import Foundation
import Observation

/// Everything the Submodule window needs to show one submodule, kept apart
/// from the repository the main window is working on.
///
/// This exists because the two must not be the same thing. Opening B's log
/// used to make B the active repository, which moved the main window off A
/// — and then B's commit dialog appeared over A's window, because that
/// dialog belongs to whatever is active. A submodule gets its own cache,
/// its own log, its own file list and its own commit here, so looking into
/// B changes nothing about working in A.
@MainActor
@Observable
final class SubmoduleSession: Identifiable {

    /// What a row in the log list can be. Uncommitted work sits above the
    /// history it is not part of yet.
    enum Node: Identifiable, Hashable {
        case uncommitted
        case commit(GitCommit)

        var id: String {
            switch self {
            case .uncommitted:   return "＊uncommitted"
            case .commit(let c): return c.hash
            }
        }
    }

    /// Repository that owns the submodule — where the pointer lives.
    let parentPath: String
    /// Repo-relative path of the submodule inside the parent.
    let path: String
    /// Absolute path: the repository every call in here runs against.
    let submodulePath: String

    // `nonisolated` because Identifiable is not: SwiftUI reads `id` while
    // diffing, from wherever it happens to be, and a main-actor `id` makes
    // the conformance cross actors — a warning today, an error in Swift 6.
    // `submodulePath` is an immutable String, so reading it off the main
    // actor is safe.
    nonisolated var id: String { submodulePath }

    /// The submodule's history, through the same view model the main
    /// Journal uses — which is what gives this window the same graph, lanes
    /// and rows rather than a flat list that only looks like a log.
    let journal: JournalViewModel
    var commits: [GitCommit] { journal.commits }

    private(set) var files: [GitFileStatus] = []
    private(set) var commitFiles: [GitFileStatus] = []
    /// Path of the file whose diff the pane below is showing, or `nil` when
    /// the pane holds a whole commit.
    ///
    /// The Files list marks it. Clicking a row only changed the pane, so the
    /// list itself gave no sign of which file was being read — and a list
    /// where every row looks the same after you have clicked one is a list
    /// you have to re-read to use.
    private(set) var shownFile: String?
    private(set) var recordedSHA: String?
    private(set) var headSHA: String?
    private(set) var branch: String?
    private(set) var isBusy = false
    private(set) var status: String?

    var selection: Node = .uncommitted
    var message: String = ""
    /// Paths the next commit will include — everything, until unticked.
    var staged: Set<String> = []

    /// The diff pane's own view model, pointed at the submodule through a
    /// cache of its own. Sharing the main window's would put B's diffs into
    /// A's panel.
    let diffVM: DiffViewModel
    private let coordinator: CacheCoordinator
    private let git: GitService
    private let output: OutputLog

    init(parentPath: String, path: String, git: GitService = .shared, output: OutputLog) {
        self.parentPath = parentPath
        self.path = path
        self.submodulePath = (parentPath as NSString).appendingPathComponent(path)
        self.git = git
        self.output = output
        let coordinator = CacheCoordinator(gitService: git)
        coordinator.switchRepo(to: self.submodulePath)
        self.coordinator = coordinator
        self.diffVM = DiffViewModel(coordinator: coordinator, git: git)
        self.journal = JournalViewModel(coordinator: coordinator, git: git)
    }

    var name: String { (path as NSString).lastPathComponent }

    /// True when the checkout is no longer the commit the parent records —
    /// including right after committing here, which is when the parent
    /// needs updating.
    var parentIsBehind: Bool {
        guard let headSHA, let recordedSHA else { return false }
        return headSHA != recordedSHA
    }

    var hasUncommittedWork: Bool { !files.isEmpty }

    // MARK: - Loading

    func load() async {
        isBusy = true
        defer { isBusy = false }

        async let log: Void = journal.forceRefresh()
        async let statusRows = (try? git.status(repoPath: submodulePath)) ?? []
        async let head = git.currentHeadSHA(repoPath: submodulePath)
        async let recorded = git.submoduleChange(repoPath: parentPath, path: path)?.recorded
        async let branchName = try? git.currentBranch(repoPath: submodulePath)

        await log
        let rows = await statusRows
        files = rows
        // Keep whatever the user has already unticked; tick anything new.
        let known = Set(rows.map(\.path))
        staged = staged.intersection(known).union(known.subtracting(seenPaths))
        seenPaths = known
        headSHA = try? await head
        recordedSHA = await recorded
        branch = await branchName

        if !hasUncommittedWork, case .uncommitted = selection, let first = commits.first {
            selection = .commit(first)
        }
        await loadSelection()
    }

    /// Paths seen by the previous load, so a file that appears while the
    /// window is open arrives ticked rather than silently excluded.
    private var seenPaths: Set<String> = []

    /// Load whatever the selected node shows: the commit's files, or the
    /// uncommitted ones.
    func loadSelection() async {
        // The pane is about to hold a whole commit, or nothing — either way
        // no single file is the one being read any more.
        shownFile = nil
        switch selection {
        case .uncommitted:
            commitFiles = []
            diffVM.clear()
        case .commit(let commit):
            commitFiles = (try? await git.commitFiles(repoPath: submodulePath, hash: commit.hash)) ?? []
            await diffVM.loadCommitDiff(commit)
        }
    }

    /// Show one file's diff in this window's own diff pane.
    func showDiff(for file: GitFileStatus) async {
        // Marked before the load, not after: the row answers the click at
        // once, rather than after git has been and come back.
        shownFile = file.path
        switch selection {
        case .uncommitted:
            if file.state == .untracked, !file.isStaged {
                await diffVM.loadUntrackedDiff(file: file.path)
            } else {
                await diffVM.loadDiff(file: file.path, mode: file.isStaged ? .headVsIndex : .indexVsWorkingTree)
            }
        case .commit(let commit):
            await diffVM.loadCommitDiff(commit, paths: [file.path])
        }
    }

    // MARK: - Committing

    var canCommit: Bool {
        !staged.isEmpty
        && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !isBusy
    }

    /// Stage the ticked paths and commit them — in the submodule, from this
    /// window. The parent is left alone: recording the new commit there is a
    /// separate act with its own message.
    func commit() async {
        let subject = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty, !staged.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        let paths = files.map(\.path).filter { staged.contains($0) }
        let id = output.begin(action: "Commit in \(name)", command: "git -C \(path) commit")
        do {
            _ = try await git.stage(repoPath: submodulePath, files: paths)
            let result = try await git.commit(repoPath: submodulePath, subject: subject)
            output.finish(id: id, result: result)
            message = ""
            status = "Committed in \(name) — the parent still records the old commit"
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            status = "Commit in \(name) failed — see Output"
            return
        }
        seenPaths = []
        await load()
        selection = commits.first.map(Node.commit) ?? .uncommitted
        await loadSelection()
    }

    /// Stage the submodule's new commit in the parent, so the parent's next
    /// commit records it. Deliberately stops short of committing there.
    func recordInParent() async {
        isBusy = true
        defer { isBusy = false }
        let id = output.begin(action: "Record \(name)", command: "git add \(path)")
        do {
            let result = try await git.stage(repoPath: parentPath, files: [path])
            output.finish(id: id, result: result)
            recordedSHA = headSHA
            status = "Staged \(path) in the parent — commit there to record it"
        } catch {
            output.finish(id: id, status: .failure, detail: String(describing: error))
            status = "Could not stage \(path) in the parent"
        }
    }

    // MARK: - Selection helpers

    func toggle(_ file: GitFileStatus) {
        if staged.contains(file.path) {
            staged.remove(file.path)
        } else {
            staged.insert(file.path)
        }
    }

    func setAllStaged(_ on: Bool) {
        staged = on ? Set(files.map(\.path)) : []
    }

    func isRecorded(_ commit: GitCommit) -> Bool { commit.hash == recordedSHA }

    /// Commits the submodule has that the parent has not recorded.
    func isAheadOfParent(_ commit: GitCommit) -> Bool {
        guard let recordedSHA,
              let recordedIndex = commits.firstIndex(where: { $0.hash == recordedSHA }),
              let own = commits.firstIndex(where: { $0.hash == commit.hash })
        else { return false }
        return own < recordedIndex
    }
}
