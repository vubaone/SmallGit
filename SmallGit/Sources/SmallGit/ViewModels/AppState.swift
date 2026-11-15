import Foundation
import Observation
import SwiftUI

/// Root application state. Owns the cache coordinator, git service, config,
/// output log, and the persistent repository list. All toolbar/context-menu
/// actions funnel through this type so logging + cache invalidation stays
/// centralised.
@MainActor
@Observable
final class AppState {

    // MARK: - Services

    let coordinator: CacheCoordinator
    let git: GitService
    let config: ConfigService
    let output: OutputLog
    let fileWatcher: FileWatcherService
    let platform: any PlatformServices
    let gitHubAuth: any GitHubAuthenticating

    // MARK: - Persisted state

    /// Set when git refused an operation for want of a username and
    /// password. Presenting this is the only way the app can ask: git
    /// prompts on a terminal, and a `.app` has none.
    var credentialRequest: CredentialRequest?

    /// The operation that hit the credentials wall, ready to run again once
    /// the user has supplied them. Held rather than reconstructed so the
    /// retry is the same command, with the same follow-up work.
    private var credentialRetry: (() async -> Void)?
    var gitHubAuthState: GitHubAuthState = .idle
    @ObservationIgnored private var gitHubAuthTask: Task<Void, Never>?
    @ObservationIgnored private var gitHubAuthAttempt: UUID?

    var appConfig: AppConfig
    var repositoriesConfig: RepositoriesConfig
    var uiState: UIState

    // MARK: - Active repo + derived UI state

    var activeRepo: RepositoryEntry?
    var statusText: String = "Ready"
    var changedFileCount: Int = 0
    var stashList: [GitStash] = []
    /// Submodules of the active repository. Empty for the overwhelming
    /// majority of repositories, which is why the sidebar section is hidden
    /// rather than shown empty.
    var submodules: [GitSubmodule] = []
    var isFirstLaunch: Bool = false
    var toast: ToastMessage?
    private var repositoryAvailability: [UUID: RepositoryAvailability] = [:]
    /// Number of git operations currently in flight via `runGit`. Status
    /// bar shows a spinner while this is > 0.
    private(set) var inFlightCount: Int = 0
    @ObservationIgnored private var deferredBranchRefreshes: Set<String> = []
    var isWorking: Bool { inFlightCount > 0 }
    var canUseActiveRepo: Bool {
        guard let activeRepo else { return false }
        return availability(for: activeRepo).isAvailable
    }
    var activeRepositoryIssue: RepositoryAvailability? {
        guard let activeRepo else { return nil }
        let availability = availability(for: activeRepo)
        return availability.isAvailable ? nil : availability
    }

    // MARK: - Dialog visibility flags

    var showCommitDialog: Bool = false

    /// What was last typed into the commit dialog, per repository, so closing
    /// the dialog by mistake doesn't throw the message away: reopening it
    /// picks up where the typing stopped. Memory only — a draft is for this
    /// session, not something to find again next week. Dropped once a commit
    /// goes through.
    @ObservationIgnored private var commitMessageDrafts: [String: String] = [:]

    var commitMessageDraft: String {
        get { activeRepo.flatMap { commitMessageDrafts[$0.path] } ?? "" }
        set {
            guard let path = activeRepo?.path else { return }
            commitMessageDrafts[path] = newValue.isEmpty ? nil : newValue
        }
    }

    var showStashSaveDialog: Bool = false
    var showStashesSheet: Bool = false
    /// MainWindow watches this to present `ReflogBrowserView`. Loaded
    /// entries live in `reflogEntries`; flipping this true triggers
    /// `loadReflog()` via the sheet's onAppear.
    var showReflogSheet: Bool = false
    /// HEAD's reflog for the active repo, newest first. Populated by
    /// `loadReflog()` when the reflog sheet opens or the user hits Refresh.
    var reflogEntries: [GitReflogEntry] = []
    var showMergePicker: Bool = false
    var showRebasePicker: Bool = false
    /// When non-nil, MainWindow presents `InteractiveRebaseSheet` with the
    /// commits between the base and HEAD pre-populated as pick rows. Set
    /// by `startInteractiveRebase(onto:)`; cleared when the sheet closes.
    var pendingInteractiveRebase: InteractiveRebaseTarget?
    /// Set when a planned rebase finished with a result that doesn't match
    /// its plan; MainWindow offers to undo it.
    var rebaseOutcomeMismatch: RebaseOutcomeMismatch?
    /// True while `runInteractiveRebase` itself is driving git — its retry
    /// aborts and restarts the rebase, and that gap is not a finished one.
    private var interactiveRebaseRunning = false
    /// When non-nil, MainWindow presents `SquashCommitsSheet` for a
    /// contiguous Journal multi-selection. Set by `prepareSquash`; cleared
    /// when the sheet closes.
    var pendingSquash: PendingSquash?
    /// When non-nil, MainWindow presents `RewordCommitSheet` for a single
    /// Journal commit. Set by `prepareReword`; cleared when the sheet
    /// closes.
    var pendingReword: PendingReword?
    /// When non-nil, MainWindow presents `AddTagSheet` for a specific
    /// commit selected from the Journal.
    var pendingTagTarget: TagTarget?
    var showNewBranchSheet: Bool = false
    var showSyncFromSmartGitSheet: Bool = false
    var showPreferences: Bool = false
    var showAddGroupSheet: Bool = false
    var showCloneSheet: Bool = false
    /// Pre-selects the "Add to Group" picker in CloneRepositorySheet.
    /// Set before flipping `showCloneSheet` so the clone lands in the
    /// group the user right-clicked, instead of defaulting to "Other".
    var pendingCloneGroup: String?
    /// When non-nil, the next group created via AddGroupSheet receives
    /// this repository (used by the "Move To → New Group…" menu path).
    var pendingMoveRepoId: UUID?
    var confirmDiscard: Bool = false

    /// Set when a `stash apply` / `pop` stopped in conflict, holding the files
    /// it touched so `abortStashApply` can put them back. Session-only on
    /// purpose: it records something git does not, and a stale list from a
    /// previous launch would restore files the user has since edited by hand.
    var stashApplyConflict: StashApplyConflict?
    /// Files the last abort could not restore because HEAD has no version of
    /// them. Read once, for the status line.
    var stashApplyLeftInPlace: [String] = []
    /// One inference attempt per stuck state, so a refresh loop cannot turn
    /// into a stash-list poll.
    private var stashApplyProbed: Bool = false

    struct StashApplyConflict: Equatable, Sendable {
        let files: [String]
    }

    /// Set when the user picks "Rename Group…" from a group's
    /// context menu — MainWindow keys `RenameGroupSheet` off this
    /// so the rename text box pre-fills with the existing name.
    var pendingGroupRename: GroupRenameTarget?
    /// Set when the user picks "Rename…" from a repo's context
    /// menu. Renames are alias-only — the working-tree folder name
    /// stays put, only the sidebar label changes.
    var pendingRepoRename: RepoRenameTarget?

    /// Repository awaiting removal confirmation. This is deliberately UI
    /// state rather than a synchronous `NSAlert`: `MainWindow` can present
    /// the same themed SwiftUI sheet as the app's other actions while the
    /// actual list/trash operation stays centralised in `AppState`.
    var pendingRepositoryRemoval: RepositoryRemovalTarget?

    struct RepoRenameTarget: Identifiable, Hashable {
        let repoID: UUID
        let currentName: String
        var id: UUID { repoID }
    }

    struct RepositoryRemovalTarget: Identifiable, Hashable {
        let repository: RepositoryEntry
        let folderExists: Bool
        var id: UUID { repository.id }
    }

    enum RepositoryRemovalChoice: Sendable {
        case removeFromList
        case moveFolderToTrash
        case cancel
    }

    struct TagTarget: Identifiable, Hashable {
        let hash: String
        let subject: String
        var id: String { hash }
        var shortHash: String { String(hash.prefix(10)) }
    }

    struct ToastMessage: Identifiable, Hashable, Sendable {
        let id = UUID()
        let text: String
    }

    /// Set when the user picks "Settings…" from a repo's context
    /// menu. Hosts `RepositorySettingsSheet` which edits per-repo
    /// git identity (user.name / user.email) and falls back to the
    /// global Preferences value when the repo leaves a field blank.
    var pendingRepoSettings: RepositoryEntry?
    /// Confirmation prompt for "Delete Group" — destructive so we
    /// want an explicit second click before yanking the group
    /// header (its repos still survive, but moving them around is
    /// surprising if it happens silently).
    var pendingGroupDelete: GroupDeleteTarget?

    struct GroupRenameTarget: Identifiable, Hashable {
        let name: String
        var id: String { name }
    }

    struct GroupDeleteTarget: Identifiable, Hashable {
        let name: String
        let repoCount: Int
        var id: String { name }
    }

    /// Set by `addRepository` when the dragged-in folder isn't a git
    /// repo yet. MainWindow presents `InitRepositorySheet` keyed off
    /// this so the user can either run `git init` (with an optional
    /// `origin` URL) or cancel. Identifiable wrapper so the sheet
    /// item-binding clears on dismiss.
    var pendingInitTarget: InitTarget?

    struct InitTarget: Identifiable, Hashable {
        let path: String
        let group: String?
        var id: String { path }
    }

    /// Set when the dragged-in folder is a *subdirectory* of an
    /// outer git repo. Without asking, the panel would silently add
    /// the parent repo (because `git rev-parse` happily walks up to
    /// find one), which is rarely what the user meant. The sheet
    /// keyed off this offers both "open the parent repo at X" and
    /// "init a new repo here" with the same UX as the init flow.
    var pendingAmbiguousTarget: AmbiguousTarget?

    struct AmbiguousTarget: Identifiable, Hashable {
        let droppedPath: String
        let parentRootPath: String
        let group: String?
        var id: String { droppedPath }
    }

    /// When set, MainWindow presents the rename sheet for this branch.
    /// Identifiable-keyed sheets clear automatically on dismiss.
    var branchPendingRename: GitBranch?
    /// When set, MainWindow presents the rename sheet for this stash.
    var stashPendingRename: GitStash?
    /// Stash indices the sidebar asked to drop, awaiting confirmation.
    /// Empty means nothing is pending.
    var pendingStashDrop: [Int] = []
    /// When set, MainWindow presents NewBranchSheet pre-filled with this
    /// branch as the starting point.
    var branchPendingNewFrom: GitBranch?
    /// When set, MainWindow presents PushToSheet for this branch.
    var branchPendingPushTo: GitBranch?
    /// When set, MainWindow presents SetTrackedBranchSheet for this branch.
    var branchPendingSetUpstream: GitBranch?
    /// When set, MainWindow presents the delete confirmation for these
    /// branches. Carries the pre-flight merge checks so the sheet can say
    /// what the delete costs without running git again.
    var branchPendingDelete: BranchDeletionTarget?

    struct BranchDeletionTarget: Identifiable, Hashable {
        /// Every branch the confirmation covers: one when "Delete…" was
        /// picked on a single row, several when the sidebar had a batch
        /// selected.
        let branches: [GitBranch]
        /// Merge check per branch name. A branch missing from here is one
        /// whose check itself failed — git then has the last word on it.
        let checks: [String: BranchDeletionCheck]
        /// Stable across the same set of branches, which is what `sheet(item:)`
        /// keys the presentation on.
        var id: String { branches.map(\.name).joined(separator: "\n") }

        /// Branches the pre-flight check says `git branch -d` will refuse.
        /// An unchecked branch isn't counted: git decides, and the sheet
        /// re-arms if it says no.
        var needingForce: [GitBranch] {
            branches.filter { checks[$0.name].map { !$0.isFullyMerged } ?? false }
        }
    }

    /// What one pass over a delete request achieved, in enough detail for the
    /// sheet to offer the force path for exactly the branches git refused
    /// rather than for the whole batch again.
    struct BranchDeletionReport: Sendable {
        var deleted: [String] = []
        /// Refused because they aren't merged anywhere git can see — the
        /// force-delete offer.
        var unmerged: [GitBranch] = []
        /// Refused for any other reason, with git's own first line.
        var failed: [Failure] = []

        struct Failure: Sendable {
            let branch: GitBranch
            let message: String
        }

        var attempted: Int { deleted.count + unmerged.count + failed.count }
        var isComplete: Bool { unmerged.isEmpty && failed.isEmpty }
        /// What is left to try, in the order it was attempted.
        var refused: [GitBranch] { unmerged + failed.map(\.branch) }
    }
    /// Wrapper so `.sheet(item:)` can present the resolver keyed on the
    /// conflicted file path. Set by the Files panel "Resolve…" action;
    /// cleared on dismiss.
    var conflictTarget: ConflictTarget?

    struct ConflictTarget: Identifiable, Hashable {
        let path: String
        var id: String { path }
    }

    /// Request to open one or more 2-pane compare views (double-click in the
    /// Files panel, "Compare…" context menu item). A multi-file request is
    /// presented as one native tab group.
    ///
    /// A request, not a record of what's on screen: `CompareWindowOpener`
    /// clears it as soon as it has opened the window. Compares are ordinary
    /// windows and several can be open at once, so there is no single target
    /// for this to hold — ask `CompareWindowPresenter` what's open.
    var compareTarget: CompareTarget?

    struct CompareTarget: Identifiable, Hashable {
        let paths: [String]

        init(path: String) {
            self.init(paths: [path])
        }

        init(paths: [String]) {
            var seen = Set<String>()
            self.paths = paths.filter { seen.insert($0).inserted }
        }

        var id: String { paths.joined(separator: "\u{0}") }
    }

    /// Set when a file is double-clicked in the Log window and no external
    /// diff tool is configured — opens the built-in, read-only commit compare
    /// window (file at the commit's parent vs at the commit). Cleared on open,
    /// for the same reason as `compareTarget`.
    var commitCompareTarget: CommitCompareTarget?

    struct CommitCompareTarget: Identifiable, Hashable {
        let commit: GitCommit
        let paths: [String]
        var id: String { "\(commit.hash):\(paths.joined(separator: "\u{0}"))" }
    }

    /// Set by "Log" on a file in the Files panel / Journal.
    /// MainWindow watches this to present `FileHistoryView`.
    var fileHistoryTarget: FileHistoryTarget?

    struct FileHistoryTarget: Identifiable, Hashable {
        let path: String
        var id: String { path }
    }

    /// Set by "Blame…" on the Files panel. MainWindow watches this to
    /// present `BlameView`.
    var blameTarget: BlameTarget?

    struct BlameTarget: Identifiable, Hashable {
        let path: String
        var id: String { path }
    }

    /// Views holding Escape for themselves, by the window they live in.
    ///
    /// Escape is taken in three places before it can reach a view — the main
    /// window's key monitor, and each secondary window's own monitor and
    /// `sendEvent` — because that is the only way the key reliably closes a
    /// SwiftUI-hosted window. The cost is that a view with something of its
    /// own to unwind, such as a compare block open for typing, cannot simply
    /// handle the key: whichever interceptor happens to run first would have
    /// closed the window already, and the order between local monitors is not
    /// defined. So the claim lives here, where all three can ask.
    ///
    /// The closure returns true when it consumed the press. Registered per
    /// window so a compare in the background never answers for the one in
    /// front.
    @ObservationIgnored private var escapeClaims: [ObjectIdentifier: () -> Bool] = [:]

    /// Re-registering for the same window replaces the previous claim, which
    /// is what lets a view refresh the closure as its state moves.
    func claimEscape(for window: ObjectIdentifier, unwind: @escaping () -> Bool) {
        escapeClaims[window] = unwind
    }

    func releaseEscapeClaim(for window: ObjectIdentifier) {
        escapeClaims[window] = nil
    }

    /// Whether `window` has a view holding Escape. Asked about windows that
    /// are *not* key — a sheet behind the compare window the press was meant
    /// for — which must be passed over rather than closed.
    func holdsEscape(_ window: ObjectIdentifier) -> Bool {
        escapeClaims[window] != nil
    }

    /// Offers Escape to whatever `window` has registered. True means the view
    /// took it and nothing else should act on the same press.
    func consumeEscape(in window: ObjectIdentifier?) -> Bool {
        guard let window, let unwind = escapeClaims[window] else { return false }
        return unwind()
    }

    /// Optional Escape-key behavior. Returns true when there was an
    /// app-owned secondary presentation to dismiss. Actual AppKit
    /// windows/sheets are closed by the key handler before it falls
    /// back to this state cleanup.
    @discardableResult
    func dismissTopSubviewFromEscape() -> Bool {
        if confirmDiscard {
            confirmDiscard = false
            return true
        }
        if pendingGroupDelete != nil {
            pendingGroupDelete = nil
            return true
        }
        // Note: the two compare targets are deliberately absent. Both are
        // cleared the instant their window opens, so they can never stand for
        // something Escape ought to dismiss — the compare windows handle their
        // own Escape via `EscapeClosingWindow`.
        if fileHistoryTarget != nil {
            fileHistoryTarget = nil
            return true
        }
        if conflictTarget != nil {
            conflictTarget = nil
            return true
        }
        if blameTarget != nil {
            blameTarget = nil
            return true
        }
        if patchSource != nil {
            patchSource = nil
            return true
        }
        if pendingInitTarget != nil {
            pendingInitTarget = nil
            return true
        }
        if pendingAmbiguousTarget != nil {
            pendingAmbiguousTarget = nil
            return true
        }
        if pendingGroupRename != nil {
            pendingGroupRename = nil
            return true
        }
        if pendingRepoRename != nil {
            pendingRepoRename = nil
            return true
        }
        if pendingRepoSettings != nil {
            pendingRepoSettings = nil
            return true
        }
        if pendingRepositoryRemoval != nil {
            pendingRepositoryRemoval = nil
            return true
        }
        if branchPendingRename != nil {
            branchPendingRename = nil
            return true
        }
        if stashPendingRename != nil {
            stashPendingRename = nil
            return true
        }
        if branchPendingNewFrom != nil {
            branchPendingNewFrom = nil
            return true
        }
        if branchPendingPushTo != nil {
            branchPendingPushTo = nil
            return true
        }
        if branchPendingSetUpstream != nil {
            branchPendingSetUpstream = nil
            return true
        }
        if branchPendingDelete != nil {
            branchPendingDelete = nil
            return true
        }
        if pendingInteractiveRebase != nil {
            pendingInteractiveRebase = nil
            return true
        }
        if pendingSquash != nil {
            pendingSquash = nil
            return true
        }
        if pendingReword != nil {
            pendingReword = nil
            return true
        }
        if pendingTagTarget != nil {
            pendingTagTarget = nil
            return true
        }

        if showPreferences { showPreferences = false; return true }
        if showSyncFromSmartGitSheet { showSyncFromSmartGitSheet = false; return true }
        if showReflogSheet { showReflogSheet = false; return true }
        if showMergePicker { showMergePicker = false; return true }
        if showRebasePicker { showRebasePicker = false; return true }
        if showNewBranchSheet { showNewBranchSheet = false; return true }
        if showWorktreesSheet { showWorktreesSheet = false; return true }
        if showSubmodulesSheet { showSubmodulesSheet = false; return true }
        if showStashSaveDialog { showStashSaveDialog = false; return true }
        // The commit dialog is deliberately absent: it holds a message the
        // user may have spent a while on, and one stray press shouldn't cost
        // it. It closes by its Cancel button only.
        if showAddGroupSheet { showAddGroupSheet = false; return true }
        if showCloneSheet { showCloneSheet = false; return true }
        if isFirstLaunch { isFirstLaunch = false; return true }

        return false
    }

    /// Set by "Create Patch…" actions on the Files panel, Journal or a stash.
    /// MainWindow watches this to present `CreatePatchSheet`.
    var patchSource: PatchSource?

    /// Where a "Create Patch" action draws its content from. Files
    /// captures the working-tree diff for a set of paths; commit
    /// captures `git format-patch -1 <hash>`; stash captures everything
    /// the entry holds, untracked files included.
    enum PatchSource: Identifiable, Hashable {
        case files(paths: [String], suggestedName: String)
        case commit(hash: String, subject: String)
        case stash(index: Int, message: String)

        var id: String {
            switch self {
            case .files(let paths, _):    return "files:" + paths.joined(separator: "|")
            case .commit(let hash, _):    return "commit:\(hash)"
            case .stash(let index, _):    return "stash:\(index)"
            }
        }

        var suggestedFileName: String {
            switch self {
            case .files(_, let name):     return name
            case .commit(let hash, let subject):
                let slug = Self.slug(subject)
                let shortHash = String(hash.prefix(7))
                return "\(shortHash)-\(slug.isEmpty ? "patch" : slug).patch"
            case .stash(_, let message):
                // "On topic: wip avatar" — the branch is noise in a file
                // name, so only what the user typed after it is kept.
                let typed = message.range(of: ": ").map { String(message[$0.upperBound...]) } ?? message
                let slug = Self.slug(typed)
                return "stash-\(slug.isEmpty ? "patch" : slug).patch"
            }
        }

        private static func slug(_ text: String) -> String {
            text
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
    }

    // MARK: - Child view-models

    let filesVM: FilesViewModel
    let branchesVM: BranchesViewModel
    let journalVM: JournalViewModel
    let terminalVM: TerminalViewModel
    let diffVM: DiffViewModel
    let reposVM: RepositoryListViewModel

    // MARK: - Init

    init(
        coordinator: CacheCoordinator = CacheCoordinator(),
        git: GitService = .shared,
        config: ConfigService = .shared,
        output: OutputLog = OutputLog(),
        fileWatcher: FileWatcherService = FileWatcherService(),
        platform: any PlatformServices = MacPlatformServices(),
        gitHubAuth: any GitHubAuthenticating = GitHubCLIAuth()
    ) {
        self.coordinator = coordinator
        self.git = git
        self.config = config
        self.output = output
        self.fileWatcher = fileWatcher
        self.platform = platform
        self.gitHubAuth = gitHubAuth
        self.appConfig = AppConfig()
        self.repositoriesConfig = RepositoriesConfig()
        self.uiState = UIState()
        self.filesVM = FilesViewModel(coordinator: coordinator, git: git)
        self.branchesVM = BranchesViewModel(coordinator: coordinator, git: git)
        self.journalVM = JournalViewModel(coordinator: coordinator, git: git)
        self.terminalVM = TerminalViewModel {
            platform.openInTerminal(path: $0)
        }
        self.diffVM = DiffViewModel(coordinator: coordinator, git: git)
        // RepositoryListViewModel needs `self`; defer to after init.
        self.reposVM = RepositoryListViewModel(placeholder: ())
        self.reposVM.bind(to: self)
        coordinator.onBackgroundRefresh = { [weak self] key in
            self?.adoptBackgroundRefresh(of: key)
        }
    }

    /// A background refresh has corrected a value a panel was handed while it
    /// was stale. Read it into that panel — from cache, so this costs no git
    /// — because `get` answers with what it found and refreshes afterwards:
    /// the fresh value is in L1 and nothing else will ask for it.
    ///
    /// The bug this exists for: a push made while another repository was
    /// active leaves a disk snapshot whose `%D` still puts `origin/<branch>`
    /// on the previous commit, so the journal draws the local chip and the
    /// remote chip on different rows until something else happens to reload
    /// it.
    private func adoptBackgroundRefresh(of key: CacheKey) {
        let generation = coordinator.readGeneration
        Task { @MainActor in
            guard !coordinator.isActionRunning,
                  coordinator.readGeneration == generation else { return }
            switch key {
            case .log:
                await journalVM.load()
            case .fileStatus:
                await filesVM.load()
                changedFileCount = filesVM.files.count
            case .trackedFiles:
                await filesVM.adoptTrackedPathsRefresh()
            case .assumeUnchangedFiles:
                // Cheap to repeat and served from cache, but only worth
                // reading once the view that shows the flags has been opened.
                if filesVM.hasLoadedAssumeUnchanged {
                    await filesVM.loadAssumeUnchanged()
                }
            case .branchList, .remoteBranches, .tagList, .currentBranch:
                await branchesVM.load()
            case .stashList:
                await refreshStashList()
            case .diff:
                // Only if it is the diff on screen — `adoptRefresh` checks.
                await diffVM.adoptRefresh(of: key)
            // Not a panel: repository validation drives the empty states, and
            // those are re-read on their own schedule.
            case .repoValidation:
                break
            }
        }
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        isFirstLaunch = await !config.hasExistingInstall
        self.appConfig = await config.loadAppConfig()
        self.repositoriesConfig = await config.loadRepositories()
        self.uiState = await config.loadUIState()
        await refreshRepositoryAvailability()

        // Apply persisted preferences that downstream services need to know
        // about (custom git path, default diff mode, …).
        //
        // The logging flag goes first: everything below this line does I/O
        // worth recording, and a launch is one of the few moments where a
        // burst of it is expected rather than suspicious.
        Log.store.setEnabled(appConfig.diagnosticsLoggingEnabled)
        Log.app("app.launch", detail: "\(allRepositories.count) repositories")
        // The delegate already applied this from disk before the first
        // window drew; re-applying here keeps the two in step when a test or
        // a fresh install ends up with a different value than the delegate saw.
        appConfig.appearance.applyToApp()
        DiffPalette.shared.apply(appConfig.diffColors)
        if let p = appConfig.gitPath { await ProcessRunner.shared.setGitPath(p) }
        diffVM.diffMode = appConfig.diffMode
        diffVM.compactMode = appConfig.diffCompactMode
        diffVM.ignoreWhitespace = appConfig.ignoreWhitespace

        // Restore the last opened repo when possible; otherwise fall back
        // to the first repository in the list.
        let restored = appConfig.lastOpenedRepoID
            .flatMap { id in allRepositories.first { $0.id == id } }
        if activeRepo == nil, let next = restored ?? allRepositories.first {
            await selectRepo(next)
        }

        // Populate per-repo branch labels in the background so the
        // Repositories panel can show "(branch-name)" next to each
        // entry. Fire-and-forget — the panel renders fine without it
        // (the labels just appear once a result arrives).
        Task { await refreshAllRepoBranchLabels() }
    }

    /// Fans out `git symbolic-ref HEAD` across every known repo (in
    /// parallel) and writes the result back into each `RepositoryEntry`
    /// so the Repositories panel can show the active branch next to
    /// the repo name. Persists the config when any entry actually
    /// changed.
    func refreshAllRepoBranchLabels() async {
        let repos = allRepositories
        guard !repos.isEmpty else { return }

        let previous = repositoryAvailability
        let updates = await withTaskGroup(
            of: (UUID, String?, RepositoryAvailability?).self,
            returning: [UUID: (String?, RepositoryAvailability?)].self
        ) { group in
            for repo in repos {
                group.addTask { [git] in
                    let availability = await Self.detectAvailability(path: repo.path, git: git)
                    guard availability == .available else {
                        // Including the case where git never answered — the
                        // label the row already carries is still the best
                        // thing known about it.
                        return (repo.id, availability == nil ? repo.currentBranch : nil, availability)
                    }
                    let branch = try? await git.currentBranch(repoPath: repo.path)
                    return (repo.id, branch, .available)
                }
            }
            var out: [UUID: (String?, RepositoryAvailability?)] = [:]
            for await (id, branch, availability) in group {
                out[id] = (branch, availability)
            }
            return out
        }

        repositoryAvailability = updates.reduce(into: [:]) { out, element in
            switch element.value.1 {
            case .some(let verdict) where !verdict.isAvailable:
                out[element.key] = verdict
            case .some:
                break
            case .none:
                if let kept = previous[element.key] { out[element.key] = kept }
            }
        }

        var changed = false
        for gi in repositoriesConfig.groups.indices {
            for ri in repositoriesConfig.groups[gi].repositories.indices {
                let id = repositoriesConfig.groups[gi].repositories[ri].id
                let new = updates[id]?.0
                if new != repositoriesConfig.groups[gi].repositories[ri].currentBranch {
                    repositoriesConfig.groups[gi].repositories[ri].currentBranch = new
                    changed = true
                }
                if activeRepo?.id == id {
                    activeRepo?.currentBranch = new
                }
            }
        }
        for ri in repositoriesConfig.ungrouped.indices {
            let id = repositoriesConfig.ungrouped[ri].id
            let new = updates[id]?.0
            if new != repositoriesConfig.ungrouped[ri].currentBranch {
                repositoriesConfig.ungrouped[ri].currentBranch = new
                changed = true
            }
            if activeRepo?.id == id {
                activeRepo?.currentBranch = new
            }
        }

        if changed {
            try? await config.saveRepositories(repositoriesConfig)
        }
    }

    /// Push the active repo's currently-detected branch (from
    /// `branchesVM.currentBranch`) into its `RepositoryEntry` so the
    /// label in the Repositories panel stays in sync after checkout /
    /// branch create / rename. Called from `refreshPanels()` after the
    /// branches view-model has been reloaded.
    private func syncActiveRepoBranchLabel() {
        guard let active = activeRepo else { return }
        // Nil is written through rather than skipped. It only gets here after
        // the branches view-model has reloaded, so it means "read the repo,
        // found no branch" — a detached HEAD — and leaving the last known name
        // in place is how the sidebar came to name a branch the repo was no
        // longer on.
        let branch = branchesVM.currentBranch
        var changed = false
        for gi in repositoriesConfig.groups.indices {
            for ri in repositoriesConfig.groups[gi].repositories.indices
                where repositoriesConfig.groups[gi].repositories[ri].id == active.id
            {
                if repositoriesConfig.groups[gi].repositories[ri].currentBranch != branch {
                    repositoriesConfig.groups[gi].repositories[ri].currentBranch = branch
                    changed = true
                }
            }
        }
        for ri in repositoriesConfig.ungrouped.indices
            where repositoriesConfig.ungrouped[ri].id == active.id
        {
            if repositoriesConfig.ungrouped[ri].currentBranch != branch {
                repositoriesConfig.ungrouped[ri].currentBranch = branch
                changed = true
            }
        }
        // Keep the local activeRepo snapshot in sync too.
        if activeRepo?.currentBranch != branch {
            activeRepo?.currentBranch = branch
        }
        if changed {
            Task { try? await config.saveRepositories(repositoriesConfig) }
        }
    }

    var allRepositories: [RepositoryEntry] {
        repositoriesConfig.groups.flatMap(\.repositories) + repositoriesConfig.ungrouped
    }

    func availability(for repo: RepositoryEntry) -> RepositoryAvailability {
        repositoryAvailability[repo.id] ?? .available
    }

    func refreshRepositoryAvailability() async {
        let repos = allRepositories
        guard !repos.isEmpty else {
            repositoryAvailability = [:]
            return
        }

        let previous = repositoryAvailability
        let updates = await withTaskGroup(
            of: (UUID, RepositoryAvailability?).self,
            returning: [UUID: RepositoryAvailability].self
        ) { group in
            for repo in repos {
                group.addTask { [git] in
                    let availability = await Self.detectAvailability(path: repo.path, git: git)
                    return (repo.id, availability)
                }
            }
            var out: [UUID: RepositoryAvailability] = [:]
            for await (id, availability) in group {
                switch availability {
                case .some(let verdict) where !verdict.isAvailable:
                    out[id] = verdict
                case .some:
                    break
                case .none:
                    // Git said nothing about this one; leave the row as it was.
                    if let kept = previous[id] { out[id] = kept }
                }
            }
            return out
        }

        repositoryAvailability = updates
    }

    @discardableResult
    private func refreshAvailability(for repo: RepositoryEntry) async -> RepositoryAvailability {
        guard let availability = await Self.detectAvailability(path: repo.path, git: git) else {
            return self.availability(for: repo)
        }
        var next = repositoryAvailability
        if availability.isAvailable {
            next.removeValue(forKey: repo.id)
        } else {
            next[repo.id] = availability
        }
        repositoryAvailability = next
        return availability
    }

    /// `nil` means git was never heard from — a spawn that failed, a
    /// timeout, a cancelled refresh. Callers keep whatever the row said
    /// before rather than reading silence as "Not a Repo", a verdict that
    /// otherwise sticks to every repository at once until the next launch.
    nonisolated private static func detectAvailability(
        path: String,
        git: GitService
    ) async -> RepositoryAvailability? {
        let normalizedPath = normalizePath(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .missingPath
        }
        switch await git.probeWorkTree(at: normalizedPath) {
        case .workTree(let root):
            // A folder inside a repository is not the repository: the
            // sidebar's rows are roots.
            return normalizePath(root) == normalizedPath ? .available : .notRepository
        case .notARepository:
            return .notRepository
        case .unknown:
            return nil
        }
    }

    // MARK: - Repo management

    func selectRepo(_ repo: RepositoryEntry) async {
        let availability = await refreshAvailability(for: repo)
        guard availability.isAvailable else {
            selectUnavailableRepo(repo, availability: availability)
            return
        }

        activeRepo = repo
        coordinator.switchRepo(to: repo.path)
        // A landmark, not a measurement: switching repos invalidates every
        // cache and restarts the watcher, so the burst of activity that
        // follows is only legible if you can see where it started.
        Log.app("repo.switch", detail: repo.path)
        statusText = "Loaded \(repo.name)"
        diffVM.clear()
        filesVM.selectedFileIDs.removeAll()
        filesVM.clearTrackedPaths()
        filesVM.clearAssumeUnchangedPaths()
        journalVM.commits = []
        journalVM.clearSearch()
        journalVM.resetPagination()
        // The terminal follows the repository, transcript and all: what was
        // run stays readable, but the next command runs in the new repo.
        terminalVM.setRepository(repo.path)
        // Graph whatever refs this repo was last showing — the Branches
        // checkboxes are per-repo state, like SmartGit's.
        journalVM.restoreRefSelection(repo.logSelection ?? .headOnly)
        // Clear branches too so the user doesn't see the previous
        // repo's branch list flash through while the new repo's
        // status loads.
        branchesVM.localBranches = []
        branchesVM.remoteBranches = []
        branchesVM.tags = []
        branchesVM.currentBranch = nil
        // Which folders were open belonged to the old repository's branch
        // names; the reveal below opens the ones the new repository needs.
        branchesVM.expandedFolders.removeAll()
        // Cleared here as well as by the panel so that switching to a second
        // repository checked out on the same branch name still reads as a new
        // request rather than as no change at all.
        branchRevealTarget = nil
        inProgressOperation = nil
        // Belong to the repository being left, not the one being opened.
        stashApplyConflict = nil
        stashApplyProbed = false
        flattenedConflictPaths = []
        startWatching(layout: await git.layout(repoPath: repo.path))
        // Persist as last-opened so next launch restores it.
        appConfig.lastOpenedRepoID = repo.id
        try? await config.saveAppConfig(appConfig)
        await refreshPanels()
        // Only now: the branch list arrives with `refreshPanels`, so asking
        // for the row any earlier asks for a row that does not exist yet.
        //
        // The folders above the branch are opened here, as part of the switch,
        // rather than by the panel as a reaction to it — so the first render
        // of the new repository already draws the row the request names. A row
        // that isn't drawn is one `scrollTo` cannot find.
        if let current = branchesVM.currentBranch {
            branchesVM.revealLocalBranch(current)
            branchRevealTarget = current
        }
    }

    private func selectUnavailableRepo(
        _ repo: RepositoryEntry,
        availability: RepositoryAvailability
    ) {
        activeRepo = repo
        coordinator.switchRepo(to: nil)
        fileWatcher.stop()
        clearRepoPanelState()
        statusText = "\(availability.emptyStateTitle): \(repo.name)"
        appConfig.lastOpenedRepoID = repo.id
        Task { try? await config.saveAppConfig(appConfig) }
    }

    /// Begin streaming filesystem changes for the active repo. The watcher
    /// hands batched paths to `CacheCoordinator.onFileSystemChange`, which
    /// in turn fires `InvalidationEngine` and surgically drops affected
    /// L1 entries. A panel refresh is then dispatched on the main actor.
    ///
    /// Watches whatever roots the layout names rather than the checkout
    /// alone: a linked worktree keeps its `HEAD` and its refs outside the
    /// work tree, so a stream rooted there saw no branch switch, no commit
    /// and no fetch — every cache stayed warm until the user clicked
    /// something.
    private func startWatching(layout: RepoLayout) {
        let coord = coordinator
        fileWatcher.start(directories: layout.watchRoots) { [weak self] changedPaths in
            Task { @MainActor in
                guard let self else { return }
                let before = coord.activeRepoPath
                let invalidated = coord.onFileSystemChange(paths: changedPaths, layout: layout)
                // Skip the refresh when the batch touched nothing the UI
                // depends on (e.g. transient `.git/` lock files). Refreshing
                // on every event spawns git commands whose own `.git/` writes
                // feed straight back into the watcher — the idle-I/O loop.
                // Also bail if the user switched repos while we were queued.
                if invalidated, coord.activeRepoPath == before {
                    await self.refreshPanels()
                }
            }
        }
    }

    /// Reload every panel view-model. Called after repo switch and after
    /// any action whose post-invalidation drops cached data.
    ///
    /// File status and the journal use `forceRefresh` rather than `load`:
    /// post-action invalidation (`coordinator.after`) only clears L1, so a
    /// plain `load` falls through to the stale L2 disk snapshot and merely
    /// schedules a background refresh the view never re-reads — leaving the
    /// Files panel showing pre-stage state, and the journal missing the
    /// commit that was just made, until the next interaction. Bypassing the
    /// cache writes the fresh `git status` and `git log` straight into
    /// `files` and `commits`.
    func refreshPanels(forceBranches: Bool = false) async {
        // Filesystem events still invalidate caches while Git is writing,
        // but the last action to finish will read the final state once.
        if coordinator.isActionRunning {
            if forceBranches, let path = coordinator.activeRepoPath {
                deferredBranchRefreshes.insert(path)
            }
            return
        }
        let deferred = coordinator.activeRepoPath.flatMap { deferredBranchRefreshes.remove($0) } != nil
        async let f: Void = filesVM.forceRefresh()
        async let b: Void = reloadBranches(force: forceBranches || deferred)
        async let j: Void = journalVM.forceRefresh()
        async let s: Void = refreshStashList()
        async let o: Void = refreshInProgressOperation()
        async let m: Void = refreshSubmodules()
        _ = await (f, b, j, s, o, m)
        // After the gather: both of these need the file list and the marker.
        await probeStashApplyConflict()
        await probeFlattenedConflicts()
        changedFileCount = filesVM.files.count
        // Surface the just-loaded branch name in the Repositories
        // panel so checkout / branch ops show up there immediately.
        syncActiveRepoBranchLabel()
        await pruneJournalRefSelection()
    }

    private func refreshAfterAction(repoPath: String, forceBranches: Bool) async {
        // Cancellation must stop the Git command, not the read that shows
        // what it left behind. An unstructured task can finish that read
        // even when the action's parent task has already been cancelled.
        await Task { @MainActor in
            guard coordinator.activeRepoPath == repoPath else { return }
            await refreshPanels(forceBranches: forceBranches)
        }.value
    }

    // MARK: - Journal ref selection

    /// Tick or untick refs in the journal's graph — the Branches panel's
    /// checkboxes — and remember the choice for this repository.
    func setJournalRefs(_ refs: [String], checked: Bool) async {
        await journalVM.setRefs(refs, checked: checked)
        await persistJournalRefSelection()
    }

    func setJournalHeadSelected(_ on: Bool) async {
        await journalVM.setHeadSelected(on)
        await persistJournalRefSelection()
    }

    /// Back to the default graph: HEAD and nothing else.
    func showJournalHeadOnly() async {
        await journalVM.showHeadOnly()
        await persistJournalRefSelection()
    }

    private func persistJournalRefSelection() async {
        guard let repo = activeRepo else { return }
        let selection = journalVM.refSelection
        // The default is stored as nil, so a repo nobody has touched
        // doesn't carry a selection in the config file.
        updateRepo(repo) { $0.logSelection = selection.isHeadOnly ? nil : selection }
        try? await config.saveRepositories(repositoriesConfig)
    }

    /// Forget ticked refs that have since been deleted. Only runs on a
    /// populated branch list — pruning against a list that hasn't loaded
    /// yet would clear the whole selection.
    private func pruneJournalRefSelection() async {
        guard !journalVM.refSelection.refs.isEmpty,
              !branchesVM.localBranches.isEmpty else { return }
        var known = Set(branchesVM.localBranches.map(\.name))
        known.formUnion(branchesVM.remoteBranches.map(\.name))
        known.formUnion(branchesVM.tags)
        await journalVM.pruneRefSelection(keeping: known)
        await persistJournalRefSelection()
    }

    /// Force-fresh vs. cached branch reload. Branch-mutating actions pass
    /// `force: true` because `coordinator.after` only clears L1 — a cached
    /// `load()` would serve the stale L2 snapshot and skip the new branch.
    private func reloadBranches(force: Bool) async {
        if force {
            await branchesVM.forceRefresh()
        } else {
            await branchesVM.load()
        }
    }

    private func refreshStashList() async {
        let list = await coordinator.get(
            .stashList, as: [GitStash].self, maxAge: 30
        ) { [git] repo in try await git.stashList(repoPath: repo) }
        self.stashList = list ?? []
    }

    /// Reloads the active repository's submodules.
    ///
    /// Uncached, unlike the branch and stash lists. `git submodule status`
    /// against a repository with none is a single cheap call that exits
    /// immediately, and one *with* them reports a state — moved, conflicted —
    /// that changes as the user works inside the submodule. A stale answer
    /// there is worse than the call it saves.
    func refreshSubmodules() async {
        guard let repo = activeRepo?.path else {
            submodules = []
            return
        }
        submodules = await git.submodules(repoPath: repo)
    }

    /// Clones and checks out submodules that aren't initialised.
    func updateSubmodules(paths: [String] = []) async {
        await runGit(action: "Update Submodules") { repo in
            try await self.git.updateSubmodules(repoPath: repo, paths: paths)
        } onSuccess: {
            // A submodule checkout changes the parent's working tree, so the
            // Files panel and the gitlink's state both move.
            self.coordinator.invalidateAll()
        }
        await refreshSubmodules()
    }

    /// Empties a submodule's working tree, keeping its registration.
    func deinitSubmodule(_ submodule: GitSubmodule) async {
        let hasLocalWork = submodule.state == .modified
        // `--force` is required whenever the checkout has work in it, and
        // without asking first that would discard it silently.
        if hasLocalWork {
            let confirmed = platform.confirmWarning(
                title: "Discard changes in \(submodule.name)?",
                message: "\(submodule.path) is checked out at a different commit than \(activeRepo?.name ?? "the repository") records. Removing its working tree discards anything uncommitted inside it.",
                primaryButton: "Remove Anyway"
            )
            guard confirmed else { return }
        }
        await runGit(action: "Deinit Submodule") { repo in
            try await self.git.deinitSubmodule(
                repoPath: repo, path: submodule.path, force: hasLocalWork
            )
        } onSuccess: {
            self.coordinator.invalidateAll()
        }
        await refreshSubmodules()
    }

    func syncSubmodules() async {
        await runGit(action: "Sync Submodules") { repo in
            try await self.git.syncSubmodules(repoPath: repo)
        }
        await refreshSubmodules()
    }

    /// Registers a new submodule and clones it.
    func addSubmodule(url: String, path: String) async {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedPath.isEmpty else { return }
        await runGit(action: "Add Submodule") { repo in
            try await self.git.addSubmodule(repoPath: repo, url: trimmedURL, path: trimmedPath)
        } onSuccess: {
            self.coordinator.invalidateAll()
        }
        await refreshSubmodules()
    }

    /// Adds a submodule's working tree to the sidebar as a repository of its
    /// own.
    ///
    /// This is the "operate on the submodule repository" half of the split
    /// that makes submodule UIs comprehensible — everything the app already
    /// does to a repository then applies to it, with no new concepts.
    func openSubmoduleAsRepository(_ submodule: GitSubmodule) async {
        guard let repo = activeRepo?.path else { return }
        let path = submodule.absolutePath(in: repo)
        guard submodule.isCloned else {
            statusText = "\(submodule.name) is not initialized yet"
            return
        }
        await addRepository(at: path)
    }

    /// Same, from a path alone — what the Files panel and the Submodule
    /// window have, neither of which is holding a `GitSubmodule`.
    func openSubmoduleAsRepository(path: String) async {
        guard await selectSubmoduleAsActiveRepository(path: path) else { return }
        // Handing the submodule over means the main window is now showing a
        // repository the user has never scrolled to — one that was added a
        // moment ago, or sits a hundred rows down a list they were not
        // reading. The row is where the branch, the tree and every
        // right-click action live, so being given the repository without
        // being given its row is half the answer.
        sidebarRevealTarget = activeRepo?.id
    }

    /// One-shot request for the Repositories list to scroll a row into view.
    ///
    /// Set by "Open as Repository" alone. Scrolling on every change of active
    /// repository would yank the list around under someone who is reading it
    /// — clicking a row you can already see should not move it — so this is a
    /// request from the one flow that hands over a repository the user has no
    /// row for, and the panel clears it as soon as it has scrolled.
    var sidebarRevealTarget: UUID?

    /// One-shot request for the Branches panel to scroll the checked-out
    /// branch into view.
    ///
    /// Set by a repository switch alone, and for the same reason the
    /// repositories list has one of these: the panel opens at the top, and in
    /// a repository with a few dozen branches the one you are actually working
    /// on is below the fold — the first thing a switch makes you do is hunt
    /// for it. Every other refresh leaves the list exactly where the user put
    /// it, since a list that scrolls itself while you are reading it is worse
    /// than one that never scrolls at all. The panel clears this as soon as it
    /// has scrolled.
    var branchRevealTarget: String?

    /// Submodule the Submodule window is showing, or nil. Set by
    /// double-clicking a submodule; deliberately *not* the active
    /// repository, so looking into it leaves the main window where it was.
    var submoduleLogTarget: SubmoduleLogTarget?

    /// Open a submodule's log — which means opening the submodule itself.
    ///
    /// A submodule is a repository, and this app already has a window that
    /// shows a repository's history with its files, its commit detail and
    /// its diff: the Log window. Rather than a second, lesser version of
    /// that for submodules, the submodule becomes the active repository and
    /// the existing window shows it — uncommitted node, toolbar, commit and
    /// all. The caller opens the window; this half makes it the thing the
    /// window is looking at.
    ///
    /// Returns false when there is nothing to open, so the caller can skip
    /// bringing up a window onto the previous repository.
    /// Absolute path of a submodule that actually has a checkout, or nil.
    ///
    /// An uninitialised submodule is an empty directory — there is nothing
    /// to open, and adding it would put a broken repository in the sidebar.
    /// (`.git` is a *file* in a submodule, a gitdir pointer, so this checks
    /// existence rather than directory-ness.)
    private func clonedSubmodulePath(_ path: String) -> String? {
        guard let repo = activeRepo?.path else { return nil }
        let absolute = Self.normalizePath((repo as NSString).appendingPathComponent(path))
        guard FileManager.default.fileExists(
            atPath: (absolute as NSString).appendingPathComponent(".git")
        ) else {
            statusText = "\((path as NSString).lastPathComponent) is not initialized yet"
            return nil
        }
        return absolute
    }

    @discardableResult
    func openSubmoduleLog(path: String) async -> Bool {
        // Point the Submodule window at it and stop. Making it the active
        // repository is a different intent — "Open as Repository" — and
        // doing it here moved the main window off the repository the user
        // was working in, taking its commit dialog with it.
        guard let repo = activeRepo?.path, clonedSubmodulePath(path) != nil else { return false }
        submoduleLogTarget = SubmoduleLogTarget(parentPath: repo, path: path)
        return true
    }

    /// Make a submodule the active repository — the explicit "work in it
    /// instead" action, and the only thing that moves the main window.
    @discardableResult
    private func selectSubmoduleAsActiveRepository(path: String) async -> Bool {
        guard let absolute = clonedSubmodulePath(path) else { return false }

        // Registering and selecting are different acts, and `addRepository`
        // only does the second as part of the first: a submodule opened
        // once is already in the list, so every later double-click hit its
        // "already exists" path and left the parent active — the Log window
        // then opened onto the parent, which is not what was clicked.
        if let existing = repository(atPath: absolute) {
            await selectRepo(existing)
        } else {
            await addRepository(at: absolute)
        }

        // Only report success if the submodule really is what the window
        // would show. Adding can end in a sheet instead — an unexpected
        // folder, a repo that needs initialising — and opening a Log window
        // onto the previous repository would look exactly like the bug this
        // guard exists to stop.
        guard let active = activeRepo, Self.normalizePath(active.path) == absolute else {
            return false
        }
        return true
    }

    /// Commit history for a single file (`git log --follow`), newest first.
    /// Returns empty on error or when no repo is active. Not cached — opened
    /// on demand from a transient sheet, freshness matters more than the cost.
    func fileHistory(path: String) async -> [GitCommit] {
        guard let repo = activeRepo else { return [] }
        let id = output.begin(action: "File History", command: "git log --follow -- \(path)")
        do {
            let commits = try await git.fileHistory(repoPath: repo.path, path: path)
            output.finish(id: id, status: .success, detail: "\(commits.count) commit\(commits.count == 1 ? "" : "s")")
            return commits
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            return []
        }
    }

    /// Diff of a single file as introduced by `hash` (`git show <hash> -- <path>`).
    /// Used by the File History sheet to preview each revision's change.
    func fileDiff(
        path: String,
        atCommit hash: String,
        compact: Bool = true,
        repoPath: String? = nil
    ) async -> [DiffHunk] {
        guard let repo = repoPath ?? activeRepo?.path else { return [] }
        let id = output.begin(action: "File Diff", command: "git show \(hash) -- \(path)")
        do {
            let hunks = try await git.commitDiff(
                repoPath: repo,
                hash: hash,
                paths: [path],
                fullFile: !compact
            )
            output.finish(id: id, status: .success, detail: "\(hunks.count) hunk\(hunks.count == 1 ? "" : "s")")
            return hunks
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            return []
        }
    }

    /// What committing now would record for `path`: HEAD against the index
    /// (`git diff --cached`). Empty on error or when no repo is active.
    func stagedFileDiff(
        path: String,
        compact: Bool = true,
        repoPath: String? = nil
    ) async -> [DiffHunk] {
        guard let repo = repoPath ?? activeRepo?.path else { return [] }
        let id = output.begin(action: "Staged Diff", command: "git diff --cached -- \(path)")
        do {
            let hunks = try await git.diff(
                repoPath: repo,
                file: path,
                mode: .headVsIndex,
                ignoreWhitespace: false,
                fullFile: !compact
            )
            output.finish(id: id, status: .success, detail: "\(hunks.count) hunk\(hunks.count == 1 ? "" : "s")")
            return hunks
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            return []
        }
    }

    /// Line-by-line authorship for a file (`git blame`). Returns empty on
    /// error (e.g. untracked path) or when no repo is active.
    func blame(path: String) async -> [GitBlameLine] {
        guard let repo = activeRepo else { return [] }
        let id = output.begin(action: "Blame", command: "git blame -- \(path)")
        do {
            let lines = try await git.blame(repoPath: repo.path, path: path)
            output.finish(id: id, status: .success, detail: "\(lines.count) line\(lines.count == 1 ? "" : "s")")
            return lines
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            return []
        }
    }

    /// Raw `git log -L` history for the selected blame line.
    func blameLineHistory(path: String, line: Int) async -> String {
        guard let repo = activeRepo else { return "" }
        let id = output.begin(action: "Line History", command: "git log -L \(line),\(line):\(path)")
        do {
            let history = try await git.blameLineHistory(repoPath: repo.path, path: path, line: line)
            output.finish(id: id, status: .success, detail: history.isEmpty ? "no history" : "loaded")
            return history
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            return ""
        }
    }

    /// Loads HEAD's reflog into `reflogEntries`. Not cached — reflog is
    /// a recovery tool and freshness matters more than the few-ms cost
    /// of re-running it each time the sheet opens.
    func loadReflog() async {
        guard let repo = activeRepo else {
            reflogEntries = []
            return
        }
        let id = output.begin(
            action: "Reflog",
            command: "git reflog show HEAD"
        )
        do {
            let entries = try await git.reflog(repoPath: repo.path)
            output.finish(
                id: id,
                status: .success,
                detail: "\(entries.count) entr\(entries.count == 1 ? "y" : "ies")"
            )
            reflogEntries = entries
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            reflogEntries = []
        }
    }

    /// Selects a file in the Files panel and loads its diff into the Diff
    /// panel. `staged` controls which diff view (worktree vs. index).
    /// Untracked files are routed through `loadUntrackedDiff` so their
    /// full content shows up as an added block instead of an empty
    /// "No differences" panel.
    func selectFile(_ file: GitFileStatus) async {
        // Don't reassign `selectedFileIDs` here — when the user
        // cmd/shift-clicks to extend the selection, the Table's
        // onChange calls into this method, and overwriting the set
        // with a single id would collapse the multi-select before
        // Stage/Unstage could act on it.
        if file.isSubmodule {
            // Not a file: `git diff` on a gitlink answers with two SHAs and
            // no content, which is what the panel used to show.
            await diffVM.loadSubmodule(path: file.path)
        } else if file.isConflict {
            await diffVM.loadConflictDiff(file: file.path)
        } else if file.state == .untracked && !file.isStaged {
            await diffVM.loadUntrackedDiff(file: file.path)
        } else {
            await diffVM.loadDiff(file: file.path, mode: Self.defaultCompareMode(for: file))
        }
    }

    /// Auto-pick rule for the compare-mode picker. Show the diff that has
    /// the most meaningful content: prefer staged changes when the file
    /// has any, otherwise fall through to the unstaged view. Matches
    /// SmartGit's default for "Staged + Modified" files.
    private static func defaultCompareMode(for file: GitFileStatus) -> DiffCompareMode {
        file.isStaged ? .headVsIndex : .indexVsWorkingTree
    }

    func addRepository(at path: String, group: String? = nil) async {
        let normalizedPath = Self.normalizePath(path)
        if let existing = repository(atPath: normalizedPath) {
            showToast("Repository already exists: \(existing.name)")
            statusText = "Repository already exists"
            return
        }

        guard await git.isRepository(at: normalizedPath) else {
            // Surface the Init-Repository sheet instead of silently
            // refusing — the user almost always wants either "make
            // this a git repo" or "I dropped the wrong folder",
            // and the sheet captures both intents.
            pendingInitTarget = InitTarget(path: normalizedPath, group: group)
            statusText = "Folder isn't a git repo — initialize?"
            return
        }

        // `git rev-parse --is-inside-work-tree` returns true for any
        // subdirectory of a git repo, so a folder that *isn't* a repo
        // root would silently get registered as its enclosing repo.
        // Compare against `show-toplevel` to detect that case and ask
        // the user which they meant — the outer repo, or a new
        // independent repo at the dropped path.
        let root: String? = (try? await git.repositoryRoot(of: normalizedPath))
            .map(Self.normalizePath)
        if let root, root != normalizedPath {
            if let existing = repository(atPath: root) {
                showToast("Repository already exists: \(existing.name)")
                statusText = "Repository already exists"
                return
            }
            pendingAmbiguousTarget = AmbiguousTarget(
                droppedPath: normalizedPath,
                parentRootPath: root,
                group: group
            )
            statusText = "Folder is inside another repo — choose how to add it"
            return
        }

        await register(path: normalizedPath, group: group)
    }

    /// Keep the current repository open while registering the selection,
    /// then load only the last repository actually added. A batch skips
    /// duplicates and non-root folders instead of stacking Init/Parent sheets.
    func addRepositories(at paths: [String], group: String? = nil) async {
        guard !paths.isEmpty else { return }
        if paths.count == 1 {
            await addRepository(at: paths[0], group: group)
            return
        }

        var added: [RepositoryEntry] = []
        var skipped: [String] = []
        for path in paths {
            let normalized = Self.normalizePath(path)
            if repository(atPath: normalized) != nil {
                skipped.append("\(normalized): already in the list")
                continue
            }
            guard case .workTree(let root) = await git.probeWorkTree(at: normalized),
                  Self.normalizePath(root) == normalized else {
                skipped.append("\(normalized): not the root of an accessible Git repository")
                continue
            }
            if let entry = await register(path: normalized, group: group, activate: false) {
                added.append(entry)
            }
        }

        if let last = added.last { await selectRepo(last) }
        if !skipped.isEmpty {
            let summary = "Added \(added.count) repositor\(added.count == 1 ? "y" : "ies"); "
                + "skipped \(skipped.count) folder\(skipped.count == 1 ? "" : "s")"
            let id = output.begin(action: "Add Repositories", command: "")
            output.finish(id: id, status: .success, detail: summary + "\n" + skipped.joined(separator: "\n"))
            statusText = summary + " — see Output"
            showToast(summary)
        }
    }

    /// Trim trailing slashes so two paths that point to the same
    /// directory compare equal — `/a/b` and `/a/b/` are the same
    /// folder, but string comparison rejects the latter.
    nonisolated private static func normalizePath(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        p = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        while p.count > 1, p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    private func repository(atPath path: String) -> RepositoryEntry? {
        let normalized = Self.normalizePath(path)
        return allRepositories.first { Self.normalizePath($0.path) == normalized }
    }

    /// Run `git init` in `path`, optionally wire up `origin` to
    /// `remoteURL`, then add the resulting repo to the panel. Called
    /// from `InitRepositorySheet` after the user confirms.
    /// Run `git init` on an already-registered entry whose folder isn't a
    /// repo yet — the "Init Git Here" action on a "Not a Repo" sidebar row.
    /// Unlike `initAndAddRepository` (which registers a *new* entry and bails
    /// when the path already exists), the entry is already in the list, so we
    /// init in place, refresh its availability badge, and open it.
    func initRepositoryInPlace(_ repo: RepositoryEntry) async {
        let path = Self.normalizePath(repo.path)
        do {
            _ = try await git.initRepository(at: path)
            // Make sure the folder is now its own repo root, not resolving
            // up to an enclosing repo — same guard as the drag-in init flow.
            let resolvedRoot = (try? await git.repositoryRoot(of: path)).map(Self.normalizePath)
            guard resolvedRoot == path else {
                statusText = "Init didn't take — folder still resolves to \(resolvedRoot ?? "unknown")"
                return
            }
            await purgeCache(forRepoPath: path)
            await refreshRepositoryAvailability()
            await selectRepo(repo)
            statusText = "Initialized \(repo.name)"
        } catch {
            statusText = "Init failed: \(error.localizedDescription)"
        }
    }

    func initAndAddRepository(path: String, group: String?, remoteURL: String?) async {
        let normalizedPath = Self.normalizePath(path)
        do {
            _ = try await git.initRepository(at: normalizedPath)
            if let url = remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !url.isEmpty {
                _ = try await git.addRemote(repoPath: normalizedPath, url: url)
            }
            // Confirm the new path is now a repo root — i.e. its own
            // `.git` is what git sees, not the enclosing repo's. If
            // verification fails, the dropped folder is still
            // resolving to its parent and registering would re-trigger
            // the original "wrong repo loaded" bug. Bail loudly.
            let resolvedRoot: String? = (try? await git.repositoryRoot(of: normalizedPath))
                .map(Self.normalizePath)
            guard resolvedRoot == normalizedPath else {
                statusText = "Init didn't take — folder still resolves to \(resolvedRoot ?? "unknown")"
                return
            }
            // Wipe any disk-cache entries the previous bad add may
            // have written for this path so the journal can't load
            // 49 commits of the parent repo's history.
            await purgeCache(forRepoPath: normalizedPath)
            await register(path: normalizedPath, group: group)
            statusText = "Initialized \(URL(fileURLWithPath: normalizedPath).lastPathComponent)"
        } catch {
            statusText = "Init failed: \(error.localizedDescription)"
        }
    }

    /// Remove every disk-cache entry tied to `repoPath`. Used after
    /// `git init` so any historical L2 data — written when the
    /// enclosing repo was silently registered for this path — can't
    /// resurface in the new empty repo's Journal or Files panels.
    private func purgeCache(forRepoPath repoPath: String) async {
        coordinator.invalidateAll()
        await coordinator.purgeDiskCache(forRepoPath: repoPath)
    }

    /// Shared body of `addRepository` + `initAndAddRepository` — the
    /// part that mutates `repositoriesConfig` and selects the entry.
    /// Kept private so the only ways into the panel go through the
    /// is-it-a-repo check above.
    @discardableResult
    private func register(path: String, group: String?, activate: Bool = true) async -> RepositoryEntry? {
        if let existing = repository(atPath: path) {
            showToast("Repository already exists: \(existing.name)")
            statusText = "Repository already exists"
            return nil
        }

        let entry = RepositoryEntry(path: path)
        if let group {
            if let idx = repositoriesConfig.groups.firstIndex(where: { $0.name == group }) {
                repositoriesConfig.groups[idx].repositories.append(entry)
            } else {
                repositoriesConfig.groups.append(
                    RepositoryGroup(name: group, repositories: [entry])
                )
            }
        } else {
            repositoriesConfig.ungrouped.append(entry)
        }
        try? await config.saveRepositories(repositoriesConfig)
        if activate { await selectRepo(entry) }
        return entry
    }

    /// Move an existing repository entry into the named group (or to
    /// ungrouped when `groupName` is nil). No-op when the entry is
    /// already where the user is trying to put it. Used by the
    /// drag-and-drop reordering in the Repositories panel.
    /// Name of the group containing `repo`, or nil if it is ungrouped /
    /// not registered. Used by the "Move To" submenu to disable the
    /// destination the repository already lives in.
    func groupName(for repo: RepositoryEntry) -> String? {
        repositoriesConfig.groups
            .first(where: { $0.repositories.contains(where: { $0.id == repo.id }) })?
            .name
    }

    /// Flip the disclosure state of a named group (or "Other" when
     /// `groupName == nil`) and persist. Drives the chevron in the
     /// Repositories panel — collapse remembers across restarts so a
     /// user with many groups doesn't have to re-collapse on every
     /// launch.
    func toggleGroupExpansion(_ groupName: String?) async {
        if let name = groupName {
            if let idx = repositoriesConfig.groups.firstIndex(where: { $0.name == name }) {
                repositoriesConfig.groups[idx].expanded.toggle()
            }
        } else {
            repositoriesConfig.ungroupedExpanded.toggle()
        }
        try? await config.saveRepositories(repositoriesConfig)
    }

    func moveRepository(_ repo: RepositoryEntry, toGroup groupName: String?) async {
        let currentGroup: String? = repositoriesConfig.groups
            .first(where: { $0.repositories.contains(where: { $0.id == repo.id }) })?
            .name
        if currentGroup == groupName { return }

        var moved: RepositoryEntry?
        for gi in repositoriesConfig.groups.indices {
            if let idx = repositoriesConfig.groups[gi].repositories
                .firstIndex(where: { $0.id == repo.id }) {
                moved = repositoriesConfig.groups[gi].repositories.remove(at: idx)
                break
            }
        }
        if moved == nil,
           let idx = repositoriesConfig.ungrouped.firstIndex(where: { $0.id == repo.id }) {
            moved = repositoriesConfig.ungrouped.remove(at: idx)
        }
        guard let entry = moved else { return }

        if let groupName,
           let idx = repositoriesConfig.groups.firstIndex(where: { $0.name == groupName }) {
            repositoriesConfig.groups[idx].repositories.append(entry)
        } else {
            repositoriesConfig.ungrouped.append(entry)
        }
        try? await config.saveRepositories(repositoriesConfig)
        statusText = "Moved \(entry.name) → \(groupName ?? "Other")"
    }

    /// Reorder / move a repository so it lands immediately *before*
    /// `beforeRepoID` inside `groupName` (`nil` = the ungrouped "Other"
    /// bucket). A `nil` `beforeRepoID` drops it at the end of the target
    /// group. This is the index-aware companion to
    /// `moveRepository(_:toGroup:)` — it backs drag-reordering both within
    /// a group and across groups. The entry is pulled out of its current
    /// home first so the insertion index stays correct even when source
    /// and destination are the same array.
    func moveRepository(
        _ repo: RepositoryEntry,
        toGroup groupName: String?,
        before beforeRepoID: UUID?
    ) async {
        // Dropping a row onto itself is a no-op; bail before the
        // remove/insert dance so it can't accidentally jump to the end.
        if beforeRepoID == repo.id { return }

        var moved: RepositoryEntry?
        for gi in repositoriesConfig.groups.indices {
            if let idx = repositoriesConfig.groups[gi].repositories
                .firstIndex(where: { $0.id == repo.id }) {
                moved = repositoriesConfig.groups[gi].repositories.remove(at: idx)
                break
            }
        }
        if moved == nil,
           let idx = repositoriesConfig.ungrouped.firstIndex(where: { $0.id == repo.id }) {
            moved = repositoriesConfig.ungrouped.remove(at: idx)
        }
        guard let entry = moved else { return }

        func insert(into list: inout [RepositoryEntry]) {
            if let beforeRepoID,
               let idx = list.firstIndex(where: { $0.id == beforeRepoID }) {
                list.insert(entry, at: idx)
            } else {
                list.append(entry)
            }
        }
        if let groupName,
           let idx = repositoriesConfig.groups.firstIndex(where: { $0.name == groupName }) {
            insert(into: &repositoriesConfig.groups[idx].repositories)
        } else {
            insert(into: &repositoriesConfig.ungrouped)
        }
        try? await config.saveRepositories(repositoriesConfig)
    }

    /// Reorder groups so the group identified by `groupID` lands
    /// immediately *before* `beforeGroupID`. A `nil` `beforeGroupID`
    /// moves it to the end (used when a group is dropped onto the
    /// trailing "Other" bucket). No-op when dropped onto itself.
    func moveGroup(_ groupID: UUID, before beforeGroupID: UUID?) async {
        guard groupID != beforeGroupID else { return }
        guard let from = repositoriesConfig.groups.firstIndex(where: { $0.id == groupID }) else {
            return
        }
        let group = repositoriesConfig.groups.remove(at: from)
        if let beforeGroupID,
           let to = repositoriesConfig.groups.firstIndex(where: { $0.id == beforeGroupID }) {
            repositoriesConfig.groups.insert(group, at: to)
        } else {
            repositoriesConfig.groups.append(group)
        }
        try? await config.saveRepositories(repositoriesConfig)
    }

    /// Update a repository's display alias. The folder on disk is
    /// untouched — only the sidebar label changes. Same entry stays
    /// in the same group / position so the rename doesn't
    /// reorder the panel under the user.
    func renameRepository(_ entry: RepositoryEntry, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }

        for gi in repositoriesConfig.groups.indices {
            if let ri = repositoriesConfig.groups[gi].repositories.firstIndex(where: { $0.id == entry.id }) {
                repositoriesConfig.groups[gi].repositories[ri].name = trimmed
                break
            }
        }
        if let ri = repositoriesConfig.ungrouped.firstIndex(where: { $0.id == entry.id }) {
            repositoriesConfig.ungrouped[ri].name = trimmed
        }
        if activeRepo?.id == entry.id {
            activeRepo?.name = trimmed
        }
        try? await config.saveRepositories(repositoriesConfig)
        statusText = "Renamed → \(trimmed)"
    }

    /// Point an existing entry at the folder it moved to — the "Browse…"
    /// on a "Not Found" repository's settings. The entry keeps its id, group,
    /// position and ref selection; only the path changes, plus the label when
    /// it was still just the old folder's name rather than an alias the user
    /// chose. Returns the updated entry, or a message saying why the folder
    /// was refused.
    func relocateRepository(
        _ entry: RepositoryEntry,
        to path: String
    ) async -> Result<RepositoryEntry, RelocationError> {
        let normalizedPath = Self.normalizePath(path)
        if let existing = repository(atPath: normalizedPath), existing.id != entry.id {
            return .failure(RelocationError(message: "Already in the list as \(existing.name)."))
        }
        switch await Self.detectAvailability(path: normalizedPath, git: git) {
        case .available:
            break
        case .missingPath:
            return .failure(RelocationError(message: "That folder doesn't exist."))
        case .notRepository:
            return .failure(RelocationError(message: "That folder isn't the root of a Git repository."))
        case nil:
            return .failure(RelocationError(message: "Git didn't answer — try again."))
        }

        // The sheet's copy may be older than what the list holds now.
        guard let stored = allRepositories.first(where: { $0.id == entry.id }) else {
            return .failure(RelocationError(message: "This repository is no longer in the list."))
        }
        let oldFolderName = URL(fileURLWithPath: stored.path).lastPathComponent
        let keepsAlias = stored.name != oldFolderName
        var updated = stored
        updated.path = normalizedPath
        if !keepsAlias {
            updated.name = URL(fileURLWithPath: normalizedPath).lastPathComponent
        }
        updated.currentBranch = (try? await git.currentBranch(repoPath: normalizedPath)) ?? nil

        for gi in repositoriesConfig.groups.indices {
            if let ri = repositoriesConfig.groups[gi].repositories.firstIndex(where: { $0.id == entry.id }) {
                repositoriesConfig.groups[gi].repositories[ri] = updated
            }
        }
        if let ri = repositoriesConfig.ungrouped.firstIndex(where: { $0.id == entry.id }) {
            repositoriesConfig.ungrouped[ri] = updated
        }
        try? await config.saveRepositories(repositoriesConfig)
        await refreshAvailability(for: updated)
        if activeRepo?.id == entry.id {
            await selectRepo(updated)
        }
        statusText = "Relocated \(updated.name) → \(normalizedPath)"
        return .success(updated)
    }

    struct RelocationError: Error, Equatable {
        let message: String
    }

    func removeRepository(_ entry: RepositoryEntry) async {
        let path = entry.path
        var isDirectory: ObjCBool = false
        let folderExists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        pendingRepositoryRemoval = RepositoryRemovalTarget(
            repository: entry,
            folderExists: folderExists
        )
    }

    func cancelRepositoryRemoval() {
        pendingRepositoryRemoval = nil
        statusText = "Remove repository cancelled"
    }

    @discardableResult
    func confirmRepositoryRemoval(
        _ target: RepositoryRemovalTarget,
        choice: RepositoryRemovalChoice
    ) async -> Bool {
        guard pendingRepositoryRemoval?.id == target.id else { return false }
        guard choice != .cancel else {
            cancelRepositoryRemoval()
            return true
        }

        let entry = target.repository
        let path = entry.path

        if choice == .moveFolderToTrash {
            let action = "Move repository folder to Trash"
            let id = output.begin(action: action, command: "trash \(path)")
            do {
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: path, isDirectory: true),
                    resultingItemURL: nil
                )
                output.finish(
                    id: id,
                    status: .success,
                    detail: "Moved \(path) to Trash"
                )
            } catch {
                output.finish(
                    id: id,
                    status: .failure,
                    detail: error.localizedDescription
                )
                statusText = "Could not move folder to Trash"
                return false
            }
        }

        for i in repositoriesConfig.groups.indices {
            repositoriesConfig.groups[i].repositories.removeAll { $0.id == entry.id }
        }
        repositoriesConfig.ungrouped.removeAll { $0.id == entry.id }
        try? await config.saveRepositories(repositoriesConfig)
        pendingRepositoryRemoval = nil

        // Removing the active repo just unloads it. We don't auto-
        // jump to another repo — silently switching context after a
        // destructive action is surprising. The panels fall back to
        // their empty states, and the user picks the next repo
        // explicitly from the sidebar when they're ready.
        if activeRepo?.id == entry.id {
            closeActiveRepo()
        }
        statusText = choice == .moveFolderToTrash
            ? "Moved \(entry.name) to Trash"
            : "Removed \(entry.name) from list"
        return true
    }

    /// Prompt for one or more folders and open the last repo added.
    /// Pass `targetGroup` to drop the new repo into a specific group
    /// (e.g. when invoked from a group's right-click menu).
    @discardableResult
    func presentOpenRepository(targetGroup: String? = nil) -> Task<Void, Never>? {
        let urls = platform.pickRepositoryFolders()
        guard !urls.isEmpty else { return nil }
        return Task { await addRepositories(at: urls.map(\.path), group: targetGroup) }
    }

    /// Create an empty group in the repositories config. If a group with the
    /// same trimmed name already exists, no-op and surface a status note so
    /// the user knows why nothing changed.
    func addGroup(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if repositoriesConfig.groups.contains(where: { $0.name == trimmed }) {
            statusText = "Group \"\(trimmed)\" already exists"
            return
        }
        repositoriesConfig.groups.append(RepositoryGroup(name: trimmed))
        try? await config.saveRepositories(repositoriesConfig)
        statusText = "Added group \"\(trimmed)\""
    }

    /// Rename a group in place. Refuses no-ops and collisions with
    /// an existing name. Position in the list is preserved so the
    /// rename doesn't visually jump the row out from under the user.
    func renameGroup(from oldName: String, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        if repositoriesConfig.groups.contains(where: { $0.name == trimmed }) {
            statusText = "Group \"\(trimmed)\" already exists"
            return
        }
        guard let idx = repositoriesConfig.groups.firstIndex(where: { $0.name == oldName }) else {
            return
        }
        repositoriesConfig.groups[idx].name = trimmed
        try? await config.saveRepositories(repositoriesConfig)
        statusText = "Renamed \"\(oldName)\" → \"\(trimmed)\""
    }

    /// Remove a group from the sidebar. The group's repositories
    /// are *not* deleted — they migrate to the ungrouped "Other"
    /// bucket so the user doesn't lose work-tree references just
    /// because they wanted a cleaner layout.
    func deleteGroup(name: String) async {
        guard let idx = repositoriesConfig.groups.firstIndex(where: { $0.name == name }) else {
            return
        }
        let displaced = repositoriesConfig.groups[idx].repositories
        repositoriesConfig.groups.remove(at: idx)
        repositoriesConfig.ungrouped.append(contentsOf: displaced)
        try? await config.saveRepositories(repositoriesConfig)
        statusText = displaced.isEmpty
            ? "Deleted group \"\(name)\""
            : "Deleted \"\(name)\" — moved \(displaced.count) repo\(displaced.count == 1 ? "" : "s") to Other"
    }

    /// Clone `remoteURL` into `destinationParent`/`folderName`. On success
    /// the new working tree is registered under `groupName` (or as
    /// ungrouped when nil) and selected as the active repository.
    func cloneRepository(
        remoteURL: String,
        destinationParent: String,
        folderName: String,
        groupName: String?
    ) async {
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = destinationParent.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !parent.isEmpty, !folder.isEmpty else {
            statusText = "Clone — missing URL or destination"
            return
        }
        let action = "Clone \(url)"
        let id = output.begin(action: action, command: "")
        statusText = "\(action)…"
        inFlightCount += 1
        defer { inFlightCount -= 1 }
        do {
            let (result, clonedPath) = try await git.clone(
                remoteURL: url,
                destinationParent: parent,
                folderName: folder
            )
            output.finish(id: id, result: result)
            if result.succeeded {
                statusText = "Cloned into \(clonedPath)"
                await addRepository(at: clonedPath, group: groupName)
            } else {
                statusText = Self.failureStatus("Clone", result: result)
                // Same credentials wall pull and push hit, reached before
                // there is a repository to hit it from. git removes the
                // half-made directory when a clone fails this early, so the
                // retry starts from clean ground.
                if let needed = GitCredentials.urlNeedingCredentials(in: result.combinedOutput),
                   let parts = GitCredentials.components(of: needed) {
                    credentialRetry = { [weak self] in
                        await self?.cloneRepository(
                            remoteURL: url,
                            destinationParent: parent,
                            folderName: folder,
                            groupName: groupName
                        )
                    }
                    credentialRequest = CredentialRequest(
                        action: "Clone",
                        url: needed,
                        scheme: parts.scheme,
                        host: parts.host,
                        suggestedUsername: parts.username,
                        repoPath: nil
                    )
                }
            }
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            statusText = "Clone — error"
        }
    }

    // MARK: - Toolbar actions

    /// The pull the toolbar's main button performs: whichever mode the
    /// user last picked from its menu.
    var pullUsesRebase: Bool { appConfig.pullUsesRebase }

    /// A pull whose mode the user picked deliberately. The choice sticks,
    /// so the next click of the button repeats it rather than asking
    /// again — merge-or-rebase is a habit, not a per-pull decision.
    func pullChoosingMode(rebase: Bool) async {
        if appConfig.pullUsesRebase != rebase {
            appConfig.pullUsesRebase = rebase
            await saveAppConfig()
        }
        _ = await pull(rebase: rebase)
    }

    /// Repeat the remembered choice. Separate from `pullChoosingMode` so
    /// that clicking the button can't quietly become a way of *changing*
    /// the remembered mode.
    func pullUsingRememberedMode() async {
        _ = await pull(rebase: appConfig.pullUsesRebase)
    }

    @discardableResult
    func pull(rebase: Bool = false) async -> Bool {
        await runGit(
            action: rebase ? "Pull (Rebase)" : "Pull",
            refreshOnFailure: true,
            forceBranches: true,
            autostashAware: true
        ) { repo in
            try await self.git.pull(repoPath: repo, rebase: rebase)
        } onSuccess: {
            self.coordinator.after(.pull)
        } onFailure: {
            self.coordinator.invalidateAll()
        }
    }

    @discardableResult
    /// `allowLeaseRecovery` is cleared on the retry that follows a fetch, so
    /// a lease that is *still* stale reports rather than loops.
    func push(
        force: Bool = false,
        tags: Bool = false,
        allowLeaseRecovery: Bool = true
    ) async -> Bool {
        // Capture the final git result so the rejection handler below can
        // inspect stderr after `runGit` has reported the outcome.
        var lastResult: GitCommandResult?
        let ok = await runGit(action: force ? "Force Push" : (tags ? "Push Tags" : "Push"), forceBranches: true) { repo in
            var result = try await self.git.push(repoPath: repo, force: force, tags: tags)
            // First push of a branch that has no upstream yet: create the
            // remote branch and set tracking in one step. This is the easy
            // case — no decision for the user to make, just do it.
            if !result.succeeded, !force, !tags,
               Self.pushFailedMissingUpstream(result),
               let remote = try await self.preferredPushRemote(repoPath: repo),
               let branch = try await self.git.currentBranch(repoPath: repo) {
                result = try await self.git.pushTo(
                    repoPath: repo,
                    remote: remote,
                    localBranch: branch,
                    setUpstream: true
                )
            }
            lastResult = result
            return result
        } onSuccess: {
            // `.push` retires the local-branch list as well, which is what a
            // set-upstream push needs: the new upstream arrow comes from there.
            self.coordinator.after(.push)
        }
        // Git pushed nothing because it would have had to guess: the branch
        // and its upstream have different names. Nothing about the state is
        // wrong and no reconciling is needed — the command just has to name
        // the upstream. Applies to a force push too, which is where the
        // other recoveries below stop.
        if !ok, let result = lastResult, Self.pushFailedUpstreamNameMismatch(result) {
            return await pushNamingTheUpstream(force: force, tags: tags)
        }
        // The lease a force push holds is the remote-tracking ref, and it is
        // out of date: the remote has moved since the last fetch. That is the
        // one thing `--force-with-lease` exists to catch, so it is also the
        // one push failure worth walking the user through rather than
        // reporting.
        if !ok, force, allowLeaseRecovery,
           let result = lastResult, Self.pushRejectedStaleLease(result) {
            return await pushAfterStaleLease(tags: tags)
        }
        if ok || force || tags { return ok }

        // Hard case: the remote rejected the push because it has commits we
        // don't (non-fast-forward). Let the user choose how to reconcile.
        guard let result = lastResult, Self.pushRejectedNonFastForward(result) else {
            return false
        }
        let branch = branchesVM.currentBranch ?? "this branch"
        var remote = "the remote"
        if let path = activeRepo?.path,
           let resolved = try? await preferredPushRemote(repoPath: path) {
            remote = resolved
        }
        switch platform.resolvePushRejection(branch: branch, remote: remote) {
        case .pullThenPush:
            let pulled = await pull(rebase: true)
            await refreshInProgressOperation()
            guard pulled, inProgressOperation == nil else {
                statusText = "Push paused — finish the pull, then push again"
                return false
            }
            return await push()
        case .forcePush:
            return await push(force: true)
        case .cancel:
            statusText = "Push cancelled"
            return false
        }
    }

    /// Recovery for a force push refused as `stale info`.
    ///
    /// The lease is the remote-tracking ref, and it is behind the real remote
    /// — somebody pushed since this repository last fetched. Git is right to
    /// stop: the commits it is protecting are ones nobody here has ever seen,
    /// so there is no way to have decided they were expendable.
    ///
    /// So the fetch happens first, and then the decision is put to the user
    /// with the commits named. Answering yes pushes again with the lease now
    /// current, which is exactly what `--force-with-lease` is for: look at
    /// what arrived, then overwrite it deliberately. A plain `--force` would
    /// have gone through the first time and taken them with it silently.
    private func pushAfterStaleLease(tags: Bool) async -> Bool {
        guard let repo = activeRepo else { return false }
        statusText = "Remote has moved — fetching before the force push"
        guard await fetch() else { return false }

        let gap = (try? await git.upstreamGap(repoPath: repo.path)) ?? nil
        // Nothing of the remote's own left to lose: the fetch caught this
        // branch up, and the force push can simply be retried.
        guard let gap, !gap.isEmpty else {
            return await push(force: true, tags: tags, allowLeaseRecovery: false)
        }

        let confirmed = confirmDestructiveGitAction(
            title: "Force push over \(gap.incoming.count) commit\(gap.incoming.count == 1 ? "" : "s") on \(gap.ref)?",
            message: """
            \(gap.ref) has work this repository had not fetched:

            \(await incomingSummary(repoPath: repo.path, gap: gap))

            Force pushing replaces the remote branch with yours, and those \
            commits stop being reachable from it.
            """,
            primaryButton: "Force Push"
        )
        guard confirmed else {
            statusText = "Force push cancelled — \(gap.ref) has commits you don't"
            return false
        }
        return await push(force: true, tags: tags, allowLeaseRecovery: false)
    }

    /// The subjects of what the fetch brought in, for the confirmation above.
    /// Named, not counted: "two commits" is not something anyone can weigh,
    /// and this is the last screen before they stop being on the branch.
    private func incomingSummary(repoPath: String, gap: UpstreamGap) async -> String {
        let limit = 5
        let commits = (try? await git.log(
            repoPath: repoPath,
            count: limit,
            revisions: ["HEAD..\(gap.ref)"]
        )) ?? []
        guard !commits.isEmpty else {
            return gap.incoming.sorted().map { "\u{2022} \($0.prefix(7))" }.joined(separator: "\n")
        }
        var lines = commits.map { "\u{2022} \($0.shortHash)  \($0.subject)" }
        let rest = gap.incoming.count - commits.count
        if rest > 0 { lines.append("\u{2022} \u{2026} and \(rest) more") }
        return lines.joined(separator: "\n")
    }

    /// Remote to target when a branch has no configured upstream. Prefers
    /// `origin`, otherwise the first configured remote, or nil when none.
    private func preferredPushRemote(repoPath: String) async throws -> String? {
        let remotes = try await git.remotes(repoPath: repoPath)
        if remotes.contains("origin") { return "origin" }
        return remotes.first
    }

    /// Recovery for the one push failure git refuses to resolve itself: the
    /// current branch and its upstream have different names, and
    /// `push.default = simple` will not pick between "the branch you track"
    /// and "the branch of the same name". Git prints both commands and
    /// stops.
    ///
    /// SmallGit offers the first of them — name the upstream explicitly —
    /// but does not run it unasked. This is the same call that failed a
    /// moment ago, now with `--force-with-lease` still on it in the force
    /// case: the one command in the app that can overwrite work someone
    /// else pushed. So it goes to the user as a button, with the exact
    /// argv it will run written out, and nothing happens if they say no.
    private func pushNamingTheUpstream(force: Bool, tags: Bool) async -> Bool {
        guard let repo = activeRepo else { return false }
        let branch = (try? await git.currentBranch(repoPath: repo.path)) ?? nil
        guard let branch else { return false }
        let upstream = (try? await git.upstreamOfBranch(
            repoPath: repo.path,
            branch: branch
        )) ?? nil
        // No upstream to name means this was some other failure wearing the
        // same words — leave the reported error as it stands.
        guard let upstream else { return false }

        let command = "git " + GitService.pushToArguments(
            remote: upstream.remote,
            localBranch: branch,
            remoteBranch: upstream.branch,
            force: force,
            tags: tags
        ).joined(separator: " ")
        let target = "\(upstream.remote)/\(upstream.branch)"
        var message = """
        Nothing was pushed. “\(branch)” tracks “\(target)”, and git will not \
        guess whether you meant the branch you track or a branch of your own \
        name on the remote.

        SmallGit can name the upstream branch explicitly:

            \(command)
        """
        if force {
            message += """


            A force push replaces \(target) with your local branch and can \
            discard commits someone else pushed.
            """
        }
        let confirmed = confirmDestructiveGitAction(
            title: force ? "Force push to \(target)?" : "Push to \(target)?",
            message: message,
            primaryButton: force ? "Force Push" : "Push"
        )
        guard confirmed else {
            statusText = "Push cancelled"
            return false
        }
        return await runGit(
            action: force ? "Force Push" : "Push",
            forceBranches: true
        ) { repo in
            try await self.git.pushTo(
                repoPath: repo,
                remote: upstream.remote,
                localBranch: branch,
                remoteBranch: upstream.branch,
                force: force,
                tags: tags
            )
        } onSuccess: {
            self.coordinator.after(.push)
        }
    }

    /// True when a push failed only because the current branch has no
    /// upstream branch configured yet (git's "has no upstream branch").
    private static func pushFailedMissingUpstream(_ result: GitCommandResult) -> Bool {
        result.combinedOutput.localizedCaseInsensitiveContains("has no upstream branch")
    }

    /// True when a push failed only because the current branch and its
    /// upstream have different names, so `push.default = simple` refused to
    /// guess which one was meant. Git prints the two commands that would
    /// work and pushes nothing.
    ///
    /// Git wraps that sentence across two lines, so the whitespace is
    /// flattened before matching — a plain `contains` on the sentence finds
    /// nothing in the real output.
    nonisolated static func pushFailedUpstreamNameMismatch(_ result: GitCommandResult) -> Bool {
        result.combinedOutput
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(
                "does not match the name of your current branch"
            )
    }

    /// True when a force push was refused because the lease was stale — the
    /// remote is not where this repository last saw it.
    ///
    /// Git spells it `! [rejected] main -> main (stale info)`, which says
    /// nothing about what is stale or what to do. It is not the same failure
    /// as a non-fast-forward: that one means "you are behind", this one means
    /// "you are behind something you have never even fetched".
    nonisolated static func pushRejectedStaleLease(_ result: GitCommandResult) -> Bool {
        let out = result.combinedOutput.lowercased()
        return out.contains("stale info") && out.contains("[rejected]")
    }

    /// True when the remote rejected the push as non-fast-forward — i.e. it
    /// holds commits the local branch is missing and must be reconciled.
    private static func pushRejectedNonFastForward(_ result: GitCommandResult) -> Bool {
        let out = result.combinedOutput.lowercased()
        return out.contains("[rejected]")
            || out.contains("non-fast-forward")
            || out.contains("fetch first")
            || (out.contains("failed to push") && out.contains("behind"))
    }

    func sync() async {
        let pulled = await pull(rebase: true)
        await refreshInProgressOperation()
        guard pulled, inProgressOperation == nil else {
            statusText = "Sync stopped — pull did not complete cleanly"
            return
        }
        // A pull that autostashed can succeed and still leave the tree
        // conflicted, because putting the changes back is a separate step
        // from the pull. Pushing over that is not what "sync" means.
        guard !filesVM.files.contains(where: \.isConflict) else {
            statusText = "Sync stopped — resolve the conflicts before pushing"
            return
        }
        await push()
    }

    @discardableResult
    func fetch() async -> Bool {
        await runGit(action: "Fetch") { repo in
            try await self.git.fetch(repoPath: repo)
        } onSuccess: {
            self.coordinator.after(.fetch)
        }
    }

    func commit(subject: String, body: String? = nil, amend: Bool = false) async {
        guard !subject.isEmpty else { return }
        // `forceBranches: true`: a commit moves the current branch tip, so its
        // ahead/behind (`upstreamTrack`) count changes. Without forcing, the
        // Branches panel reloads from the still-warm `.branchList` cache and
        // keeps showing the pre-commit count.
        await runGit(action: amend ? "Commit (Amend)" : "Commit", forceBranches: true) { repo in
            try await self.git.commit(repoPath: repo, subject: subject, body: body, amend: amend)
        } onSuccess: {
            self.coordinator.after(.commit)
            self.showCommitDialog = false
            self.commitMessageDraft = ""
            let full = body.map { "\(subject)\n\n\($0)" } ?? subject
            self.recordRecentCommitMessage(full)
        }
    }

    /// Push `message` onto the kept list of recently-used commit messages
    /// (most-recent first, de-duplicated, capped at 10) and persist it.
    /// Powers the commit dialog's "Recent Messages" reuse menu.
    func recordRecentCommitMessage(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = appConfig.recentCommitMessages
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        appConfig.recentCommitMessages = list
        Task { try? await config.saveAppConfig(appConfig) }
    }

    /// Full messages of the most recent commits in the active repo's log, for the
    /// commit dialog's "Recent Commits" reuse menu. Empty when no repo/log.
    func recentCommitMessages(limit: Int = 10) async -> [String] {
        guard let repo = activeRepo?.path,
              let messages = try? await git.recentCommitMessages(repoPath: repo, count: limit)
        else { return [] }
        return messages
    }

    func commitAndPush(subject: String, body: String? = nil, amend: Bool = false) async {
        await commit(subject: subject, body: body, amend: amend)
        await push()
    }

    /// True when the files went into the index — false when there was
    /// nothing to stage, the user backed out of the conflict-marker warning,
    /// or git refused.
    @discardableResult
    func stage(files: [String]) async -> Bool {
        guard !files.isEmpty else { return false }
        if let repo = activeRepo?.path,
           !filesContainingConflictMarkers(files, repoPath: repo).isEmpty,
           !confirmStageWithConflictMarkers() {
            statusText = "Stage cancelled"
            return false
        }
        let ok = await runGit(action: "Stage") { repo in
            try await self.git.stage(repoPath: repo, files: files)
        } onSuccess: {
            self.coordinator.after(.stage(files: files))
        }
        if ok { await diffVM.reloadAfterStaging() }
        return ok
    }

    /// Heuristic scan for git conflict markers — the standard 7-char
    /// `<<<<<<<` / `=======` / `>>>>>>>` line prefixes. Used to warn
    /// before staging so the user doesn't accidentally commit a half-
    /// resolved merge (matches SmartGit's safety prompt).
    private func filesContainingConflictMarkers(_ files: [String], repoPath: String) -> [String] {
        files.filter { rel in
            let abs = (repoPath as NSString).appendingPathComponent(rel)
            guard let contents = try? String(contentsOfFile: abs, encoding: .utf8) else { return false }
            // `isNewline` rather than the `\n` character, so a file with CRLF
            // endings is cut into lines at all — Swift reads the pair as one
            // grapheme. See `holdsConflictBlock`, which makes the same call.
            for line in contents.split(
                maxSplits: .max, omittingEmptySubsequences: false, whereSeparator: \.isNewline
            ) {
                if line.hasPrefix("<<<<<<< ") || line == "=======" || line.hasPrefix(">>>>>>> ") {
                    return true
                }
            }
            return false
        }
    }

    private func confirmStageWithConflictMarkers() -> Bool {
        confirmDestructiveGitAction(
            title: "Do you want to stage files with conflict markers?",
            message: """
            At least one of the files you are trying to stage seems to contain Git conflict markers. Usually this indicates a conflict which was resolved incorrectly or not yet at all.

            If the detected conflict markers are actually valid file content and intentional, you may proceed.
            """,
            primaryButton: "Stage Anyway"
        )
    }

    private func confirmDestructiveGitAction(
        title: String,
        message: String,
        primaryButton: String
    ) -> Bool {
        platform.confirmWarning(
            title: title,
            message: message,
            primaryButton: primaryButton
        )
    }

    /// Resolves `path` by taking the current branch's version (`HEAD` /
     /// stage 2) and staging it. Used by the conflict quick-action banner.
    func acceptOurs(path: String) async {
        let ok = await runGit(action: "Take Ours") { repo in
            try await self.git.acceptOurs(repoPath: repo, path: path)
        } onSuccess: {
            self.coordinator.after(.stage(files: [path]))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    /// Resolves `path` by taking the incoming branch's version (stage 3)
    /// and staging it.
    func acceptTheirs(path: String) async {
        let ok = await runGit(action: "Take Theirs") { repo in
            try await self.git.acceptTheirs(repoPath: repo, path: path)
        } onSuccess: {
            self.coordinator.after(.stage(files: [path]))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    /// Stages whatever's currently on disk as the resolution. Routes
    /// through `stage(files:)` so the conflict-marker safety prompt
    /// fires if the user forgot to clean up.
    func markConflictResolved(path: String) async {
        await stage(files: [path])
    }

    /// Take files back out of the index — every path except a conflicted one.
    ///
    /// `git reset` on an unmerged path does not unstage it, it *destroys* it:
    /// the three stages collapse into one entry matching HEAD, and the file
    /// git was calling a conflict becomes an ordinary modification that still
    /// has `<<<<<<<` markers in it. Nothing on screen says a conflict was ever
    /// there — no Conflict state, no resolver, and a banner reading "all
    /// conflicts resolved" over a Continue button that git then refuses,
    /// because the leftover unstaged change blocks `rebase --continue`.
    ///
    /// Unstaging a conflict means nothing anyway: its stages are not something
    /// the user staged. So conflicted paths are dropped here rather than
    /// passed to git, and the menus that offer the action grey it out when
    /// that is all the selection holds.
    func unstage(files: [String]) async {
        guard !files.isEmpty else { return }
        let conflicted = Set(filesVM.files.filter(\.isConflict).map(\.path))
        let unstageable = files.filter { !conflicted.contains($0) }
        guard !unstageable.isEmpty else {
            statusText = files.count == 1
                ? "Nothing to unstage — the file is conflicted"
                : "Nothing to unstage — the selected files are conflicted"
            return
        }
        let skipped = files.count - unstageable.count
        let ok = await runGit(action: "Unstage") { repo in
            try await self.git.unstage(repoPath: repo, files: unstageable)
        } onSuccess: {
            self.coordinator.after(.unstage(files: unstageable))
        }
        if ok {
            if skipped > 0 {
                statusText = "Unstage — done, skipped \(skipped) conflicted file\(skipped == 1 ? "" : "s")"
            }
            await diffVM.reloadAfterStaging()
        }
    }

    func discard(files: [String]) async {
        guard !files.isEmpty else { return }
        let ok = await runGit(action: "Discard") { repo in
            try await self.git.discard(repoPath: repo, files: files)
        } onSuccess: {
            self.coordinator.after(.discard(files: files))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    /// Discard a mixed selection, running each kind of file through the
    /// command that can actually discard it.
    ///
    /// One `git checkout --` over everything is what this used to do, and it
    /// failed whenever the selection held an untracked file ("did not match
    /// any file(s) known to git") or a conflicted one ("path ... is
    /// unmerged"). Neither is a partial failure: git checks every pathspec
    /// before it touches the working tree, so one bad path meant nothing was
    /// discarded — including the files that were perfectly discardable.
    ///
    /// The three run in order of increasing irreversibility, and a failure
    /// stops the sequence: deleting untracked files last means a repo that
    /// refuses the earlier steps has not already lost the files that git
    /// isn't storing anywhere.
    func discard(plan: FilesViewModel.DiscardPlan) async {
        guard !plan.isEmpty else { return }
        let ok = await runGit(action: "Discard") { repo in
            var last = GitCommandResult.outcome("discard")
            if !plan.tracked.isEmpty {
                last = try await self.git.discard(repoPath: repo, files: plan.tracked)
            }
            if !plan.conflicted.isEmpty {
                last = try await self.git.discardConflicted(repoPath: repo, files: plan.conflicted)
            }
            if !plan.untracked.isEmpty {
                last = try await self.git.cleanUntracked(repoPath: repo, paths: plan.untracked)
            }
            return last
        } onSuccess: {
            self.coordinator.after(.discard(files: plan.all))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    /// Delete untracked files (`git clean`). Destructive and unrecoverable —
    /// untracked files aren't stored in Git — so it always confirms first.
    func discardUntracked(paths: [String]) async {
        guard !paths.isEmpty else { return }
        let subject = paths.count == 1 ? paths[0] : "\(paths.count) untracked files"
        guard confirmDestructiveGitAction(
            title: paths.count == 1 ? "Delete untracked file?" : "Delete untracked files?",
            message: "This permanently deletes \(subject) from disk. Untracked files are not stored in Git, so this cannot be undone.",
            primaryButton: "Delete"
        ) else {
            statusText = "Clean cancelled"
            return
        }
        let ok = await runGit(action: "Clean Untracked") { repo in
            try await self.git.cleanUntracked(repoPath: repo, paths: paths)
        } onSuccess: {
            self.coordinator.after(.discard(files: paths))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    // MARK: - Patches

    /// Generates patch text for `source` and writes it to `destination`.
    /// Runs outside `runGit` because the heavy lifting is the file I/O
    /// — there's no git index mutation to invalidate caches over.
    func writePatch(source: PatchSource, to destination: URL) async {
        guard let repo = activeRepo else {
            statusText = "No active repository"
            return
        }
        let action = "Create Patch"
        let logID = output.begin(action: action, command: "git diff → \(destination.lastPathComponent)")
        do {
            let patch: String
            switch source {
            case .files(let paths, _):
                patch = try await git.createPatch(repoPath: repo.path, files: paths)
            case .commit(let hash, _):
                patch = try await git.createPatch(repoPath: repo.path, commitHash: hash)
            case .stash(let index, _):
                patch = try await git.createPatch(repoPath: repo.path, stashIndex: index)
            }
            if patch.isEmpty {
                output.finish(id: logID, status: .failure, detail: "patch is empty (no changes to capture)")
                statusText = "Create Patch — nothing to write"
                return
            }
            try patch.write(to: destination, atomically: true, encoding: .utf8)
            output.finish(
                id: logID,
                status: .success,
                detail: """
                Patch saved: \(destination.lastPathComponent)
                \(destination.path)
                \(patch.utf8.count) bytes
                """,
                link: OutputLink(label: "Open in Finder", path: destination.path)
            )
            statusText = "Patch saved → \(destination.lastPathComponent)"
        } catch {
            output.finish(id: logID, status: .failure, detail: String(describing: error))
            statusText = "Create Patch — error"
        }
    }

    /// Apply a `.patch` file to the working tree. Wrapped in `runGit`
    /// so the post-apply panel refresh / cache invalidation runs.
    func applyPatchFile(at url: URL, threeWay: Bool = false) async {
        await runGit(action: "Apply Patch") { repo in
            try await self.git.applyPatchFile(
                repoPath: repo,
                patchPath: url.path,
                threeWay: threeWay
            )
        } onSuccess: {
            // `git apply` mutates the working tree. We don't know which
            // files the patch touched without parsing it, so just nuke
            // the broad file-status cache and let `refreshPanels` rerun.
            self.coordinator.invalidate(.fileStatus)
        }
    }

    /// When non-nil, the next Save Stash dialog stashes only these
    /// files instead of everything. Set by the Files context menu's
    /// "Stash Selected…"; cleared when the dialog closes.
    var pendingStashScope: PendingStashScope?

    /// Options the next Save Stash dialog opens with, for the toolbar
    /// entries that used to save straight away under git's "WIP on …"
    /// name. They open the dialog pre-set instead, so the stash gets a name.
    /// Cleared when the dialog closes.
    var pendingStashPreset: StashPreset?

    struct StashPreset {
        var includeUntracked = false
        var snapshot = false
    }

    /// Open the Save Stash dialog with some options already ticked.
    func openStashSaveDialog(_ preset: StashPreset) {
        pendingStashPreset = preset
        showStashSaveDialog = true
    }

    struct PendingStashScope {
        /// Pathspecs handed to `git stash push --` (renames expand to
        /// old + new path so the move stashes as a unit).
        let paths: [String]
        /// `true` when the selection contains untracked files — the
        /// dialog pre-checks "Include untracked" because plain
        /// `stash push -- <path>` silently skips them.
        let includesUntracked: Bool
    }

    func stashSave(
        message: String? = nil,
        includeUntracked: Bool = false,
        keepIndex: Bool = false,
        paths: [String] = []
    ) async {
        let action = paths.isEmpty
            ? "Save Stash"
            : "Stash \(paths.count) File\(paths.count == 1 ? "" : "s")"
        await runGit(action: action) { repo in
            try await self.git.stashSave(
                repoPath: repo,
                message: message,
                includeUntracked: includeUntracked,
                keepIndex: keepIndex,
                paths: paths
            )
        } onSuccess: {
            self.coordinator.after(.stashSave)
        }
    }

    /// The other half of Save Stash: record the entry and leave every file
    /// where it is. Neither `keepIndex` nor a path scope has a meaning here —
    /// a snapshot reverts nothing, so there is nothing for `--keep-index` to
    /// keep, and `git stash create` accepts no pathspec, so it is always the
    /// whole working tree.
    func stashSnapshot(message: String? = nil, includeUntracked: Bool = false) async {
        await runGit(action: "Save Snapshot") { repo in
            try await self.git.stashSnapshot(
                repoPath: repo,
                message: message,
                includeUntracked: includeUntracked
            )
        } onSuccess: {
            // The same invalidation as a save. Nothing in the working tree
            // moved, so the file-status half is redundant — one `git status`
            // is cheaper than a second rule that has to stay in step.
            self.coordinator.after(.stashSave)
        }
    }

    func stashApply(index: Int = 0) async {
        await applyStash(index: index, action: "Apply Stash") { repo in
            try await self.git.stashApply(repoPath: repo, index: index)
        }
    }

    func stashPop() async {
        await applyStash(index: 0, action: "Pop Stash") { repo in
            try await self.git.stashPop(repoPath: repo)
        }
    }

    /// Shared body of apply and pop, so both can leave a way back out.
    ///
    /// A stash that conflicts leaves no marker git can unwind — see
    /// `GitService.abortStashApply` — so the only record that an apply is
    /// half-done is the one we keep here. The file list is read *before*
    /// running, while the stash is still addressable: a pop that conflicts
    /// keeps the entry, but an abort followed by a successful pop would
    /// renumber it, and `stash@{0}` is not a stable name to come back to.
    private func applyStash(
        index: Int,
        action: String,
        operation: @escaping (String) async throws -> GitCommandResult
    ) async {
        let touched: [String]
        if let repo = activeRepo {
            touched = (try? await git.stashFiles(repoPath: repo.path, index: index))?.map(\.path) ?? []
        } else {
            touched = []
        }
        await runGit(action: action, operation: operation) {
            self.coordinator.after(.stashApply)
        }
        await filesVM.load()
        await refreshInProgressOperation()
        if filesVM.files.contains(where: \.isConflict), !touched.isEmpty {
            // Observed beats inferred: we know exactly which stash this was.
            stashApplyConflict = StashApplyConflict(files: touched)
            stashApplyProbed = true
        } else {
            stashApplyConflict = nil
            stashApplyProbed = false
        }
    }

    /// Restore the files a conflicted stash apply disturbed, and forget it.
    func abortStashApply() async {
        guard let conflict = stashApplyConflict else { return }

        // Only the stash's files that this working tree actually has changes
        // for. A file the stash touched but the tree is clean on has nothing
        // to restore, and when the stash was matched by inference rather than
        // observed, narrowing to what is dirty keeps the reach to what the
        // apply plausibly did.
        let dirty = Set(filesVM.files.map(\.path))
        var restore = conflict.files.filter { dirty.contains($0) }
        if restore.isEmpty {
            restore = filesVM.files.filter(\.isConflict).map(\.path)
        }
        guard !restore.isEmpty else {
            statusText = "Nothing to restore"
            return
        }

        let subject = restore.count == 1 ? restore[0] : "\(restore.count) files"
        guard confirmDestructiveGitAction(
            title: "Abort the stash apply?",
            message: "This restores \(subject) to the last committed state, undoing what the "
                + "stash put there. Uncommitted changes of your own to those files are lost. "
                + "The stash itself is kept, so you can apply it again.",
            primaryButton: "Abort Apply"
        ) else {
            statusText = "Abort cancelled"
            return
        }

        let plan = StashApplyConflict(files: restore)
        let ok = await runGit(action: "Abort Stash Apply") { repo in
            let (result, leftInPlace) = try await self.git.abortStashApply(
                repoPath: repo,
                files: plan.files
            )
            await MainActor.run { self.stashApplyLeftInPlace = leftInPlace }
            return result
        } onSuccess: {
            self.coordinator.after(.discard(files: plan.files))
        }
        if ok {
            stashApplyConflict = nil
            let left = stashApplyLeftInPlace
            statusText = left.isEmpty
                ? "Stash apply aborted — the stash is still in the list"
                : "Stash apply aborted — \(left.count) new file\(left.count == 1 ? "" : "s") left in place, HEAD has no version to restore"
            await diffVM.reloadAfterStaging()
        }
    }

    func stashDrop(index: Int) async {
        await stashDrop(indices: [index])
    }

    func stashRename(index: Int, message: String) async {
        // Refreshed on failure too: a rename that stopped partway may have
        // changed the list, and the panel should show what is really there.
        await runGit(action: "Rename Stash @{\(index)}", refreshOnFailure: true) { repo in
            try await self.git.stashRename(repoPath: repo, index: index, message: message)
        } onSuccess: {
            // Nothing moved in the working tree; the list is what changed,
            // which is exactly what a drop invalidates.
            self.coordinator.after(.stashDrop)
        } onFailure: {
            self.coordinator.after(.stashDrop)
        }
    }

    /// Drop several stashes in one go.
    ///
    /// Every drop renumbers the entries above it — dropping stash@{1} turns
    /// stash@{3} into stash@{2} — so a list of indices taken from the visible
    /// order goes stale the moment the first one lands. Working from the
    /// highest index down leaves the ones still to go exactly where they
    /// were, which is the only ordering that drops what the user picked.
    @discardableResult
    func stashDrop(indices: [Int]) async -> Bool {
        let ordered = Set(indices).sorted(by: >)
        guard !ordered.isEmpty else { return false }

        for index in ordered {
            let ok = await runGit(action: "Drop Stash @{\(index)}") { repo in
                try await self.git.stashDrop(repoPath: repo, index: index)
            } onSuccess: {
                self.coordinator.after(.stashDrop)
            }
            // Stop on the first failure rather than carrying on down a list
            // of indices whose meaning now depends on what actually happened.
            guard ok else { return false }
        }
        return true
    }

    /// Open the stash's files-and-diff window.
    ///
    /// A window of its own rather than the main Diff panel: a stash is
    /// several files, and the panel could only ever show them as one
    /// undivided run of hunks with no way to pick one out.
    func showStashDiff(index: Int) {
        guard let stash = stashList.first(where: { $0.index == index }) else { return }
        CompareWindowPresenter.presentStash(appState: self, stash: stash)
        statusText = "Showing stash@{\(index)}"
    }

    /// Load a past commit's diff into the main Diff panel. Triggered by
    /// selecting a row in the Journal table — gives the user a SmartGit-
    /// style "browse history" experience.
    func showCommitDiff(_ commit: GitCommit) async {
        filesVM.selectedFileIDs.removeAll()
        await diffVM.loadCommitDiff(commit)
        statusText = "Showing \(commit.shortHash) — \(commit.subject)"
    }

    /// Checking out a branch, by whatever name the sidebar row carried.
    ///
    /// `GitService.checkoutBranch` is what decides between switching and
    /// creating a tracking branch, because it can ask the repository and this
    /// can only ask a cache.
    /// - Parameter offerFastForward: ask first when `branch` is a local branch
    ///   its upstream was ahead of at the last fetch, and fast-forward it on
    ///   the way in if the user says so — what checking out `main` after a
    ///   few days on a feature branch almost always wants. Off for callers
    ///   that mean an exact state, such as Undo.
    func checkout(branch: String, offerFastForward: Bool = false) async {
        var offer = false
        if offerFastForward,
           let repo = activeRepo,
           let local = branchesVM.localBranches.first(where: { $0.name == branch }),
           !local.isHead,
           local.upstream != nil,
           local.behindCount > 0 {
            // Ahead as well is either real local work, where a fast-forward
            // is bound to fail and isn't offered, or an upstream that was
            // rewritten under a branch holding only its old state — which
            // `fastForwardToUpstream` moves all the same.
            if local.aheadCount == 0 {
                offer = true
            } else {
                offer = await git.holdsOnlyFormerUpstream(repoPath: repo.path, branch: branch)
            }
        }
        if offer, let local = branchesVM.localBranches.first(where: { $0.name == branch }),
           let upstream = local.upstream {
            switch platform.resolveBehindCheckout(
                branch: branch, upstream: upstream, behind: local.behindCount
            ) {
            case .checkOutAndFastForward:
                // Before the checkout, while the branch isn't checked out:
                // the fetch that moves it refuses a checked-out branch. A
                // failure stops here, with the reason on the status line,
                // rather than switching to the stale branch regardless.
                guard await fastForwardToUpstream(branch: branch) else { return }
            case .checkOutOnly:
                break
            case .cancel:
                statusText = "Checkout cancelled"
                return
            }
        }
        let done = await runGit(action: "Checkout \(branch)", forceBranches: true) { repo in
            try await self.git.checkoutBranch(repoPath: repo, name: branch)
        } onSuccess: {
            // `.branchCreate` too: checking out a remote branch for the first
            // time makes a local one, and the branch list has to be rebuilt
            // rather than re-read.
            self.coordinator.after(.branchCreate)
            self.coordinator.after(.checkout)
        }
        // A tag or a bare commit lands on no branch at all, and git says so
        // with exit code 0 — which read as an unqualified success until the
        // next pull failed with "You are not currently on a branch".
        // `runGit` has already refreshed the panels, so this is the settled
        // answer rather than a guess.
        if done, branchesVM.currentBranch == nil {
            statusText = "Checked out \(branch) — HEAD is detached, not on a branch"
        }
    }

    /// Asks how to land `branch` the way SmartGit's Merge dialog does —
    /// Fast-Forward (when possible), Create Merge-Commit, or Merge to Working
    /// Tree — then merges. The working-tree merge stops with MERGE_HEAD set,
    /// so the in-progress banner takes over from there: Continue commits the
    /// merge with git's prepared message, Abort undoes it.
    func merge(branch: String) async {
        guard let repo = activeRepo else {
            statusText = "No active repository"
            return
        }
        let current = branchesVM.currentBranch ?? "HEAD"
        let relation = await git.mergeRelation(repoPath: repo.path, branch: branch)
        if relation == .upToDate {
            statusText = "\(current) already contains \(branch) — nothing to merge"
            return
        }
        let mode: MergeMode
        switch platform.resolveMerge(
            branch: branch,
            into: current,
            canFastForward: relation == .canFastForward
        ) {
        case .fastForward: mode = .fastForward
        case .mergeCommit: mode = .mergeCommit
        case .workingTree: mode = .workingTree
        case .cancel:
            statusText = "Merge cancelled"
            return
        }

        var lastResult: GitCommandResult?
        let done = await runGit(
            action: "Merge \(branch)",
            refreshOnFailure: true,
            forceBranches: true,
            // A working-tree merge only *sets* the stash aside; it comes back
            // on commit or abort, which report it then.
            autostashAware: mode != .workingTree
        ) { repo in
            let result = try await self.git.merge(repoPath: repo, branch: branch, mode: mode)
            lastResult = result
            return result
        } onSuccess: {
            self.coordinator.after(.merge)
        } onFailure: {
            self.coordinator.invalidateAll()
        }
        if done, mode == .workingTree {
            let stashed = lastResult.map {
                GitOutputParser.autostashOutcome(in: $0.combinedOutput) != .none
            } ?? false
            statusText = "Merged \(branch) into the working tree — review it, then Commit or Abort"
                + (stashed ? ". Your local changes are set aside until then" : "")
        }
    }

    /// When `onto` was rewritten after HEAD branched from it — a teammate
    /// rebased and force-pushed it — HEAD still carries its old commits, and
    /// a plain rebase would replay them onto their own new versions. The
    /// user is asked, with those commits named, whether to replay only their
    /// own (`--onto <onto> <fork-point>`, what `git pull --rebase` does).
    func rebase(onto: String) async {
        var from: String?
        if let repo = activeRepo {
            let stale = await git.commitsFromRewrittenBase(repoPath: repo.path, base: onto)
            if let forkPoint = stale.first?.hash {
                let own = (try? await git.commitsToRebase(repoPath: repo.path, base: forkPoint)) ?? []
                switch platform.resolveRewrittenBaseRebase(
                    onto: onto,
                    staleSubjects: stale.map(\.subject),
                    ownCount: own.count
                ) {
                case .ownOnly:
                    from = forkPoint
                case .all:
                    break
                case .cancel:
                    statusText = "Rebase cancelled"
                    return
                }
            }
        }
        await runGit(
            action: "Rebase onto \(onto)",
            refreshOnFailure: true,
            forceBranches: true,
            autostashAware: true
        ) { repo in
            try await self.git.rebase(repoPath: repo, onto: onto, from: from)
        } onSuccess: {
            self.coordinator.after(.rebase)
        } onFailure: {
            self.coordinator.invalidateAll()
        }
    }

    /// Entry point for interactive rebase: works out what a rebase onto `onto`
    /// would replay, then opens `InteractiveRebaseSheet` so the user can build
    /// the plan. The rebase itself runs in `runInteractiveRebase(plan:onto:)`.
    ///
    /// One command for both directions the user can mean by it, because git
    /// makes no distinction either — `git rebase -i <onto>` replays
    /// `<onto>..HEAD` whatever `<onto>` is. Picking a commit already on HEAD
    /// replays what comes after it; picking a branch, or any commit on another
    /// line of history, replays HEAD's own commits since the two diverged onto
    /// that branch's tip. The planner lists exactly what git would, so the
    /// sheet is where the user sees which of the two they asked for.
    ///
    /// The range is asked of git rather than read off the loaded journal:
    /// rebasing onto a sibling branch reaches back to the merge-base, which is
    /// routinely past the window the Journal has paged in.
    func startInteractiveRebase(onto: String, display: String? = nil) async {
        guard let repo = activeRepo else {
            statusText = "No active repository"
            return
        }
        let label = display ?? onto
        let id = output.begin(
            action: "List commits to rebase onto \(label)",
            command: "git log --cherry-mark --right-only \(onto)...HEAD"
        )
        do {
            let range = try await git.rebaseRange(repoPath: repo.path, base: onto)
            // Old versions of a rewritten `onto` start out dropped: replaying
            // them onto their own rewrites is what duplicates and conflicts.
            // Still rows, not hidden, so a wrong guess is one click to undo.
            let stale = Set(await git.commitsFromRewrittenBase(repoPath: repo.path, base: onto).map(\.hash))
            let initialTodo = range.todo.map { row in
                var row = row
                if stale.contains(row.hash) { row.action = .drop }
                return row
            }
            // Empty means HEAD is already on top of it — git would answer a
            // rebase with a fast-forward or a no-op, and an empty planner
            // would leave the user pressing Start on nothing.
            guard !initialTodo.isEmpty else {
                output.finish(id: id, status: .success, detail: "nothing to replay")
                // Two ways to get here, and the user did different things in
                // each: HEAD really is on top of the base, or everything HEAD
                // had is already there under other SHAs — the whole branch was
                // merged or rebased upstream while they weren't looking.
                let reason = range.alreadyOnBase.isEmpty
                    ? "Nothing to rebase — HEAD is already on top of \(label)"
                    : "Nothing to rebase — \(label) already has all \(range.alreadyOnBase.count) of these commits"
                statusText = reason
                showToast(reason)
                return
            }
            // A merge in the range cannot be replayed: git's own todo leaves
            // it out and inlines its side branch, and the todo SmallGit writes
            // would name it in a `pick` line git never generates. Refused with
            // the commit named rather than flattened behind the user's back.
            let merges = try await git.mergesToRebase(repoPath: repo.path, base: onto)
            if let merge = merges.first {
                output.finish(
                    id: id,
                    status: .failure,
                    detail: "merge \(merge) is in the range and cannot be replayed"
                )
                statusText = "Can't rebase onto \(label) — merge \(merge) would be flattened"
                showToast("Merge \(merge) is in the way — an interactive rebase would flatten it")
                return
            }
            output.finish(
                id: id,
                status: .success,
                detail: "\(initialTodo.count) commit\(initialTodo.count == 1 ? "" : "s") will be replayed"
            )
            self.pendingInteractiveRebase = InteractiveRebaseTarget(
                base: onto,
                baseDisplay: label,
                initialTodo: initialTodo,
                alreadyOnBase: range.alreadyOnBase
            )
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            statusText = "Could not list commits to rebase"
        }
    }

    /// Executes the rebase the user assembled in the planner sheet.
    /// On conflict, the in-progress operation banner appears via the
    /// existing `inProgressOperation()` polling — the user resolves via
    /// the four-pane conflict resolver and clicks Continue / Abort.
    func runInteractiveRebase(plan: [RebaseTodo], onto: String, display: String? = nil) async {
        interactiveRebaseRunning = true
        defer { interactiveRebaseRunning = false }
        await runGit(
            action: "Rebase Interactively onto \(display ?? onto)",
            refreshOnFailure: true,
            autostashAware: true
        ) { repo in
            try await self.git.runInteractiveRebase(
                repoPath: repo,
                onto: onto,
                todo: plan
            )
        } onSuccess: {
            self.coordinator.after(.rebase)
        } onFailure: {
            self.coordinator.invalidateAll()
        }
        // Finished in one go never passes through "in progress" on screen.
        if let repo = activeRepo?.path { await checkRebaseOutcome(repo: repo) }
    }

    /// Full messages of the planner's commits, keyed by hash, to seed its
    /// message editor — the plan itself only carries subjects. A commit whose
    /// message can't be read is left out; the editor falls back to its subject.
    func fullCommitMessages(_ hashes: [String]) async -> [String: String] {
        guard let repo = activeRepo else { return [:] }
        var messages: [String: String] = [:]
        for hash in hashes {
            if let detail = try? await git.commitMessageAndAuthorDate(repoPath: repo.path, hash: hash) {
                messages[hash] = detail.message
            }
        }
        return messages
    }

    /// Build a `PendingSquash` for a contiguous run of commits and present
    /// the squash dialog. `commits` arrive in journal display order (newest
    /// first), so `.last` is the oldest — the commit everything folds into.
    ///
    /// Fetches each commit's full message and author date (the journal log
    /// only carries subjects) so the dialog can pre-fill an editable
    /// combined message and offer an authorship dropdown.
    func prepareSquash(_ commits: [GitCommit]) async {
        guard commits.count >= 2,
              let oldest = commits.last,
              let newest = commits.first else { return }
        guard let repo = activeRepo else {
            statusText = "No active repository"
            return
        }

        let id = output.begin(
            action: "Prepare squash of \(commits.count) commits",
            command: "git show -s"
        )

        // Chronological order (oldest first) so the combined message and
        // authorship list read top-to-bottom like history.
        let chronological = commits.reversed()
        var messageOptions: [SquashMessageOption] = []
        var authors: [SquashAuthorOption] = []
        var bodies: [String] = []
        do {
            let oldestHasParent = try await git.commitHasParent(
                repoPath: repo.path,
                hash: oldest.hash
            )
            for commit in chronological {
                let detail = try await git.commitMessageAndAuthorDate(
                    repoPath: repo.path,
                    hash: commit.hash
                )
                bodies.append(detail.message)
                messageOptions.append(SquashMessageOption(
                    id: commit.hash,
                    label: commit.subject,
                    message: detail.message
                ))
                authors.append(SquashAuthorOption(
                    id: commit.hash,
                    display: "\(DateFormatters.absolute.string(from: commit.date)) - \(commit.authorName)",
                    name: commit.authorName,
                    email: commit.authorEmail,
                    dateISO: detail.authorDateISO
                ))
            }
            output.finish(id: id, status: .success, detail: "Ready to squash \(commits.count) commits")
            let selectedHashes = Set(commits.map(\.hash))
            let publishedHashes = try await git.commitsReachableFromUpstream(
                repoPath: repo.path,
                hashes: selectedHashes
            )
            let rewritesPublishedCommits = !publishedHashes.isEmpty
            pendingSquash = PendingSquash(
                onto: oldestHasParent ? "\(oldest.hash)^" : "--root",
                pickHash: oldest.hash,
                lastSelectedHash: newest.hash,
                selectedHashes: selectedHashes,
                count: commits.count,
                rewritesPublishedCommits: rewritesPublishedCommits,
                combinedMessage: bodies
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n"),
                authors: authors,
                messageOptions: messageOptions
            )
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            statusText = "Could not prepare squash"
            return
        }
    }

    /// Run the squash the user confirmed in `SquashCommitsSheet`, with the
    /// (possibly edited) `message` and chosen `author`. Folds the selected
    /// range into one commit, replays any newer commits on top, and rewrites
    /// the squashed commit's message + authorship via the rebase's amend
    /// step. On conflict the standard in-progress resolver takes over.
    func performSquash(_ plan: PendingSquash, message: String, author: SquashAuthorOption?) async {
        let squashed = await runGit(
            action: "Squash \(plan.count) commits",
            refreshOnFailure: true,
            forceBranches: true,
            autostashAware: true
        ) { repo in
            try await self.git.squashRange(
                repoPath: repo,
                onto: plan.onto,
                pickHash: plan.pickHash,
                selectedHashes: plan.selectedHashes,
                lastSelectedHash: plan.lastSelectedHash,
                message: message,
                authorName: author?.name,
                authorEmail: author?.email,
                authorDateISO: author?.dateISO
            )
        } onSuccess: {
            self.coordinator.after(.rebase)
        } onFailure: {
            self.coordinator.invalidateAll()
        }
        guard squashed else { return }

        // The squashed commits no longer exist — drop the stale selection.
        journalVM.clearSelection()
        guard plan.rewritesPublishedCommits else { return }

        let shouldForcePush = confirmDestructiveGitAction(
            title: "Force push rewritten commits?",
            message: """
            This squash rewrote commits that are already on the upstream branch.

            To update the remote branch, SmallGit needs to run a force push with lease.
            """,
            primaryButton: "Force Push"
        )
        if shouldForcePush {
            await push(force: true)
        } else {
            statusText = "Squash done — force push skipped"
        }
    }

    /// Load `commit`'s full message and present the reword dialog.
    ///
    /// The journal's log only carries subjects, so the message body is
    /// fetched here — the editor has to open on what the commit actually
    /// says, not on its first line. Also settles the two questions the
    /// sheet warns about before the user commits to the rewrite: how many
    /// commits get replayed on top, and whether this one is already on the
    /// upstream.
    func prepareReword(_ commit: GitCommit) async {
        guard let repo = activeRepo else {
            statusText = "No active repository"
            return
        }
        let id = output.begin(
            action: "Prepare message change for \(commit.shortHash)",
            command: "git show -s"
        )
        do {
            let detail = try await git.commitMessageAndAuthorDate(
                repoPath: repo.path,
                hash: commit.hash
            )
            let hasParent = try await git.commitHasParent(
                repoPath: repo.path,
                hash: commit.hash
            )
            let onTop = try await git.commitsAfter(repoPath: repo.path, hash: commit.hash)
            let published = try await git.commitsReachableFromUpstream(
                repoPath: repo.path,
                hashes: [commit.hash]
            )
            output.finish(id: id, status: .success, detail: "Ready to change \(commit.shortHash)")
            pendingReword = PendingReword(
                hash: commit.hash,
                shortHash: commit.shortHash,
                onto: hasParent ? "\(commit.hash)^" : "--root",
                originalMessage: detail.message,
                commitsReplayedOnTop: onTop,
                rewritesPublishedCommits: !published.isEmpty
            )
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            statusText = "Could not read that commit's message"
        }
    }

    /// Run the reword the user confirmed in `RewordCommitSheet`.
    ///
    /// The commit keeps its changes and its authorship and gets a new
    /// hash; every commit on top is replayed onto it and gets one too.
    /// Published history needs confirmation before the rewrite. Afterwards
    /// the journal shows both the rewritten local tip and the unchanged
    /// upstream tip, leaving force push or branch creation to the user.
    func performReword(_ plan: PendingReword, message: String) async {
        if plan.rewritesPublishedCommits {
            guard confirmDestructiveGitAction(
                title: "Change message of a pushed commit?",
                message: """
                Commit \(plan.shortHash) has already been pushed. Changing its message rewrites local history.

                The remote stays unchanged, so the journal will show separate local and remote tips. You can force push or create a new branch afterward.
                """,
                primaryButton: "Change Message"
            ) else { return }
        }

        let reworded = await runGit(
            action: "Change message of \(plan.shortHash)",
            refreshOnFailure: true,
            forceBranches: true,
            autostashAware: true
        ) { repo in
            try await self.git.rewordCommit(
                repoPath: repo,
                onto: plan.onto,
                hash: plan.hash,
                message: message
            )
        } onSuccess: {
            self.coordinator.after(.rebase)
        } onFailure: {
            self.coordinator.invalidateAll()
        }
        guard reworded else { return }

        // Clear the selection of the old version, which may still be shown
        // at the unchanged upstream tip after a published commit is rewritten.
        journalVM.clearSelection()
    }

    /// Bring a branch that is not checked out level with its upstream —
    /// `main` to `origin/main` while standing on a feature branch — so it can
    /// be rebased onto without switching to it first.
    ///
    /// Fetches as part of the move (see `GitService.fastForwardToUpstream`),
    /// so the branch lands on what the remote has now rather than on what it
    /// had at the last fetch.
    @discardableResult
    func fastForwardToUpstream(branch: String) async -> Bool {
        let upstream = branchesVM.branch(named: branch)?.upstream ?? "its upstream"
        var tipBefore: String?
        var tipAfter: String?
        var lastResult: GitCommandResult?
        let done = await runGit(
            action: "Fast-Forward \(branch) to \(upstream)",
            refreshOnFailure: true,
            forceBranches: true
        ) { repo in
            let ref = "refs/heads/\(branch)"
            tipBefore = await self.git.resolveRevision(repoPath: repo, revision: ref)
            let result = try await self.git.fastForwardToUpstream(repoPath: repo, branch: branch)
            tipAfter = await self.git.resolveRevision(repoPath: repo, revision: ref)
            lastResult = result
            return result
        } onSuccess: {
            // A fetch in every respect the panels care about: remote refs
            // moved, a local branch moved, and the graph may have new commits.
            self.coordinator.after(.fetch)
        } onFailure: {
            // Fetch can update the remote refs even when moving the local
            // branch is rejected. Show the newly fetched divergence.
            self.coordinator.after(.fetch)
        }
        if done, tipBefore != nil, tipBefore == tipAfter {
            statusText = "\(branch) is already up to date with \(upstream)"
        } else if done, let result = lastResult, result.combinedOutput.contains("forced update") {
            statusText = "\(upstream) was rewritten on the remote — \(branch) had nothing of its own, so it now matches"
        } else if !done, let result = lastResult,
                  result.combinedOutput.contains("non-fast-forward") {
            return await resolveDivergedFastForward(branch: branch)
        }
        return done
    }

    /// A fast-forward cannot keep a branch's own commits once the upstream
    /// has diverged. Offer an integration explicitly, after the fetch, and
    /// check out the target so conflicts belong to the visible working tree.
    private func resolveDivergedFastForward(branch: String) async -> Bool {
        guard let repo = activeRepo,
              let local = try? await git.localBranches(repoPath: repo.path).first(where: { $0.name == branch }),
              let upstream = local.upstream,
              local.aheadCount > 0, local.behindCount > 0
        else { return false }
        statusText = "\(branch) has commits \(upstream) doesn't — choose Rebase or Merge to keep them"
        guard await git.inProgressOperation(repoPath: repo.path) == nil,
              local.worktreePath == nil else { return false }

        let rebase: Bool
        switch platform.resolveDivergedBranch(
            branch: branch, upstream: upstream, ahead: local.aheadCount, behind: local.behindCount
        ) {
        case .rebase: rebase = true
        case .merge: rebase = false
        case .cancel: return false
        }
        guard activeRepo?.path == repo.path else { return false }
        let checkedOut = await runGit(
            action: "Checkout \(branch)", refreshOnFailure: true, forceBranches: true
        ) { path in
            try await self.git.checkoutBranch(repoPath: path, name: branch)
        } onSuccess: {
            self.coordinator.after(.checkout)
        } onFailure: {
            self.coordinator.invalidateAll()
        }
        guard checkedOut, activeRepo?.path == repo.path else { return false }
        return await runGit(
            action: "\(rebase ? "Rebase" : "Merge") \(branch) with \(upstream)",
            refreshOnFailure: true,
            forceBranches: true,
            autostashAware: true
        ) { path in
            try await self.git.integrateUpstream(repoPath: path, branch: branch, rebase: rebase)
        } onSuccess: {
            self.coordinator.after(rebase ? .rebase : .merge)
        } onFailure: {
            self.coordinator.invalidateAll()
        }
    }

    func createBranch(name: String, from: String? = nil, checkout: Bool = true) async {
        guard !name.isEmpty else { return }
        await runGit(action: "Create Branch \(name)", forceBranches: true) { repo in
            try await self.git.createBranch(repoPath: repo, name: name, from: from, checkout: checkout)
        } onSuccess: {
            self.coordinator.after(.branchCreate)
            if checkout { self.coordinator.after(.checkout) }
        }
    }

    /// Entry point for the "Delete…" branch action. Asks git whether the
    /// branch is contained anywhere, then hands the answer to the
    /// confirmation sheet — the delete itself only happens once the user
    /// confirms there.
    func requestBranchDeletion(_ branch: GitBranch) async {
        // A remote branch is deleted by pushing, not by `git branch -d`, and
        // the question it puts to the user is a different one: not "is this
        // merged" but "this leaves the machine".
        if branch.isRemote {
            await deleteRemoteBranch(branch)
        } else {
            await requestBranchDeletion([branch])
        }
    }

    /// Delete a branch from its remote, once the user has said so.
    ///
    /// Confirmed with an alert rather than the branch-delete sheet: that
    /// sheet is built around `git branch -d` refusing an unmerged branch and
    /// offering the force, and none of that exists here. A push either goes
    /// or is rejected by the far end, and the only thing worth saying first
    /// is what stops being reachable there.
    private func deleteRemoteBranch(_ branch: GitBranch) async {
        guard let repo = activeRepo else {
            statusText = "No active repository"
            return
        }
        let remotes = (try? await git.remotes(repoPath: repo.path)) ?? []
        guard let ref = branch.remoteRef(knownRemotes: remotes) else {
            statusText = "Could not tell which remote \(branch.name) is on"
            return
        }

        let comparedTo = branchesVM.currentBranch ?? "HEAD"
        let check = try? await git.branchDeletionCheck(
            repoPath: repo.path,
            branch: branch.name,
            upstream: nil,
            comparedTo: comparedTo
        )
        let standing: String
        if let check, check.unmergedCount > 0 {
            let n = check.unmergedCount
            standing = """
            \(n) commit\(n == 1 ? "" : "s") on it \(n == 1 ? "is" : "are") not in \(comparedTo). \
            Deleting the branch is how they stop being reachable on \(ref.remote).
            """
        } else {
            standing = "Everything on it is already in \(comparedTo)."
        }

        guard confirmDestructiveGitAction(
            title: "Delete \(ref.branch) from \(ref.remote)?",
            message: """
            This removes the branch from \(ref.remote), for everyone who uses it.

            \(standing)
            """,
            primaryButton: "Delete from \(ref.remote)"
        ) else {
            statusText = "Delete cancelled"
            return
        }

        var failure = ""
        let ok = await runGit(action: "Delete \(branch.name)", forceBranches: true) { repo in
            let result = try await self.git.deleteRemoteBranch(
                repoPath: repo,
                remote: ref.remote,
                branch: ref.branch
            )
            if !result.succeeded { failure = result.combinedOutput }
            return result
        } onSuccess: {
            self.coordinator.after(.branchDelete)
        }
        if !ok {
            statusText = Self.remoteDeleteRefusal(failure, remote: ref.remote, branch: ref.branch)
        }
    }

    /// Why the far end said no, in words that name the next step.
    ///
    /// The one worth translating is the default branch: git's own wording is
    /// "refusing to delete the current branch", which on a hosted repository
    /// means the default the host has set — a setting on the host, with no
    /// git command to change it, so a user reading git's line has nowhere to
    /// go with it.
    nonisolated static func remoteDeleteRefusal(
        _ output: String,
        remote: String,
        branch: String
    ) -> String {
        let lowered = output.lowercased()
        if lowered.contains("refusing to delete the current branch")
            || lowered.contains("default branch") {
            return "\(branch) is the default branch on \(remote) — change that first, then delete it"
        }
        if lowered.contains("remote ref does not exist") {
            return "\(branch) is already gone from \(remote)"
        }
        return gitRefusal(output)
    }

    /// The batch form, for a sidebar selection covering several branches.
    /// Remote branches and the checked-out one are dropped rather than
    /// refused: a selection made by dragging over rows will contain them, and
    /// nobody meant them by "delete these".
    func requestBranchDeletion(_ branches: [GitBranch]) async {
        let current = branchesVM.currentBranch
        let targets = branches.filter { !$0.isRemote && $0.name != current }
        guard !targets.isEmpty else {
            statusText = "Nothing to delete: remote and checked-out branches are left alone"
            return
        }
        guard let repo = activeRepo else {
            statusText = "No active repository"
            return
        }
        let comparedTo = current ?? "HEAD"
        // Concurrently: each check is two `merge-base --is-ancestor` calls, and
        // a batch of thirty branches run one after another is a sheet that
        // takes a visible second to open.
        let git = self.git
        let path = repo.path
        let checks = await withTaskGroup(
            of: (String, BranchDeletionCheck?).self,
            returning: [String: BranchDeletionCheck].self
        ) { group in
            for branch in targets {
                group.addTask {
                    (branch.name, try? await git.branchDeletionCheck(
                        repoPath: path,
                        branch: branch.name,
                        upstream: branch.upstream,
                        comparedTo: comparedTo
                    ))
                }
            }
            var out: [String: BranchDeletionCheck] = [:]
            for await (name, check) in group {
                if let check { out[name] = check }
            }
            return out
        }
        branchPendingDelete = BranchDeletionTarget(branches: targets, checks: checks)
    }

    func cancelBranchDeletion() {
        branchPendingDelete = nil
    }

    /// Runs the deletes the sheet asked for and reports back in enough detail
    /// for it to offer the force path, rather than leaving a bare "failed" in
    /// the log.
    ///
    /// One `git branch -d` per branch, not one command listing them all: git
    /// stops at the first branch it refuses, which would leave the rest
    /// undeleted with nothing on screen saying which.
    func confirmBranchDeletion(_ branches: [GitBranch], force: Bool) async -> BranchDeletionReport {
        var report = BranchDeletionReport()
        for branch in branches {
            var failureOutput = ""
            let name = branch.name
            let ok = await runGit(action: "Delete \(name)", forceBranches: true) { repo in
                let result = try await self.git.deleteBranch(repoPath: repo, name: name, force: force)
                if !result.succeeded { failureOutput = result.combinedOutput }
                return result
            } onSuccess: {
                self.coordinator.after(.branchDelete)
            }

            if ok {
                report.deleted.append(name)
            } else if failureOutput.contains("not fully merged") {
                report.unmerged.append(branch)
            } else {
                report.failed.append(.init(branch: branch, message: Self.gitRefusal(failureOutput)))
            }
        }
        if report.isComplete { branchPendingDelete = nil }
        return report
    }

    /// git's own first useful line, for a sheet that has to say why.
    private nonisolated static func gitRefusal(_ output: String) -> String {
        let detail = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty && !$0.hasPrefix("hint:") })
        return detail ?? "git could not delete this branch."
    }

    /// Push a specific local branch to a chosen remote / remote ref.
    /// Independent of the configured upstream — used by the
    /// "Push To…" branch context-menu item.
    func pushTo(
        localBranch: String,
        remote: String,
        remoteBranch: String?,
        force: Bool,
        setUpstream: Bool
    ) async {
        let trimmedRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRemote.isEmpty else { return }
        let refspec: String = {
            let r = (remoteBranch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return r.isEmpty ? localBranch : "\(localBranch):\(r)"
        }()
        let action = "Push \(refspec) → \(trimmedRemote)"
        await runGit(action: action) { repo in
            try await self.git.pushTo(
                repoPath: repo,
                remote: trimmedRemote,
                localBranch: localBranch,
                remoteBranch: remoteBranch,
                force: force,
                setUpstream: setUpstream
            )
        } onSuccess: {
            // `.push` covers the local-branch list too, which is what
            // --set-upstream needs: the new tracking arrow comes from there.
            self.coordinator.after(.push)
        }
    }

    /// Set `branch`'s upstream to `upstream` (e.g. "origin/main").
    func setUpstream(branch: String, upstream: String) async {
        let trimmed = upstream.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await runGit(action: "Set Upstream \(branch) → \(trimmed)") { repo in
            try await self.git.setUpstream(repoPath: repo, branch: branch, upstream: trimmed)
        } onSuccess: {
            self.coordinator.invalidate(.branchList)
        }
    }

    /// Remove the upstream tracking config for `branch`.
    func unsetUpstream(branch: String) async {
        await runGit(action: "Stop Tracking \(branch)") { repo in
            try await self.git.unsetUpstream(repoPath: repo, branch: branch)
        } onSuccess: {
            self.coordinator.invalidate(.branchList)
        }
    }

    func renameBranch(from oldName: String, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        await runGit(action: "Rename \(oldName) → \(trimmed)", forceBranches: true) { repo in
            try await self.git.renameBranch(repoPath: repo, from: oldName, to: trimmed)
        } onSuccess: {
            self.coordinator.after(.branchRename)
            // Renaming the checked-out branch also moves HEAD.
            if self.branchesVM.currentBranch == oldName {
                self.coordinator.invalidate(.currentBranch)
            }
        }
    }

    func resetCurrent(to ref: String, mode: ResetMode) async {
        if mode == .hard,
           !confirmDestructiveGitAction(
                title: "Hard reset current branch?",
                message: "This will move the current branch to \(ref) and discard local working tree and index changes that conflict with that reset. This cannot be undone from SmallGit.",
                primaryButton: "Hard Reset"
           ) {
            statusText = "Hard reset cancelled"
            return
        }
        await runGit(action: "Reset \(mode.rawValue) → \(ref)", forceBranches: true) { repo in
            try await self.git.reset(repoPath: repo, ref: ref, mode: mode)
        } onSuccess: {
            self.coordinator.after(.reset)
        }
    }

    func cherryPick(_ hash: String) async {
        await runGit(action: "Cherry-Pick \(hash.prefix(7))", refreshOnFailure: true, forceBranches: true) { repo in
            try await self.git.cherryPick(repoPath: repo, hash: hash)
        } onSuccess: {
            self.coordinator.after(.commit)
        } onFailure: {
            self.coordinator.invalidateAll()
        }
    }

    // MARK: - Maintenance (Clean Up)

    /// Right-click a repo → "Clean Up…": shrink the repository and drop
    /// dead bookkeeping. Runs, in order:
    ///
    /// 1. `git remote prune <remote>` for every remote — deletes
    ///    remote-tracking refs whose upstream branch is gone,
    /// 2. `git worktree prune` — drops records of manually deleted
    ///    worktrees,
    /// 3. `git gc --prune=now` — repacks loose objects and deletes
    ///    unreachable ones.
    ///
    /// gc only deletes objects unreachable from every ref *and reflog
    /// entry*, so anything recoverable via Undo / the reflog browser
    /// stays recoverable. The status toast reports the object database
    /// size before → after.
    func cleanUpRepository() async {
        guard let repo = activeRepo else {
            statusText = "No active repository"
            return
        }
        guard confirmDestructiveGitAction(
            title: "Clean up repository?",
            message: "This prunes remote-tracking refs whose upstream branch is gone, removes stale worktree bookkeeping, and runs git gc --prune=now to repack the repository and delete unreachable objects. Anything reachable from a branch, tag, or the reflog is kept — but objects orphaned everywhere are removed for good. This can take a while on large repositories.",
            primaryButton: "Clean Up"
        ) else {
            statusText = "Clean up cancelled"
            return
        }

        let before = (try? await git.objectDatabaseSize(repoPath: repo.path)) ?? -1

        // Remote prune needs the network; a dead remote shouldn't stop
        // the local gc, so failures here are logged but not fatal.
        let remoteNames = (try? await git.remotes(repoPath: repo.path)) ?? []
        for remote in remoteNames {
            await runGit(action: "Prune Remote \(remote)") { path in
                try await self.git.pruneRemote(repoPath: path, remote: remote)
            }
        }

        await runGit(action: "Prune Worktrees") { path in
            try await self.git.pruneWorktrees(repoPath: path)
        }

        let gcOK = await runGit(action: "Garbage Collect (gc --prune=now)") { path in
            try await self.git.gc(repoPath: path)
        } onSuccess: {
            // gc rewrites packs under .git — anything cached could be
            // stale-keyed; start fresh.
            self.coordinator.invalidateAll()
        }

        guard gcOK else { return }
        let after = (try? await git.objectDatabaseSize(repoPath: repo.path)) ?? -1
        if before >= 0, after >= 0 {
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            let msg = "Cleaned up: \(fmt.string(fromByteCount: before)) → \(fmt.string(fromByteCount: after))"
            statusText = msg
            showToast(msg)
        } else {
            statusText = "Clean up — done"
        }
    }

    // MARK: - Worktrees

    /// Drives the Worktrees sheet (Repository menu → "Worktrees…", ⌘⇧T).
    var showWorktreesSheet: Bool = false
    var showSubmodulesSheet: Bool = false
    /// Current `git worktree list` snapshot; reloaded whenever the
    /// sheet opens or a worktree op completes.
    var worktreeList: [GitWorktree] = []

    func loadWorktrees() async {
        guard let repo = activeRepo else {
            worktreeList = []
            return
        }
        worktreeList = (try? await git.worktrees(repoPath: repo.path)) ?? []
    }

    /// Create a worktree at `path`. Pass `newBranch` (+ optional
    /// `startPoint`) to create-and-checkout a fresh branch, or
    /// `checkoutBranch` to check an existing branch out there.
    func addWorktree(
        path: String,
        checkoutBranch: String? = nil,
        newBranch: String? = nil,
        startPoint: String? = nil
    ) async {
        let name = (path as NSString).lastPathComponent
        // `forceBranches: true`: in `newBranch` mode this creates a branch,
        // and invalidation alone only clears L1 — a cached branch reload
        // would serve the stale L2 snapshot without the new branch. Adding
        // a worktree never moves *this* repo's HEAD, so `.branchCreate` is
        // the right (narrow) invalidation, not `.checkout`.
        await runGit(action: "Add Worktree \(name)", forceBranches: true) { repo in
            try await self.git.addWorktree(
                repoPath: repo,
                path: path,
                checkoutBranch: checkoutBranch,
                newBranch: newBranch,
                startPoint: startPoint
            )
        } onSuccess: {
            if newBranch != nil { self.coordinator.after(.branchCreate) }
        }
        await loadWorktrees()
    }

    func removeWorktree(path: String, force: Bool = false) async {
        let name = (path as NSString).lastPathComponent
        // Removing a worktree leaves this repo's HEAD and index untouched;
        // only the worktree list changes, which `loadWorktrees()` refreshes.
        await runGit(action: "Remove Worktree \(name)\(force ? " (forced)" : "")") { repo in
            try await self.git.removeWorktree(repoPath: repo, path: path, force: force)
        }
        await loadWorktrees()
    }

    func pruneWorktrees() async {
        await runGit(action: "Prune Worktrees") { repo in
            try await self.git.pruneWorktrees(repoPath: repo)
        }
        await loadWorktrees()
    }

    /// Register a worktree as its own entry in the repository list —
    /// the natural way to "open" one in SmallGit. Grouped next to its
    /// parent repository when the parent is grouped.
    func openWorktreeAsRepository(_ worktree: GitWorktree) async {
        let group = activeRepo.flatMap { groupName(for: $0) }
        await addRepository(at: worktree.path, group: group)
    }

    /// One-click Undo (Repository menu, ⌥⌘Z): read the most recent
    /// reflog entry, derive its safe inverse via `GitReflogEntry.undoPlan`,
    /// confirm with the user, and execute it. History moves use
    /// `git reset --keep` — it rewinds the branch + working tree like
    /// `--hard` but *refuses* to overwrite uncommitted local changes
    /// (git aborts and nothing is touched). The undone state stays
    /// reachable from the reflog browser, so Undo is itself recoverable.
    func undoLastOperation() async {
        guard let repo = activeRepo else {
            statusText = "No active repository"
            return
        }
        let entries = (try? await git.reflog(repoPath: repo.path, limit: 2)) ?? []
        guard let last = entries.first, entries.count >= 2 else {
            statusText = "Nothing to undo — the reflog has no previous state"
            showToast("Nothing to undo")
            return
        }

        switch last.undoPlan {
        case .checkout(let ref):
            guard confirmDestructiveGitAction(
                title: "Undo checkout?",
                message: "The last operation was “\(last.subject)”. Undo will check out “\(ref)” again.",
                primaryButton: "Check Out \(ref)"
            ) else {
                statusText = "Undo cancelled"
                return
            }
            await checkout(branch: ref)

        case .resetKeep(let ref):
            guard confirmDestructiveGitAction(
                title: "Undo last operation?",
                message: "This will undo “\(last.subject)” by resetting the current branch to \(ref) (git reset --keep). Uncommitted changes are kept — git aborts if they would be overwritten. The undone commits remain reachable from the reflog.",
                primaryButton: "Undo"
            ) else {
                statusText = "Undo cancelled"
                return
            }
            await runGit(
                action: "Undo \(last.action.displayName) — reset --keep \(ref)",
                forceBranches: true
            ) { repoPath in
                try await self.git.reset(repoPath: repoPath, ref: ref, mode: .keep)
            } onSuccess: {
                self.coordinator.after(.reset)
            }

        case .unsupported:
            statusText = "Can't undo “\(last.subject)” — use the reflog browser (⌘⇧G)"
            showToast("Can't undo this operation")
        }
    }

    /// Commit the staged changes as `fixup! <target>` (`git commit
    /// --fixup`). Pairs with `autosquashFixups(from:)`, which later folds
    /// all fixups into their targets. Fails with git's own "no changes
    /// added to commit" when nothing is staged.
    func commitFixup(of hash: String) async {
        // `forceBranches: true` for the same reason as `commit()`: the fixup
        // advances the branch tip, changing its ahead/behind vs. upstream.
        await runGit(action: "Commit Fixup of \(hash.prefix(7))", forceBranches: true) { repo in
            try await self.git.commitFixup(repoPath: repo, targetHash: hash)
        } onSuccess: {
            self.coordinator.after(.commit)
        }
    }

    /// Fold every `fixup!` / `squash!` commit into its target via
    /// `git rebase -i --autosquash <commit>^`. `commit` is the oldest commit
    /// that may receive a fixup — rebasing from its parent keeps the
    /// rewritten range minimal. A root commit has no parent, so it rebases
    /// with `--root` instead. Conflicts pause into the standard in-progress
    /// banner + resolver, like any other rebase.
    func autosquashFixups(from commit: GitCommit) async {
        let base = commit.parentHashes.isEmpty ? "--root" : "\(commit.hash)^"
        await runGit(
            action: "Autosquash Fixups from \(commit.shortHash)",
            refreshOnFailure: true,
            forceBranches: true,
            autostashAware: true
        ) { repo in
            try await self.git.autosquashRebase(repoPath: repo, base: base)
        } onSuccess: {
            self.coordinator.after(.rebase)
        } onFailure: {
            self.coordinator.invalidateAll()
        }
    }

    func revertCommit(_ commit: GitCommit) async {
        guard let repo = activeRepo else {
            statusText = "No active repository"
            return
        }
        if let operation = await git.inProgressOperation(repoPath: repo.path) {
            statusText = "Finish or abort the current \(operation.displayName) before reverting another commit"
            return
        }
        guard let files = try? await git.status(repoPath: repo.path, includeIgnored: false) else {
            statusText = "Could not read repository status"
            return
        }
        guard !files.contains(where: \.isConflict) else {
            statusText = "Resolve the existing conflicts before reverting a commit"
            return
        }
        let noCommit: Bool
        switch platform.resolveRevert(
            commit: "\(commit.shortHash) — \(commit.subject)",
            canCommit: !files.contains(where: \.isStaged)
        ) {
        case .commit: noCommit = false
        case .workingTree: noCommit = true
        case .cancel:
            statusText = "Revert cancelled"
            return
        }
        let done = await runGit(
            action: "\(noCommit ? "Revert" : "Revert & Commit") \(commit.shortHash)",
            refreshOnFailure: true,
            forceBranches: true
        ) { repo in
            try await self.git.revertCommit(repoPath: repo, hash: commit.hash, noCommit: noCommit)
        } onSuccess: {
            self.coordinator.invalidateAll()
        } onFailure: {
            self.coordinator.invalidateAll()
        }
        if done, noCommit {
            statusText = "Reverted \(commit.shortHash) without committing — review the staged changes"
        }
    }

    // MARK: - In-progress operations (paused on conflicts)

    /// Polled by MainWindow to decide whether to show the rebase /
    /// merge / cherry-pick continue banner. Cheap (one filesystem
    /// stat) so we re-read on every refresh rather than cache.
    var inProgressOperation: GitService.InProgressOperation?

    /// Refreshes `inProgressOperation` from the .git/ marker files.
    /// Called from `refreshPanels()` and after any continue/abort.
    func refreshInProgressOperation() async {
        guard let repo = activeRepo?.path else {
            inProgressOperation = nil
            stashApplyConflict = nil
            stashApplyProbed = false
            flattenedConflictPaths = []
            return
        }
        let previous = inProgressOperation
        inProgressOperation = await git.inProgressOperation(repoPath: repo)
        // However the rebase was finished — here, or `--continue` typed in a
        // terminal — the moment it stops being in progress is when to check it.
        if previous == .rebase, inProgressOperation == nil, !interactiveRebaseRunning {
            await checkRebaseOutcome(repo: repo)
        }
    }

    private func checkRebaseOutcome(repo: String) async {
        guard let mismatch = await git.checkRebaseOutcome(repoPath: repo) else { return }
        rebaseOutcomeMismatch = mismatch
        let id = output.begin(action: "Check rebase result", command: "git log")
        output.finish(
            id: id,
            status: .failure,
            detail: "expected \(mismatch.expectedCommits) commits, found \(mismatch.actualCommits)"
        )
    }

    /// Put the branch back where it was before a rebase whose result didn't
    /// match its plan.
    func undoMismatchedRebase(_ mismatch: RebaseOutcomeMismatch) async {
        await runGit(action: "Undo Rebase", refreshOnFailure: true) { repo in
            try await self.git.undoRebase(repoPath: repo, to: mismatch.originalHead)
        } onSuccess: {
            self.coordinator.invalidateAll()
        }
    }

    /// Recognise a conflicted stash apply, which git records nothing for.
    ///
    /// Separate from `refreshInProgressOperation` because it reads
    /// `filesVM.files`, and `refreshPanels` refreshes the two concurrently —
    /// reading the file list from inside the marker check would race the load
    /// that fills it and usually lose. Called once both have landed.
    func probeStashApplyConflict() async {
        guard let repo = activeRepo?.path else {
            stashApplyConflict = nil
            stashApplyProbed = false
            return
        }
        // Unmerged files that no merge, rebase, cherry-pick or revert
        // accounts for: that is the shape a stash apply leaves behind.
        let conflicted = Set(filesVM.files.filter(\.isConflict).map(\.path))
        guard inProgressOperation == nil, !conflicted.isEmpty else {
            stashApplyConflict = nil
            stashApplyProbed = false
            return
        }
        guard stashApplyConflict == nil, !stashApplyProbed else { return }
        stashApplyProbed = true
        stashApplyConflict = await inferStashApplyConflict(repo: repo, conflicted: conflicted)
    }

    // MARK: - Conflicts git has stopped calling conflicts

    /// Paths carrying a whole `<<<<<<<` / `=======` / `>>>>>>>` block that git
    /// no longer reports as unmerged.
    ///
    /// The state a `git reset` on a conflicted path leaves behind — SmallGit's
    /// own Unstage used to produce it, and a terminal still can. It is the
    /// worst state the banner can be in, because every signal reads normal: an
    /// ordinary Modified row, no conflict count, and Continue offered for an
    /// operation git will refuse to continue.
    private(set) var flattenedConflictPaths: [String] = []

    /// Most files to open and scan for markers in one probe.
    ///
    /// A paused merge or rebase has a handful of changed files, not hundreds;
    /// past this the working tree is telling us the user has something else
    /// going on, and reading all of it on every refresh would cost more than
    /// the answer is worth.
    private static let maxConflictMarkerScan = 300

    /// Largest file the probe will read. A merge that left markers behind left
    /// them in something a person edits; a multi-megabyte blob is a generated
    /// file or a checked-in asset, and reading it to look for `<<<<<<<` is all
    /// cost.
    private nonisolated static let maxConflictMarkerFileBytes = 4_000_000

    /// Refreshes `flattenedConflictPaths`. Called from `refreshPanels` once
    /// the file list has landed, alongside `probeStashApplyConflict` and for
    /// the same reason — it reads `filesVM.files`.
    ///
    /// Scoped to a paused operation on both counts that matter: it is when the
    /// state can be acted on (Continue is on screen) and when `git checkout -m`
    /// still has the two heads it needs to put the conflict back.
    func probeFlattenedConflicts() async {
        guard let repo = activeRepo?.path, inProgressOperation != nil else {
            flattenedConflictPaths = []
            return
        }
        // A conflicted row is already a conflict; an untracked or ignored one
        // was never part of the merge; a submodule has no text to scan. What
        // is left is the tracked file with unstaged content — which is both
        // the shape a flattened conflict takes and the only shape that can
        // block `--continue`.
        let candidates = filesVM.files
            .filter { !$0.isConflict && !$0.hasNoIndexEntry && !$0.isSubmodule && $0.isUnstaged }
            .map(\.path)
        guard !candidates.isEmpty, candidates.count <= Self.maxConflictMarkerScan else {
            flattenedConflictPaths = []
            return
        }
        flattenedConflictPaths = await Self.pathsHoldingConflictBlocks(candidates, repoPath: repo)
    }

    /// Which of `files` contains a complete conflict block.
    ///
    /// Stricter than the scan behind the staging prompt, and deliberately so:
    /// that one warns on a single stray marker line, because a half-deleted
    /// marker is still a botched resolution and a warning costs a click. This
    /// one decides whether to *disable* Continue, so it asks for the whole
    /// `<<<<<<<` → `=======` → `>>>>>>>` sequence rather than take a source
    /// file that merely discusses markers for an unresolved merge.
    ///
    /// `nonisolated` so the file reads happen off the main actor.
    private nonisolated static func pathsHoldingConflictBlocks(
        _ files: [String],
        repoPath: String
    ) async -> [String] {
        files.filter { rel in
            let abs = (repoPath as NSString).appendingPathComponent(rel)
            let attributes = try? FileManager.default.attributesOfItem(atPath: abs)
            let size = (attributes?[.size] as? Int) ?? 0
            guard size <= Self.maxConflictMarkerFileBytes,
                  let contents = try? String(contentsOfFile: abs, encoding: .utf8)
            else { return false }
            return holdsConflictBlock(contents)
        }
    }

    /// Whether `text` holds git's three markers in the order git writes them.
    ///
    /// `|||||||` — the ancestor section `merge.conflictStyle = diff3` adds —
    /// sits between the first two and needs no case of its own: it is neither
    /// an opening nor a closing marker, so the walk simply passes over it.
    nonisolated static func holdsConflictBlock(_ text: String) -> Bool {
        enum Stage { case start, opened, separated }
        var stage = Stage.start
        // Split on `isNewline`, not on the `\n` character: Swift reads a CRLF
        // pair as one grapheme, so splitting on `\n` does not cut a file with
        // Windows endings at all — the whole thing arrives as a single line
        // and every marker test below answers no.
        for line in text.split(
            maxSplits: .max, omittingEmptySubsequences: false, whereSeparator: \.isNewline
        ) {
            // A marker line is seven of the character, then a space and a
            // label — or, for the separator, nothing at all.
            if line.hasPrefix("<<<<<<< ") {
                stage = .opened
            } else if stage == .opened, line == "=======" {
                stage = .separated
            } else if stage == .separated, line.hasPrefix(">>>>>>> ") {
                return true
            }
        }
        return false
    }

    /// Put the conflict back on the paths that still hold its markers.
    ///
    /// The way out of a flattened conflict, and the only one: with the stages
    /// gone there is nothing for the resolver to read, and git's own advice
    /// ("mark them as resolved using git add") would commit the markers.
    ///
    /// Confirmed first because `git checkout -m` rebuilds each file from the
    /// merge — any editing done since the conflict was flattened goes with it.
    func restoreFlattenedConflicts() async {
        let paths = flattenedConflictPaths
        guard !paths.isEmpty else { return }
        guard confirmDestructiveGitAction(
            title: paths.count == 1
                ? "Restore the conflict in \(paths[0])?"
                : "Restore conflicts in \(paths.count) files?",
            message: """
            These files still contain conflict markers, but git no longer records them as conflicted — a `git reset` on a conflicted path does that.

            Restoring re-runs the merge to bring back both sides, so the files can be resolved normally. Any edits made to them since the conflict was lost are replaced.
            """,
            primaryButton: "Restore"
        ) else {
            statusText = "Restore conflicts cancelled"
            return
        }
        await runGit(action: "Restore Conflicts") { repo in
            try await self.git.restoreConflict(repoPath: repo, files: paths)
        } onSuccess: {
            // Index and working tree both move for these paths, which is the
            // key set staging retires.
            self.coordinator.after(.stage(files: paths))
        }
    }

    /// Work out which stash a conflicted working tree came from, for the case
    /// SmallGit did not run the apply itself — the conflict predates launch,
    /// or someone did it in a terminal.
    ///
    /// Asked of the stash list rather than remembered, because remembering
    /// only helps the session that got stuck, and by then the user has
    /// usually restarted the app looking for the way out. A stash whose file
    /// list covers every conflicted path is the one that was applied; the
    /// search stops at the first, since `stash@{0}` is where apply and pop
    /// both default.
    ///
    /// Runs only in a state that is already unusual — unmerged files with no
    /// operation behind them — and `stashApplyProbed` keeps it to one attempt
    /// per occurrence, so the subprocess cost never lands on a normal refresh.
    private func inferStashApplyConflict(
        repo: String,
        conflicted: Set<String>
    ) async -> StashApplyConflict? {
        guard let stashes = try? await git.stashList(repoPath: repo) else { return nil }
        for index in stashes.indices {
            guard let files = try? await git.stashFiles(repoPath: repo, index: index) else { continue }
            let paths = Set(files.map(\.path))
            if conflicted.isSubset(of: paths) {
                return StashApplyConflict(files: paths.sorted())
            }
        }
        return nil
    }

    func continueInProgressOperation() async {
        guard let op = inProgressOperation else { return }
        // Finishing or abandoning a rebase is when git puts an autostash
        // back, so these two report it as well.
        await runGit(action: "Continue \(op.displayName)", autostashAware: true) { repo in
            try await self.git.continueOperation(repoPath: repo, operation: op)
        } onSuccess: {
            // Any of these can either finish the operation or land us
            // back on another conflict — invalidate everything and let
            // the next refresh tell us which.
            self.coordinator.invalidateAll()
        }
        await refreshInProgressOperation()
    }

    func abortInProgressOperation() async {
        guard let op = inProgressOperation else { return }
        await runGit(action: "Abort \(op.displayName)", autostashAware: true) { repo in
            try await self.git.abortOperation(repoPath: repo, operation: op)
        } onSuccess: {
            self.coordinator.invalidateAll()
        }
        await refreshInProgressOperation()
    }

    func createTag(name: String, message: String? = nil, at hash: String? = nil) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalMessage = trimmedMessage?.isEmpty == false ? trimmedMessage : nil
        await runGit(action: "Tag \(trimmedName)") { repo in
            try await self.git.createTag(
                repoPath: repo,
                name: trimmedName,
                message: finalMessage,
                hash: hash
            )
        } onSuccess: {
            self.coordinator.after(.tagChange)
        }
    }

    /// Delete a local tag. Does not affect the remote — use `pushTag` with a
    /// later delete if the tag was already published. Confirms first.
    func deleteTag(_ name: String) async {
        guard confirmDestructiveGitAction(
            title: "Delete tag \(name)?",
            message: "This deletes the local tag \(name). It does not remove the tag from any remote it was already pushed to.",
            primaryButton: "Delete"
        ) else {
            statusText = "Delete tag cancelled"
            return
        }
        await runGit(action: "Delete Tag \(name)") { repo in
            try await self.git.deleteTag(repoPath: repo, name: name)
        } onSuccess: {
            self.coordinator.after(.tagChange)
        }
    }

    /// Push a single tag to the first configured remote (falling back to
    /// "origin"). Mirrors Fork/SmartGit's per-tag "Push" action.
    func pushTag(_ name: String) async {
        guard let repo = activeRepo else {
            statusText = "No active repository"
            return
        }
        let remotes = (try? await git.remotes(repoPath: repo.path)) ?? []
        let remote = remotes.first ?? "origin"
        await runGit(action: "Push Tag \(name) → \(remote)") { repo in
            try await self.git.pushTag(repoPath: repo, remote: remote, tag: name)
        }
    }

    /// Confirm once for the whole selection, then remove each path. Hoisting
    /// the prompt here means a multi-file remove shows a single dialog rather
    /// than one alert per file.
    ///
    /// `git rm` works off the index, and refuses a pathspec it can't find
    /// there — an untracked or ignored file in the selection fails the whole
    /// invocation with "did not match any files", taking the tracked files
    /// down with it. Those paths are split off and handed to `git clean`,
    /// which is the command that can delete a file git has no entry for.
    /// When the file is meant to stay on disk there is nothing to do for
    /// them at all: they are already outside the index.
    func removeFiles(files: [GitFileStatus], deleteFromDisk: Bool) async {
        guard !files.isEmpty else { return }
        let unindexed = files.filter(\.hasNoIndexEntry)
        let tracked = files.filter { !$0.hasNoIndexEntry }.map(\.path)
        let unindexedPaths = unindexed.map(\.path)

        guard deleteFromDisk || !tracked.isEmpty else {
            statusText = unindexedPaths.count == 1
                ? "Nothing to remove — \(unindexedPaths[0]) is not in the index"
                : "Nothing to remove — none of the \(unindexedPaths.count) files are in the index"
            return
        }

        // What the confirmation counts is what will actually be touched: a
        // "keep the file" remove skips the unindexed paths entirely, so
        // naming them in the dialog would overstate what it does.
        let paths = deleteFromDisk ? files.map(\.path) : tracked
        let isSingle = paths.count == 1
        let subject = isSingle ? paths[0] : "\(paths.count) files"
        let title = deleteFromDisk
            ? (isSingle ? "Delete file from disk?" : "Delete files from disk?")
            : (isSingle ? "Remove file from Git?" : "Remove files from Git?")
        var message = deleteFromDisk
            ? "This will delete \(subject) from the working tree and stage the deletion."
            : "This will stop tracking \(subject) but keep \(isSingle ? "the file" : "the files") on disk."
        if !unindexed.isEmpty {
            let n = unindexedPaths.count
            let it = n == 1 ? "it" : "them"
            if deleteFromDisk {
                message += isSingle
                    ? " It is not stored in Git, so this cannot be undone."
                    : " \(n) of them \(n == 1 ? "is" : "are") not stored in Git, so deleting \(it) cannot be undone."
            } else {
                message += " \(n) selected \(n == 1 ? "file is" : "files are") not in the index, so \(it) \(n == 1 ? "is" : "are") left alone."
            }
        }
        let primary = deleteFromDisk ? "Delete" : "Remove from Git"
        guard confirmDestructiveGitAction(
            title: title,
            message: message,
            primaryButton: primary
        ) else {
            statusText = "Remove cancelled"
            return
        }
        for path in tracked {
            await removeFile(path: path, deleteFromDisk: deleteFromDisk)
        }
        if deleteFromDisk && !unindexed.isEmpty {
            await deleteUnindexedFiles(unindexed)
        }
    }

    private func removeFile(path: String, deleteFromDisk: Bool) async {
        await runGit(action: "Remove \(path)") { repo in
            try await self.git.removeFile(repoPath: repo, path: path, cached: !deleteFromDisk)
        } onSuccess: {
            self.coordinator.after(.stage(files: [path]))
        }
    }

    /// Delete paths with no index entry through `git clean`, scoped to the
    /// selection. There's no deletion to stage afterwards — git was never
    /// tracking these — so the caches to settle are the discard ones.
    private func deleteUnindexedFiles(_ files: [GitFileStatus]) async {
        let paths = files.map(\.path)
        let action = paths.count == 1
            ? "Remove \(paths[0])"
            : "Remove \(paths.count) untracked files"
        let includeIgnored = files.contains { $0.state == .ignored }
        let ok = await runGit(action: action) { repo in
            try await self.git.cleanUntracked(
                repoPath: repo,
                paths: paths,
                includeIgnored: includeIgnored
            )
        } onSuccess: {
            self.coordinator.after(.discard(files: paths))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    // MARK: - Hunk-level staging

    func stageHunk(_ hunk: DiffHunk, file: String) async {
        guard let patch = DiffPatchBuilder.buildPatch(file: file, hunk: hunk) else { return }
        let ok = await runGit(action: "Stage Hunk") { repo in
            try await self.git.applyPatch(repoPath: repo, patch: patch, cached: true, reverse: false)
        } onSuccess: {
            self.coordinator.after(.stage(files: [file]))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    func unstageHunk(_ hunk: DiffHunk, file: String) async {
        guard let patch = DiffPatchBuilder.buildPatch(file: file, hunk: hunk) else { return }
        let ok = await runGit(action: "Unstage Hunk") { repo in
            try await self.git.applyPatch(repoPath: repo, patch: patch, cached: true, reverse: true)
        } onSuccess: {
            self.coordinator.after(.unstage(files: [file]))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    func stageLine(_ line: DiffLine, in hunk: DiffHunk, file: String) async {
        guard let patch = DiffPatchBuilder.buildLinePatch(file: file, hunk: hunk, targetLine: line) else { return }
        let ok = await runGit(action: "Stage Line") { repo in
            try await self.git.applyPatch(repoPath: repo, patch: patch, cached: true, reverse: false)
        } onSuccess: {
            self.coordinator.after(.stage(files: [file]))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    func unstageLine(_ line: DiffLine, in hunk: DiffHunk, file: String) async {
        guard let patch = DiffPatchBuilder.buildLinePatch(
            file: file, hunk: hunk, targetLine: line, direction: .reverse
        ) else { return }
        let ok = await runGit(action: "Unstage Line") { repo in
            try await self.git.applyPatch(repoPath: repo, patch: patch, cached: true, reverse: true)
        } onSuccess: {
            self.coordinator.after(.unstage(files: [file]))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    /// Stage every line in `lineIDs` (typically the diff-view selection)
    /// across `hunks` of `file`. No-op if the synthesized patch is empty.
    func stageLines(_ lineIDs: Set<UUID>, in hunks: [DiffHunk], file: String) async {
        guard let patch = DiffPatchBuilder.buildLinesPatch(
            file: file, hunks: hunks, targetLineIDs: lineIDs
        ) else { return }
        let count = lineIDs.count
        let ok = await runGit(action: "Stage \(count) Line\(count == 1 ? "" : "s")") { repo in
            try await self.git.applyPatch(repoPath: repo, patch: patch, cached: true, reverse: false)
        } onSuccess: {
            self.coordinator.after(.stage(files: [file]))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    func unstageLines(_ lineIDs: Set<UUID>, in hunks: [DiffHunk], file: String) async {
        guard let patch = DiffPatchBuilder.buildLinesPatch(
            file: file, hunks: hunks, targetLineIDs: lineIDs, direction: .reverse
        ) else { return }
        let count = lineIDs.count
        let ok = await runGit(action: "Unstage \(count) Line\(count == 1 ? "" : "s")") { repo in
            try await self.git.applyPatch(repoPath: repo, patch: patch, cached: true, reverse: true)
        } onSuccess: {
            self.coordinator.after(.unstage(files: [file]))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    /// Reverse-apply the line's patch against the working tree —
    /// equivalent to undoing that one line of unstaged change.
    func discardLine(_ line: DiffLine, in hunk: DiffHunk, file: String) async {
        guard let patch = DiffPatchBuilder.buildLinePatch(
            file: file, hunk: hunk, targetLine: line, direction: .reverse
        ) else { return }
        let ok = await runGit(action: "Discard Line") { repo in
            try await self.git.applyPatch(repoPath: repo, patch: patch, cached: false, reverse: true)
        } onSuccess: {
            self.coordinator.after(.discard(files: [file]))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    func discardLines(_ lineIDs: Set<UUID>, in hunks: [DiffHunk], file: String) async {
        guard let patch = DiffPatchBuilder.buildLinesPatch(
            file: file, hunks: hunks, targetLineIDs: lineIDs, direction: .reverse
        ) else { return }
        let count = lineIDs.count
        let ok = await runGit(action: "Discard \(count) Line\(count == 1 ? "" : "s")") { repo in
            try await self.git.applyPatch(repoPath: repo, patch: patch, cached: false, reverse: true)
        } onSuccess: {
            self.coordinator.after(.discard(files: [file]))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    func discardHunk(_ hunk: DiffHunk, file: String) async {
        guard let patch = DiffPatchBuilder.buildPatch(file: file, hunk: hunk) else { return }
        let ok = await runGit(action: "Discard Hunk") { repo in
            try await self.git.applyPatch(repoPath: repo, patch: patch, cached: false, reverse: true)
        } onSuccess: {
            self.coordinator.after(.discard(files: [file]))
        }
        if ok { await diffVM.reloadAfterStaging() }
    }

    func addToGitignore(patterns: [String]) async {
        guard let repo = activeRepo else { return }
        let id = output.begin(action: "Ignore", command: "edit .gitignore")
        do {
            try await git.addToGitignore(repoPath: repo.path, patterns: patterns)
            output.finish(id: id, status: .success, detail: "Added \(patterns.count) pattern(s)")
            coordinator.invalidate(.fileStatus)
            await refreshPanels()
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
        }
    }

    /// Set or clear the index's `assume-unchanged` flag on `paths`.
    ///
    /// The flag tells git to stop looking at a file: local edits to it stop
    /// appearing in status, produce no diff, and go into no commit, until
    /// the flag comes off. Handy for a config file you had to change
    /// locally — and the reason the Files panel has a view for it (⌘5), as
    /// a flagged file leaves nothing on screen to remind you.
    ///
    /// Untracked paths are dropped rather than passed through:
    /// `update-index` has no entry to flag for them and fails the whole
    /// invocation over one, taking the tracked paths in the same selection
    /// down with it.
    func setAssumeUnchanged(files: [GitFileStatus], on: Bool) async {
        let paths = files.filter { $0.state != .untracked && !$0.isConflict }.map(\.path)
        guard !paths.isEmpty else {
            statusText = "Assume unchanged applies to tracked, unconflicted files"
            return
        }
        let subject = paths.count == 1 ? paths[0] : "\(paths.count) files"
        let action = on
            ? "Assume unchanged: \(subject)"
            : "Stop assuming unchanged: \(subject)"
        let ok = await runGit(action: action) { repo in
            try await self.git.setAssumeUnchanged(repoPath: repo, paths: paths, on: on)
        } onSuccess: {
            // A file that just gained the flag vanishes from `git status`,
            // so the row backing this selection is about to disappear;
            // holding its id would leave the diff pane on a dead file.
            self.filesVM.selectedFileIDs.removeAll()
            self.diffVM.clear()
        }
        guard ok else { return }
        await dropCachesAfterAssumeUnchanged(paths: paths)
    }

    /// `purge`, not `invalidate`: the disk entry is left in place as a
    /// fallback by the latter, and here that fallback is the flag list that
    /// just changed — handed straight back the next time the view is switched
    /// on. The diffs of these paths go the same way, since git will now
    /// report nothing for a flagged file however it was edited. File status
    /// is the exception: the caller has already re-read it past the caches,
    /// so dropping it would only cost another `git status`.
    private func dropCachesAfterAssumeUnchanged(paths: [String]) async {
        var stale = InvalidationEngine.keysAfter(.assumeUnchanged(files: paths))
        stale.remove(.fileStatus)
        await coordinator.purge(stale)
        if filesVM.showAssumeUnchanged {
            await filesVM.refreshAssumeUnchanged()
        }
    }

    // MARK: - Repository tree

    /// The repository a path in the sidebar tree belongs to. Not necessarily
    /// the active one — a tree can be opened under any repository row — and
    /// the innermost one, for a repository listed inside another.
    func repository(containing path: String) -> RepositoryEntry? {
        allRepositories
            .filter { path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    /// `path` relative to `repo`, or nil when it is not inside it.
    static func relativePath(_ path: String, in repo: RepositoryEntry) -> String? {
        let root = repo.path.hasSuffix("/") ? repo.path : repo.path + "/"
        guard path.hasPrefix(root) else { return nil }
        return String(path.dropFirst(root.count))
    }

    /// Ignore a sidebar path on this machine only, through `info/exclude` —
    /// for files git does not track and should not be told about, without
    /// a `.gitignore` change everybody else would get.
    ///
    /// Tracked files under the path stay tracked: an ignore rule only ever
    /// covers untracked ones. Said in the output rather than refused, since
    /// a folder can hold both and the untracked half still goes quiet.
    func excludeLocally(path: String, isDirectory: Bool) async {
        guard let repo = repository(containing: path),
              let relative = Self.relativePath(path, in: repo), !relative.isEmpty
        else { return }
        let pattern = GitService.ignorePattern(forRelativePath: relative, isDirectory: isDirectory)
        let id = output.begin(action: "Exclude locally: \(relative)", command: "edit info/exclude")
        do {
            let added = try await git.addToLocalExclude(repoPath: repo.path, patterns: [pattern])
            // Only a note on top: the pattern is already written, and a
            // failure to count must not report the exclude as failed.
            let tracked = (try? await git.trackedFiles(repoPath: repo.path, under: relative)) ?? []
            var detail = added.isEmpty
                ? "\(pattern) was already in info/exclude"
                : "Added \(pattern) to info/exclude"
            if !tracked.isEmpty {
                let n = tracked.count
                detail += "\n\(n) tracked file\(n == 1 ? "" : "s") under it stay\(n == 1 ? "s" : "") tracked — "
                    + "ignore rules only cover untracked files; Assume Unchanged hides edits to tracked ones"
            }
            output.finish(id: id, status: .success, detail: detail)
            statusText = "Excluded locally: \(relative)"
            if repo.path == activeRepo?.path {
                coordinator.invalidate(.fileStatus)
                await refreshPanels()
            }
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            statusText = "Exclude locally — error"
        }
    }

    /// Set or clear `assume-unchanged` on every tracked file at or under a
    /// sidebar path — the folder form of the Files panel's command, which
    /// can only reach a file once git already reports it.
    func setAssumeUnchanged(under path: String, on: Bool) async {
        guard let repo = repository(containing: path),
              let relative = Self.relativePath(path, in: repo), !relative.isEmpty
        else { return }
        let action = on
            ? "Assume unchanged: \(relative)"
            : "Stop assuming unchanged: \(relative)"
        let id = output.begin(action: action, command: "git update-index")
        do {
            let files = try await git.trackedFiles(repoPath: repo.path, under: relative)
            guard !files.isEmpty else {
                // The flag lives on index entries, and an untracked path has
                // none — `update-index` would do nothing and say nothing.
                output.finish(
                    id: id,
                    status: .failure,
                    detail: "Nothing under \(relative) is tracked, so there is nothing to flag. "
                        + "Exclude Locally keeps untracked files out of git on this machine."
                )
                statusText = "Nothing tracked under \(relative)"
                return
            }
            let result = try await git.setAssumeUnchanged(repoPath: repo.path, paths: files, on: on)
            output.finish(id: id, result: result)
            guard result.succeeded else {
                statusText = "\(action) — error"
                return
            }
            let n = files.count
            statusText = "\(on ? "Assuming" : "Stopped assuming") unchanged: \(n) file\(n == 1 ? "" : "s")"
            guard repo.path == activeRepo?.path else { return }
            filesVM.selectedFileIDs.removeAll()
            diffVM.clear()
            await filesVM.forceRefresh()
            changedFileCount = filesVM.files.count
            await dropCachesAfterAssumeUnchanged(paths: files)
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            statusText = "\(action) — error"
        }
    }

    // MARK: - System integrations (menu helpers)

    func revealInFinder(path: String) {
        platform.revealInFinder(path: path)
    }

    func openInFinder(path: String) {
        platform.openInFinder(path: path)
    }

    func openInTerminal(path: String) {
        platform.openInTerminal(path: path)
    }

    // MARK: - External diff / merge tool

    /// Single entrypoint for "open this file in a compare view" — routes
    /// through the configured external tool first and falls back to the
    /// built-in 2-pane diff (or 4-pane resolver for conflicts) when the
    /// tool is `.builtin`, isn't installed, or fails to launch. Call this
    /// from every double-click, Return-key, Resolve-banner, and context-
    /// menu handler so the preference is honored uniformly.
    func openCompareOrMerge(path: String, isConflict: Bool) {
        guard isConflict else {
            openCompares(paths: [path])
            return
        }

        Task {
            let launched = await openExternalMerge(path: path)
            if launched { return }
            conflictTarget = ConflictTarget(path: path)
        }
    }

    /// Opens every selected path. External diff preferences are still
    /// honoured one file at a time; any paths that cannot be handed off are
    /// opened together in SmallGit's native tabbed compare window.
    func openCompares(paths: [String]) {
        let request = CompareTarget(paths: paths)
        guard !request.paths.isEmpty else { return }

        Task {
            var builtInPaths: [String] = []
            for path in request.paths {
                if !(await openExternalDiff(path: path)) {
                    builtInPaths.append(path)
                }
            }
            guard !builtInPaths.isEmpty else { return }
            compareTarget = CompareTarget(paths: builtInPaths)
        }
    }

    /// Launches the configured external diff tool for a 2-way compare of
    /// `path` (HEAD version vs. working-tree version). Returns `true` if
    /// the external tool was launched; `false` when the configured tool is
    /// `.builtin`, isn't installed, or fails to extract HEAD content —
    /// callers should fall back to `compareTarget` for the built-in view.
    func openExternalDiff(path: String, repoPath: String? = nil) async -> Bool {
        guard appConfig.externalDiffTool != .builtin,
              let repo = repoPath ?? activeRepo?.path
        else { return false }

        guard let invocation = resolveDiffInvocation() else { return false }

        let headContent = (try? await git.fileAtHead(repoPath: repo, path: path)) ?? ""
        guard let leftURL  = writeTempFile(name: "HEAD-\((path as NSString).lastPathComponent)", contents: headContent) else { return false }
        let rightURL = URL(fileURLWithPath: (repo as NSString).appendingPathComponent(path))

        let args = substituteArgs(
            invocation.template,
            substitutions: ["leftFile": leftURL.path, "rightFile": rightURL.path]
        )
        return spawnExternalTool(binary: invocation.binary, args: args)
    }

    /// Launches the configured external diff tool on HEAD against the index
    /// for `file` — what the commit dialog is about to record. Both sides are
    /// temp copies: the right one is the staged blob, not the working file,
    /// which may hold changes that are not going into this commit. Returns
    /// `false` when the tool is `.builtin` or can't be launched.
    func openExternalStagedDiff(file: GitFileStatus) async -> Bool {
        guard appConfig.externalDiffTool != .builtin,
              let repo = activeRepo?.path
        else { return false }

        guard let invocation = resolveDiffInvocation() else { return false }

        // A staged rename is recorded against its old name in HEAD.
        let headPath = file.state == .renamed ? (file.originalPath ?? file.path) : file.path
        let headContent  = (try? await git.fileAtHead(repoPath: repo, path: headPath)) ?? ""
        // An empty revision is git's `:path` — stage 0 of the index.
        let indexContent = (try? await git.fileAtRevision(repoPath: repo, revision: "", path: file.path)) ?? ""

        let leaf = (file.path as NSString).lastPathComponent
        guard let leftURL  = writeTempFile(name: "HEAD-\(leaf)",  contents: headContent),
              let rightURL = writeTempFile(name: "INDEX-\(leaf)", contents: indexContent)
        else { return false }

        let args = substituteArgs(
            invocation.template,
            substitutions: ["leftFile": leftURL.path, "rightFile": rightURL.path]
        )
        return spawnExternalTool(binary: invocation.binary, args: args)
    }

    /// Launches the configured external diff tool to compare a single
    /// file across a commit boundary — the file at the commit's first
    /// parent (or `commit^` for root commits without recorded parents)
    /// vs. the file at the commit itself. Returns `true` when launched,
    /// `false` when the tool is `.builtin`, not installed, or git can't
    /// extract one of the revisions. Used by the Log window's per-file
    /// double-click handler.
    func openExternalCommitDiff(commit: GitCommit, path: String) async -> Bool {
        guard appConfig.externalDiffTool != .builtin,
              let repo = activeRepo?.path
        else { return false }

        guard let invocation = resolveDiffInvocation() else { return false }

        let parent = commit.parentHashes.first ?? "\(commit.hash)^"
        let leftContent  = (try? await git.fileAtRevision(repoPath: repo, revision: parent,       path: path)) ?? ""
        let rightContent = (try? await git.fileAtRevision(repoPath: repo, revision: commit.hash, path: path)) ?? ""

        let leaf = (path as NSString).lastPathComponent
        guard let leftURL  = writeTempFile(name: "\(commit.shortHash)-parent-\(leaf)", contents: leftContent),
              let rightURL = writeTempFile(name: "\(commit.shortHash)-\(leaf)",        contents: rightContent)
        else { return false }

        let args = substituteArgs(
            invocation.template,
            substitutions: ["leftFile": leftURL.path, "rightFile": rightURL.path]
        )
        return spawnExternalTool(binary: invocation.binary, args: args)
    }

    /// Launches the configured external merge tool for a 3-way conflict on
    /// `path`. Returns `true` if the external tool was launched; `false`
    /// for `.builtin`, presets/customs without a merge template, missing
    /// binary, or git extraction failures — callers should fall back to
    /// `conflictTarget` for the built-in 4-pane resolver.
    func openExternalMerge(path: String) async -> Bool {
        guard appConfig.externalDiffTool != .builtin,
              let repo = activeRepo?.path
        else { return false }

        guard let invocation = resolveMergeInvocation() else { return false }

        let base   = (try? await git.conflictVersion(repoPath: repo, path: path, side: .base))   ?? ""
        let ours   = (try? await git.conflictVersion(repoPath: repo, path: path, side: .ours))   ?? ""
        let theirs = (try? await git.conflictVersion(repoPath: repo, path: path, side: .theirs)) ?? ""

        let leaf = (path as NSString).lastPathComponent
        guard let baseURL   = writeTempFile(name: "BASE-\(leaf)",   contents: base),
              let leftURL   = writeTempFile(name: "OURS-\(leaf)",   contents: ours),
              let rightURL  = writeTempFile(name: "THEIRS-\(leaf)", contents: theirs)
        else { return false }
        let mergedURL = URL(fileURLWithPath: (repo as NSString).appendingPathComponent(path))

        let args = substituteArgs(
            invocation.template,
            substitutions: [
                "leftFile":   leftURL.path,
                "rightFile":  rightURL.path,
                "baseFile":   baseURL.path,
                "mergedFile": mergedURL.path
            ]
        )
        return spawnExternalTool(binary: invocation.binary, args: args)
    }

    private func resolveDiffInvocation() -> (binary: String, template: String)? {
        switch appConfig.externalDiffTool {
        case .builtin:
            return nil
        case .custom:
            guard let raw = appConfig.customDiffToolPath,
                  let bin = resolveAppBundleBinary(raw),
                  !appConfig.customDiffArgs.isEmpty
            else { return nil }
            return (bin, appConfig.customDiffArgs)
        case let preset:
            guard let bin = preset.presetBinaryCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
                  !preset.presetDiffArgsTemplate.isEmpty
            else { return nil }
            return (bin, preset.presetDiffArgsTemplate)
        }
    }

    private func resolveMergeInvocation() -> (binary: String, template: String)? {
        switch appConfig.externalDiffTool {
        case .builtin:
            return nil
        case .custom:
            guard let raw = appConfig.customDiffToolPath,
                  let bin = resolveAppBundleBinary(raw),
                  !appConfig.customMergeArgs.isEmpty
            else { return nil }
            return (bin, appConfig.customMergeArgs)
        case let preset:
            let tmpl = preset.presetMergeArgsTemplate
            guard !tmpl.isEmpty,
                  let bin = preset.presetBinaryCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            else { return nil }
            return (bin, tmpl)
        }
    }

    /// If `raw` is a `.app` bundle, return the executable inside
    /// `Contents/MacOS/`. Otherwise treat `raw` as a direct binary path.
    /// Returns nil if nothing executable exists at the resolved location.
    private func resolveAppBundleBinary(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix(".app"),
           let bundle = Bundle(path: trimmed),
           let exec   = bundle.executablePath,
           FileManager.default.isExecutableFile(atPath: exec) {
            return exec
        }
        return FileManager.default.isExecutableFile(atPath: trimmed) ? trimmed : nil
    }

    private func writeTempFile(name: String, contents: String) -> URL? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SmallGit-Diff-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Splits `template` on whitespace, substituting `${key}` tokens. Keeps
    /// it simple — no quoting/escaping support, matching how git's own
    /// `mergetool.<tool>.cmd` users tend to write paths-without-spaces.
    private func substituteArgs(_ template: String, substitutions: [String: String]) -> [String] {
        template.split(whereSeparator: { $0.isWhitespace }).map { token in
            var s = String(token)
            for (k, v) in substitutions {
                s = s.replacingOccurrences(of: "${\(k)}", with: v)
            }
            return s
        }
    }

    @discardableResult
    private func spawnExternalTool(binary: String, args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        // `bcomp` / `ksdiff` are blocking helpers — they exit when the
        // user closes their compare window. Hook termination to re-read
        // status & diff so a resolved conflict drops out of the files
        // list without a manual ⌘R, even if SmallGit was never formally
        // deactivated (subprocess GUI doesn't reliably trigger
        // the app did-become-active notification).
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeRepo != nil else { return }
                await self.refreshAllForced()
            }
        }
        do {
            try process.run()
            return true
        } catch {
            statusText = "Failed to launch diff tool: \(error.localizedDescription)"
            return false
        }
    }

    /// Opens `path` in the editor configured in Preferences. For `.system`
    /// (or when the configured editor isn't installed) falls back to the OS
    /// default opener for the path.
    func openInEditor(path: String) {
        let editor = appConfig.externalEditor
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        platform.openInEditor(
            path: path,
            appPath: editor == .custom ? appConfig.customEditorPath : nil,
            bundleIDs: editor.candidateBundleIDs(isDirectory: isDirectory.boolValue)
        )
    }

    // MARK: - Zoom

    /// Clamp range for the monospace font size used in diff / output /
    /// files panels.
    static let monoFontSizeRange: ClosedRange<CGFloat> = 8...28
    /// Default mono font size — used to reset via ⌘0.
    static let defaultMonoFontSize: CGFloat = 12

    func bumpMonoFontSize(by delta: CGFloat) {
        let next = min(max(appConfig.monoFontSize + delta, Self.monoFontSizeRange.lowerBound),
                       Self.monoFontSizeRange.upperBound)
        guard next != appConfig.monoFontSize else { return }
        appConfig.monoFontSize = next
        statusText = "Mono font \(Int(next))pt"
        Task { await saveAppConfig() }
    }

    func resetMonoFontSize() {
        guard appConfig.monoFontSize != Self.defaultMonoFontSize else { return }
        appConfig.monoFontSize = Self.defaultMonoFontSize
        statusText = "Mono font \(Int(Self.defaultMonoFontSize))pt"
        Task { await saveAppConfig() }
    }

    /// Switch the app between light, dark and following the system, then
    /// persist the choice. Applying comes first so the window repaints on the
    /// click rather than after the config file has been written.
    func setAppearance(_ mode: AppearanceMode) {
        guard appConfig.appearance != mode else { return }
        appConfig.appearance = mode
        mode.applyToApp()
        Task { await saveAppConfig() }
    }

    /// Change one compare/conflict colour, for the theme currently in effect.
    ///
    /// Per theme rather than one value for both: a colour that reads well on a
    /// dark editor is usually a highlighter pen on white, so setting one is
    /// deliberately not allowed to wreck the other. `nil` drops the override
    /// and hands the role back to the theme.
    func setDiffColor(_ role: DiffColorRole, hex: String?, dark: Bool) {
        guard appConfig.diffColors.value(role.rawValue, dark: dark) != hex else { return }
        appConfig.diffColors.set(hex, for: role.rawValue, dark: dark)
        DiffPalette.shared.apply(appConfig.diffColors)
        // The palette follows every update, so the diff behind the picker
        // tracks the drag; the config file only needs the colour the user
        // settles on. A colour well streams a value per mouse-move, and
        // writing the file that many times is a lot of disk for one decision.
        diffColorSave?.cancel()
        diffColorSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.saveAppConfig()
        }
    }

    /// Debounces the writes above. Cancelled — not awaited — by a reset, which
    /// saves at once because it is a single deliberate click.
    private var diffColorSave: Task<Void, Never>?

    /// Back to the theme's own colours, in both themes — "default" means the
    /// state a fresh install is in, not "the half of it you can currently see".
    func resetDiffColors() {
        guard !appConfig.diffColors.isEmpty else { return }
        diffColorSave?.cancel()
        appConfig.diffColors.removeAll()
        DiffPalette.shared.apply(appConfig.diffColors)
        Task { await saveAppConfig() }
    }

    /// Toggle the whitespace glyphs in every diff and compare view.
    ///
    /// One app-wide setting rather than one per window: the checkbox sits in
    /// three places that all render the same lines, and having a file look
    /// different depending on which of them you opened it from is the
    /// confusing option.
    func setShowWhitespace(_ on: Bool) {
        guard appConfig.showWhitespace != on else { return }
        appConfig.showWhitespace = on
        Task { await saveAppConfig() }
    }

    // MARK: - Credentials

    @discardableResult
    func signInWithGitHubCLI(for request: CredentialRequest) -> Task<Void, Never>? {
        guard request.supportsGitHubCLI, credentialRequest == request, gitHubAuthTask == nil else { return nil }
        let attempt = UUID()
        gitHubAuthAttempt = attempt
        gitHubAuthState = .checking
        let id = output.begin(action: request.requiresWorkflowScope ? "GitHub Workflow Access" : "GitHub Sign In",
                              command: request.requiresWorkflowScope
                                ? "gh auth refresh --hostname github.com --scopes workflow"
                                : "gh auth status / login / setup-git")
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await gitHubAuth.connect(requiresWorkflowScope: request.requiresWorkflowScope) { [weak self] state in
                    await self?.updateGitHubAuth(state, attempt: attempt)
                }
                try Task.checkCancellation()
                guard gitHubAuthAttempt == attempt, credentialRequest == request else {
                    throw CancellationError()
                }
                let retry = credentialRetry
                credentialRetry = nil
                credentialRequest = nil
                gitHubAuthAttempt = nil
                gitHubAuthTask = nil
                gitHubAuthState = .idle
                output.finish(id: id, status: .success, detail: "Git uses GitHub CLI for github.com.")
                statusText = "Connected to GitHub with gh"
                // A browser flow can outlive the original selection. Never
                // run its pending operation on a different repository.
                if request.repoPath == nil || activeRepo?.path == request.repoPath {
                    await retry?()
                } else {
                    statusText = "Connected to GitHub — retry \(request.action) in the original repository"
                }
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                let message = cancelled ? "GitHub sign-in cancelled" :
                    ((error as? GitHubAuthError)?.localizedDescription ?? "Could not connect to GitHub CLI. Try again.")
                output.finish(id: id, status: .failure, detail: message)
                guard gitHubAuthAttempt == attempt else { return }
                gitHubAuthAttempt = nil
                gitHubAuthTask = nil
                if cancelled {
                    gitHubAuthState = .idle
                } else if error as? GitHubAuthError == .notInstalled {
                    gitHubAuthState = .missingCLI
                } else {
                    gitHubAuthState = .failed(message)
                }
            }
        }
        gitHubAuthTask = task
        return task
    }

    private func updateGitHubAuth(_ state: GitHubAuthState, attempt: UUID) {
        guard gitHubAuthAttempt == attempt else { return }
        gitHubAuthState = state
    }

    func cancelGitHubSignIn() {
        gitHubAuthAttempt = nil
        gitHubAuthTask?.cancel()
        gitHubAuthTask = nil
        gitHubAuthState = .idle
    }

    /// Leave the modal so the embedded terminal is usable. Preparing the
    /// command must not install anything or retry the failed Git operation.
    func prepareGitHubCLIInstallation(for request: CredentialRequest) {
        guard credentialRequest == request, request.supportsGitHubCLI,
              gitHubAuthState == .missingCLI else { return }
        cancelCredentialRequest()
        showTerminal(true)
        terminalVM.prepareCommand("brew install gh")
        statusText = "Press Enter in Terminal to install GitHub CLI, then retry \(request.action)"
    }

    /// Stores the credentials git asked for and runs the failed command
    /// again.
    ///
    /// Storing goes through `git credential approve`, so git decides the
    /// format and is guaranteed to read the entry back. If no helper is
    /// configured the credentials would be accepted and silently dropped —
    /// so the macOS keychain is configured first, which is where the git
    /// CLI and every other Mac client already look.
    ///
    /// The question comes back in as an argument rather than being read from
    /// `credentialRequest`, which is what the dialog is presented from:
    /// dismissing a `.sheet(item:)` clears its binding, so by the time the
    /// answer arrived the question had already gone and this returned
    /// without storing anything. Every password the user typed was dropped
    /// in silence, and the next fetch asked for it again.
    func submitCredentials(
        for request: CredentialRequest,
        username: String,
        password: String
    ) async {
        cancelGitHubSignIn()
        // Nil for a clone, which reached this wall before it had a
        // repository. Both `credential approve` and the global helper
        // setting work repo-less, and going through the *asking* repo (not
        // the selected one) is what keeps a repo-local `credential.helper`
        // honoured where one is configured.
        let repoPath = request.repoPath
        credentialRequest = nil
        let retry = credentialRetry
        credentialRetry = nil

        let id = output.begin(action: "Save Credentials", command: "git credential approve")
        do {
            if try await git.credentialHelper(repoPath: repoPath) == nil {
                try await git.useKeychainCredentialHelper(repoPath: repoPath)
            }
            let result = try await git.approveCredential(
                repoPath: repoPath,
                scheme: request.scheme,
                host: request.host,
                username: username,
                password: password
            )
            output.finish(id: id, result: result)
            guard result.succeeded else {
                statusText = "Could not save credentials for \(request.host)"
                return
            }
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            statusText = "Could not save credentials for \(request.host)"
            return
        }

        statusText = "Saved credentials for \(request.host)"
        await retry?()
    }

    /// "Push — failed", plus what to do about it when the failure is one
    /// SSH or the server has already explained. The output panel has the
    /// whole message; the status line is where someone looks first, and
    /// "Repository not found" or "returned error: 503" needs translating
    /// before it means anything.
    static func failureStatus(_ action: String, result: GitCommandResult) -> String {
        let output = result.combinedOutput
        guard let hint = GitCredentials.sshFailureHint(in: output)
                ?? GitRemoteFailure.hint(in: output)
        else {
            return "\(action) — failed"
        }
        return "\(action) — \(hint)"
    }

    /// Dismiss without storing anything. The command stays failed — the log
    /// already says why.
    func cancelCredentialRequest() {
        cancelGitHubSignIn()
        credentialRequest = nil
        credentialRetry = nil
    }

    /// Persist the current `appConfig`. Called from Preferences whenever
    /// the user changes a setting.
    func saveAppConfig() async {
        try? await config.saveAppConfig(appConfig)
        // Propagate the values downstream services may have cached.
        if let p = appConfig.gitPath {
            await ProcessRunner.shared.setGitPath(p)
        } else {
            await ProcessRunner.shared.setGitPath(nil)
        }
    }

    /// Flip the sidebar-hiding focus mode and persist.
    /// Triggered from the titlebar button next to the traffic
    /// lights — survives restarts so the user doesn't have to
    /// re-enable focus mode every session.
    func toggleCompactMode() {
        uiState.compactMode.toggle()
        let snapshot = uiState
        Task { try? await config.saveUIState(snapshot) }
    }

    /// Show the Terminal in the Changes panel, or the diff. Persisted: an
    /// expert who works from a command line wants it there next launch too.
    func showTerminal(_ on: Bool) {
        guard uiState.showsTerminal != on else { return }
        uiState.showsTerminal = on
        if on { terminalVM.setRepository(activeRepo?.path) }
        let snapshot = uiState
        Task { try? await config.saveUIState(snapshot) }
    }

    /// Fold the Journal + Output row away, or bring it back. Persisted, like
    /// the other layout choices — someone working mostly in the diff or the
    /// terminal wants the room to still be theirs next launch.
    func setBottomPanelsCollapsed(_ collapsed: Bool) {
        guard uiState.bottomPanelsCollapsed != collapsed else { return }
        uiState.bottomPanelsCollapsed = collapsed
        let snapshot = uiState
        Task { try? await config.saveUIState(snapshot) }
    }

    /// Record the main window's position + size so the next launch reopens it
    /// where the user left it. Called (debounced) by `MainWindowStateHandler`
    /// as the window moves or resizes, and once more as it closes.
    ///
    /// Awaits the write rather than firing and forgetting: the close path
    /// terminates the app immediately afterwards, and an in-flight write would
    /// be lost.
    func persistMainWindowFrame(_ frame: WindowFrameState) async {
        guard uiState.mainWindowFrame != frame else { return }
        uiState.mainWindowFrame = frame
        let snapshot = uiState
        try? await config.saveUIState(snapshot)
    }

    /// Blocking variant, for when the window has just moved to another display.
    /// The process may be killed before an async write lands, and that would
    /// lose the very move the user just made — so pay for one synchronous write
    /// instead of dropping it. Screen changes are rare enough that the
    /// main-thread cost doesn't matter.
    func persistMainWindowFrameNow(_ frame: WindowFrameState) {
        guard uiState.mainWindowFrame != frame else { return }
        uiState.mainWindowFrame = frame
        config.saveUIStateBlocking(uiState)
    }

    func copyToPasteboard(_ string: String) {
        platform.copyToPasteboard(string)
        statusText = "Copied: \(string)"
    }

    /// Say what `--autostash` did. Every command that can stash the
    /// working tree for its own duration — pull, merge, rebase, squash —
    /// exits 0 in all three cases, so a conflicted reapply otherwise
    /// leaves "done" on screen while the Files panel fills with markers.
    private func reportAutostash(_ result: GitCommandResult, action: String) {
        switch GitOutputParser.autostashOutcome(in: result.combinedOutput) {
        case .none:
            break
        case .applied:
            showToast("\(action) — your local changes were put back")
        case .conflicted:
            statusText = "\(action) — your changes conflicted and are kept in a stash"
            showToast("Your changes wouldn't reapply — resolve the conflicts, then drop the stash")
        }
    }

    func showToast(_ text: String) {
        let next = ToastMessage(text: text)
        toast = next
        Task { @MainActor [weak self, next] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self, self.toast?.id == next.id else { return }
            self.toast = nil
        }
    }

    // MARK: - Repo edits

    func renameRepo(_ repo: RepositoryEntry, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateRepo(repo) { $0.name = trimmed }
        try? await config.saveRepositories(repositoriesConfig)
    }

    func toggleFavorite(_ repo: RepositoryEntry) async {
        updateRepo(repo) { $0.isFavorite.toggle() }
        try? await config.saveRepositories(repositoriesConfig)
    }

    func closeActiveRepo() {
        activeRepo = nil
        coordinator.switchRepo(to: nil)
        fileWatcher.stop()
        statusText = "Closed repository"
        clearRepoPanelState()
    }

    private func clearRepoPanelState() {
        filesVM.files = []
        filesVM.selectedFileIDs.removeAll()
        filesVM.clearTrackedPaths()
        filesVM.clearAssumeUnchangedPaths()
        diffVM.clear()
        journalVM.commits = []
        journalVM.restoreRefSelection(.headOnly)
        journalVM.clearSearch()
        journalVM.unpushedHashes = []
        journalVM.selectedCommitID = nil
        journalVM.resetPagination()
        inProgressOperation = nil
        flattenedConflictPaths = []
        branchesVM.localBranches = []
        branchesVM.remoteBranches = []
        branchesVM.tags = []
        branchesVM.currentBranch = nil
        branchesVM.selection = []
        branchesVM.expandedFolders.removeAll()
        stashList = []
        changedFileCount = 0
    }

    func refreshAllForced() async {
        await refreshRepositoryAvailability()
        if let active = activeRepo, !availability(for: active).isAvailable {
            await selectRepo(active)
            return
        }

        coordinator.invalidateAll()
        await refreshPanels()
        // Re-run the on-screen diff bypassing the cache. `invalidateAll`
        // only clears L1, so a plain `selectFile` would fall through to the
        // pre-edit L2 disk snapshot and merely schedule a background refresh
        // the view never re-reads — leaving the Diff panel stale after an
        // external edit (editing the file in another app, resolving a
        // conflict in Beyond Compare, …). `reloadIfLive` force-refreshes the
        // working-tree / index / conflict / untracked diff that's showing,
        // and correctly leaves immutable commit / stash snapshots alone.
        await diffVM.reloadIfLive()
    }

    private func updateRepo(_ repo: RepositoryEntry, mutate: (inout RepositoryEntry) -> Void) {
        for gi in repositoriesConfig.groups.indices {
            for ri in repositoriesConfig.groups[gi].repositories.indices
            where repositoriesConfig.groups[gi].repositories[ri].id == repo.id {
                mutate(&repositoriesConfig.groups[gi].repositories[ri])
                if activeRepo?.id == repo.id {
                    activeRepo = repositoriesConfig.groups[gi].repositories[ri]
                }
                return
            }
        }
        for ri in repositoriesConfig.ungrouped.indices
        where repositoriesConfig.ungrouped[ri].id == repo.id {
            mutate(&repositoriesConfig.ungrouped[ri])
            if activeRepo?.id == repo.id { activeRepo = repositoriesConfig.ungrouped[ri] }
            return
        }
    }

    /// Status placeholder for menu items not yet wired to real git ops.
    func notImplemented(_ feature: String) {
        statusText = "\(feature) — not implemented yet"
        let id = output.begin(action: feature, command: "(not implemented)")
        output.finish(id: id, status: .failure, detail: "This action is not implemented in the MVP.")
    }

    // MARK: - Generic runner

    /// Centralised execution path: logs the command, runs it, records the
    /// outcome, then fires post-action cache invalidation on success and
    /// reloads the affected panels.
    /// `operation` receives the active repository path.
    @discardableResult
    /// - Parameter autostashAware: for commands run with `--autostash`.
    ///   They exit 0 whether the stashed changes went back cleanly or
    ///   conflicted, so the outcome has to be read out of the output and
    ///   said out loud — see `reportAutostash`.
    private func runGit(
        action: String,
        refreshOnFailure: Bool = false,
        forceBranches: Bool = false,
        autostashAware: Bool = false,
        operation: @escaping (String) async throws -> GitCommandResult,
        onSuccess: @escaping () -> Void = {},
        onFailure: @escaping () -> Void = {}
    ) async -> Bool {
        guard let repo = activeRepo else {
            statusText = "No active repository"
            return false
        }
        let id = output.begin(action: action, command: "")
        statusText = "\(action)…"
        inFlightCount += 1
        defer { inFlightCount -= 1 }

        let availability = await refreshAvailability(for: repo)
        guard availability.isAvailable else {
            output.finish(
                id: id,
                status: .failure,
                detail: availability.emptyStateMessage(path: repo.path)
            )
            selectUnavailableRepo(repo, availability: availability)
            return false
        }
        coordinator.beginAction(repoPath: repo.path)
        let result: GitCommandResult
        do {
            result = try await operation(repo.path)
        } catch {
            coordinator.endAction(repoPath: repo.path)
            output.finish(id: id, status: .failure, detail: String(describing: error))
            statusText = "\(action) — error"
            if coordinator.activeRepoPath == repo.path {
                if refreshOnFailure { onFailure() }
                coordinator.invalidateAll()
                await refreshAfterAction(repoPath: repo.path, forceBranches: forceBranches)
            }
            return false
        }
        coordinator.endAction(repoPath: repo.path)
        output.finish(id: id, result: result)
        if result.succeeded {
            statusText = "\(action) — done"
            if coordinator.activeRepoPath == repo.path {
                onSuccess()
                await refreshAfterAction(repoPath: repo.path, forceBranches: forceBranches)
                if autostashAware { reportAutostash(result, action: action) }
            }
            return true
        } else {
            statusText = Self.failureStatus(action, result: result)
            if coordinator.activeRepoPath == repo.path {
                if refreshOnFailure { onFailure() }
                coordinator.invalidateAll()
                await refreshAfterAction(repoPath: repo.path, forceBranches: forceBranches)
            }
            // Git cannot prompt for credentials or missing workflow access
            // here. Show the appropriate request and retain the operation
            // so it can be retried after the user completes authorization.
            let workflowURL = GitRemoteFailure.workflowPermissionURL(in: result.combinedOutput)
            if let url = workflowURL ?? GitCredentials.urlNeedingCredentials(in: result.combinedOutput),
               let parts = GitCredentials.components(of: url) {
                credentialRetry = { [weak self] in
                    _ = await self?.runGit(
                        action: action,
                        refreshOnFailure: refreshOnFailure,
                        forceBranches: forceBranches,
                        autostashAware: autostashAware,
                        operation: operation,
                        onSuccess: onSuccess,
                        onFailure: onFailure
                    )
                }
                credentialRequest = CredentialRequest(
                    action: action,
                    url: url,
                    scheme: parts.scheme,
                    host: parts.host,
                    suggestedUsername: parts.username,
                    repoPath: repo.path,
                    requiresWorkflowScope: workflowURL != nil
                )
            }
            return false
        }
    }
}
