import Foundation
import Observation

/// The three column sorts offered by the Files table's headers.
///
/// Named constants rather than comparators written inline in the column
/// declarations: inside a `TableColumn` closure the inline form pushed the
/// expression past the type-checker's budget and failed to compile.
///
/// All three use `.localizedStandard`, the comparison Finder sorts with —
/// "v2" before "v10", and case never splits one directory's files into two
/// runs.
/// Sort for one Files-table column, chosen by clicking its header.
///
/// A hand-written comparator rather than a key-path one, for two reasons the
/// alternative kept running into: a `KeyPath` is not `Sendable`, which this
/// target compiles as a warning today and an error under Swift 6, and the
/// generic inference around a key-path comparator inside a `TableColumn`
/// closure pushed the type-checker past its budget.
///
/// The comparison is case- and numerics-aware, the way Finder sorts, so
/// "v2" lands before "v10" and capitalisation never splits one directory's
/// files into two runs.
struct FileSortComparator: SortComparator, Hashable {
    enum Field: Hashable, Sendable {
        case name
        case state
        /// The short code — "Mod", "Del" — rather than the full word.
        ///
        /// A commit's files all arrive staged, so `stateDisplay` reads
        /// "Staged" for every one of them and sorting by it would order
        /// nothing. The Log window's Files column shows the code for that
        /// reason, and a header sorts by what it shows.
        case stateCode
        case directory
    }

    var field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: GitFileStatus, _ rhs: GitFileStatus) -> ComparisonResult {
        let result = key(lhs).compare(key(rhs), options: [.caseInsensitive, .numeric])
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending:  return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame:       return .orderedSame
        }
    }

    private func key(_ file: GitFileStatus) -> String {
        switch field {
        case .name:      return file.name
        case .state:     return file.stateDisplay
        case .stateCode: return file.state.rawValue
        case .directory: return file.relativeDirectory
        }
    }
}

/// Drives the Files table — reads `git status` via the cache.
@MainActor
@Observable
final class FilesViewModel {

    var files: [GitFileStatus] = [] { didSet { rowsChanged() } }
    var selectedFileIDs: Set<String> = []
    var filterText: String = "" { didSet { rowsChanged() } }

    /// Per-file-type visibility toggles, surfaced as icon buttons in
    /// the Files panel header. Defaults mirror what most git GUIs
    /// (SmartGit, Tower) show out of the box: everything except
    /// ignored files. Conflicts are always shown — there's no useful
    /// "hide my unresolved conflicts" workflow.
    /// Column sort, driven by clicking a header in the Files table.
    ///
    /// Empty until the first click, which leaves the rows in the order git
    /// reported them — conflicts and staged entries where `git status` put
    /// them. Once the user sorts, the choice sticks for the session; it is
    /// deliberately not persisted, since the order you want while resolving
    /// a merge is rarely the one you want next week.
    var sortOrder: [FileSortComparator] = [] { didSet { rowsChanged() } }

    var showStaged:    Bool = true  { didSet { rowsChanged() } }
    var showUnstaged:  Bool = true  { didSet { rowsChanged() } }
    var showUntracked: Bool = true  { didSet { rowsChanged() } }
    var showIgnored:   Bool = false { didSet { rowsChanged() } }
    /// Whether to list files carrying the index's `assume-unchanged` flag.
    ///
    /// Off by default, like ignored files: these rows are not part of "what
    /// changed", which is the panel's question. Unlike the other four
    /// toggles this one doesn't filter what `git status` already reported —
    /// a flagged file is invisible to status by design — it adds a second
    /// list on top. That's also why the flag is so easy to forget you set,
    /// and why there is a view for it at all.
    var showAssumeUnchanged: Bool = false { didSet { rowsChanged() } }

    /// Paths flagged `assume-unchanged`, read when the view above is on.
    private(set) var assumeUnchangedPaths: [String] = [] { didSet { rowsChanged() } }
    /// Whether that list has come back yet. An empty list means two very
    /// different things — "nothing in this repository is flagged" and "we
    /// haven't looked" — and the tip under the header says the first of
    /// them out loud, so it must not say it while the read is in flight.
    private(set) var hasLoadedAssumeUnchanged: Bool = false

    /// Every path git tracks, loaded on demand the first time the user
    /// filters. The panel itself only ever lists what changed, but a
    /// filter is usually someone looking for a file — SmartGit answers
    /// with unchanged files too, and that's what makes it a fast finder
    /// rather than a way to narrow six rows to two.
    private(set) var trackedPaths: [String] = [] {
        didSet {
            // Folded once here rather than per keystroke: a repository can
            // track a hundred thousand paths, and lower-casing all of them
            // on every read of `filteredFiles` was most of what made a
            // large repository's file list feel stuck.
            trackedPathsFolded = trackedPaths.map { ($0, $0.lowercased()) }
            rowsChanged()
        }
    }
    @ObservationIgnored
    private var trackedPathsFolded: [(path: String, folded: String)] = []
    /// Guards the lazy load so a burst of keystrokes runs one `ls-files`.
    private(set) var isLoadingTrackedPaths: Bool = false

    private let coordinator: CacheCoordinator
    private let git: GitService

    init(coordinator: CacheCoordinator, git: GitService = .shared) {
        self.coordinator = coordinator
        self.git = git
    }

    var stagedFiles: [GitFileStatus] {
        files.filter { $0.isStaged }
    }

    var unstagedFiles: [GitFileStatus] {
        files.filter { $0.isUnstaged && !$0.isStaged }
    }

    /// Applies both the type-toggle filters and the free-text filter.
    /// Conflicts bypass type filters — a conflicted file must always
    /// surface so the user can resolve it.
    ///
    /// While a filter is active the matching *unchanged* files are
    /// appended after the changed ones, so the field doubles as a
    /// find-file across the whole working tree. They sort last when no
    /// column sort is set: what changed is still the answer to the
    /// panel's own question.
    ///
    /// Assume-unchanged files come in the same way when their view is on,
    /// ahead of the find-file matches so a flagged file isn't buried in
    /// them — and excluded from those matches, or a flagged path matching
    /// the filter would be listed twice.
    /// Bumped by every input `filteredFiles` reads.
    ///
    /// Observed — unlike the cache below — so a view reading `filteredFiles`
    /// still re-renders when the inputs change, even on the reads that are
    /// answered from cache.
    private var rowsVersion: Int = 0
    /// Last computed rows and the version they were computed at. Ignored by
    /// observation: filling a cache is not a change anyone should re-render
    /// for, and notifying from inside a read would loop.
    @ObservationIgnored
    private var cachedRows: (version: Int, rows: [GitFileStatus])?

    private func rowsChanged() { rowsVersion &+= 1 }

    /// The rows the table shows.
    ///
    /// Cached, because this is not a cheap property and it is read on every
    /// pass over the view: filtering the changed set, scanning every tracked
    /// path for the filter's text, and sorting the result. Selecting 17,000
    /// rows used to re-run all of that for each read, which is what turned
    /// ⌘A in a large repository into a hang.
    var filteredFiles: [GitFileStatus] {
        let version = rowsVersion
        if let cachedRows, cachedRows.version == version { return cachedRows.rows }
        let rows = computeFilteredFiles()
        cachedRows = (version, rows)
        return rows
    }

    /// How many unchanged files the filter will list before it stops.
    ///
    /// The filter is a finder, and a finder's job is to put the file you
    /// meant near the top — not to hand a table seventeen thousand rows to
    /// build, lay out and select. Everything that *changed* is always
    /// listed; only the tracked-but-unchanged matches are capped.
    static let maxUnchangedMatches = 500

    /// Matches the cap left out, so the panel can say so rather than
    /// quietly pretending the list is complete.
    @ObservationIgnored
    private var cachedTruncatedCount = 0

    /// Number of finder matches not shown. Reads `filteredFiles` first so
    /// the count belongs to the rows currently on screen.
    var truncatedMatchCount: Int {
        _ = filteredFiles
        return cachedTruncatedCount
    }

    private func computeFilteredFiles() -> [GitFileStatus] {
        var out = files.filter { passesTypeFilter($0) }
        let q = filterText.lowercased()
        if !q.isEmpty {
            out = out.filter { $0.path.lowercased().contains(q) }
        }

        var extras: [GitFileStatus] = []
        if showAssumeUnchanged {
            extras = Self.assumeUnchangedRows(
                in: assumeUnchangedPaths, query: q, excluding: files
            )
        }
        cachedTruncatedCount = 0
        if !q.isEmpty {
            let matches = Self.unchangedMatches(
                folded: trackedPathsFolded, query: q, excluding: files + extras
            )
            if matches.count > Self.maxUnchangedMatches {
                cachedTruncatedCount = matches.count - Self.maxUnchangedMatches
                extras += matches.prefix(Self.maxUnchangedMatches)
            } else {
                extras += matches
            }
        }
        out += extras

        if !sortOrder.isEmpty {
            out.sort(using: sortOrder)
        }
        return out
    }

    /// Tracked paths matching `query` that aren't already in the changed
    /// set, as rows the table can show. `nonisolated` so tests can drive
    /// the matching without an observable instance.
    nonisolated static func unchangedMatches(
        in trackedPaths: [String],
        query: String,
        excluding changed: [GitFileStatus]
    ) -> [GitFileStatus] {
        unchangedMatches(
            folded: trackedPaths.map { ($0, $0.lowercased()) },
            query: query,
            excluding: changed
        )
    }

    /// Same, given paths already folded to lower case.
    ///
    /// The panel keeps that folded copy because the alternative is folding
    /// every tracked path on every read — and "every tracked path" is six
    /// figures in a repository big enough for the filter to be the fastest
    /// way to find anything.
    nonisolated static func unchangedMatches(
        folded trackedPaths: [(path: String, folded: String)],
        query: String,
        excluding changed: [GitFileStatus]
    ) -> [GitFileStatus] {
        guard !query.isEmpty, !trackedPaths.isEmpty else { return [] }
        let q = query.lowercased()
        let known = Set(changed.map(\.path))
        return trackedPaths
            .filter { !known.contains($0.path) && $0.folded.contains(q) }
            // "." on both sides is porcelain v2 for "no change here",
            // which `GitFileStatus.state` reads as `.unmodified`.
            .map { GitFileStatus(path: $0.path, indexStatus: ".", workTreeStatus: ".") }
    }

    /// Flagged paths as rows the table can show, honouring `query` when
    /// one is typed and skipping anything `git status` already reported.
    ///
    /// A flagged file is normally absent from the changed set — that is
    /// what the flag does — but not always: flag a file *after* staging it
    /// and the staged entry stays. Those rows are already on screen with
    /// their real state, so this only adds the ones that would otherwise
    /// be invisible.
    ///
    /// `nonisolated` so tests can drive the matching without an observable
    /// instance, matching `unchangedMatches`.
    nonisolated static func assumeUnchangedRows(
        in flaggedPaths: [String],
        query: String,
        excluding changed: [GitFileStatus]
    ) -> [GitFileStatus] {
        guard !flaggedPaths.isEmpty else { return [] }
        let q = query.lowercased()
        let known = Set(changed.map(\.path))
        return flaggedPaths
            .filter { !known.contains($0) && (q.isEmpty || $0.lowercased().contains(q)) }
            // "." on both sides is porcelain v2 for "no change here" — the
            // only thing git will admit about a flagged file.
            .map {
                GitFileStatus(
                    path: $0,
                    indexStatus: ".",
                    workTreeStatus: ".",
                    isAssumeUnchanged: true
                )
            }
    }

    /// `true` when `file` should be visible given the current type
    /// toggles. Conflicts always pass.
    private func passesTypeFilter(_ file: GitFileStatus) -> Bool {
        if file.isConflict { return true }
        switch file.state {
        case .untracked: return showUntracked
        case .ignored:   return showIgnored
        default:
            // Tracked-and-changed: classified by stage state.
            if file.isStaged && !showStaged { return false }
            if !file.isStaged && file.isUnstaged && !showUnstaged { return false }
            return true
        }
    }

    /// How many files the filter is holding back. Counts the whole
    /// working tree once the tracked list is loaded — with unchanged
    /// files searchable, "hidden" means hidden out of everything, which
    /// is the number SmartGit shows.
    /// Files the current filter is not showing.
    ///
    /// Cached with the rows: this counts a union of every tracked path in
    /// the repository, which on a large one is as expensive as building the
    /// rows themselves — and the panel header reads it on every pass.
    var hiddenCount: Int {
        let version = rowsVersion
        if let cachedHidden, cachedHidden.version == version { return cachedHidden.count }
        let rows = filteredFiles
        let universe = Set(files.map(\.path)).union(trackedPaths).count
        let count = max(0, universe - rows.count)
        cachedHidden = (version, count)
        return count
    }

    @ObservationIgnored
    private var cachedHidden: (version: Int, count: Int)?

    var selectedPaths: [String] {
        files.filter { selectedFileIDs.contains($0.id) }.map(\.path)
    }

    /// The selection minus its conflicted rows — what Unstage can act on.
    /// `git reset` on a conflicted path does not take a staged change back:
    /// it collapses the merge stages and leaves a file full of markers that
    /// git no longer calls conflicted. See `AppState.unstage`.
    var selectedUnstageablePaths: [String] {
        files.filter { selectedFileIDs.contains($0.id) && !$0.isConflict }.map(\.path)
    }

    /// A discard split three ways, because "discard" is three different git
    /// commands and mixing them into one `git checkout --` breaks all three:
    /// git validates every pathspec up front, so a single untracked or
    /// conflicted file in the selection makes the whole command a no-op and
    /// nothing at all gets discarded.
    struct DiscardPlan: Equatable, Sendable {
        /// Tracked and unconflicted — `git checkout --`, working-tree edits
        /// only, anything staged stays staged.
        var tracked: [String] = []
        /// Conflicted — `git checkout HEAD --`, the only source that clears
        /// the unmerged stages.
        var conflicted: [String] = []
        /// Untracked — nothing to revert *to*; discarding means deleting.
        var untracked: [String] = []

        var isEmpty: Bool { tracked.isEmpty && conflicted.isEmpty && untracked.isEmpty }
        var all: [String] { tracked + conflicted + untracked }

        /// What the confirmation says. Spelled out per kind because the three
        /// outcomes differ in how far they go: a tracked file can be restored
        /// from the commit it came from, an untracked one is gone for good.
        /// A dialog that said only "discard the selected files" would be
        /// hiding the one consequence git cannot undo.
        var confirmationMessage: String {
            func files(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }
            var parts: [String] = []
            if !tracked.isEmpty {
                parts.append("Discards uncommitted changes in \(files(tracked.count)).")
            }
            if !conflicted.isEmpty {
                parts.append(
                    "Abandons the merge in \(files(conflicted.count)) and takes the committed version."
                )
            }
            if !untracked.isEmpty {
                parts.append(
                    "Permanently deletes \(files(untracked.count)) from disk — untracked files "
                    + "are not stored in Git, so this cannot be undone."
                )
            }
            return parts.joined(separator: " ")
        }
    }

    var selectedDiscardPlan: DiscardPlan {
        var plan = DiscardPlan()
        for file in files where selectedFileIDs.contains(file.id) {
            switch file.state {
            case .untracked, .ignored: plan.untracked.append(file.path)
            case .conflict:            plan.conflicted.append(file.path)
            default:                   plan.tracked.append(file.path)
            }
        }
        return plan
    }

    func load() async {
        guard !coordinator.isActionRunning else { return }
        let generation = coordinator.readGeneration
        let value = await coordinator.get(
            .fileStatus,
            as: [GitFileStatus].self,
            maxAge: 5
        ) { [git, showIgnored] repo in
            try await git.status(repoPath: repo, includeIgnored: showIgnored)
        }
        guard generation == coordinator.readGeneration else { return }
        if let value, files != value { self.files = value }
    }

    /// Load the tracked-file list, once, the first time a filter needs
    /// it. Deliberately not part of `load()`: `ls-files` on a large repo
    /// returns tens of thousands of paths, and the panel doesn't need
    /// them until someone types.
    func loadTrackedPathsIfNeeded() async {
        guard !coordinator.isActionRunning, trackedPaths.isEmpty, !isLoadingTrackedPaths else { return }
        let generation = coordinator.readGeneration
        isLoadingTrackedPaths = true
        defer { isLoadingTrackedPaths = false }
        let value = await cachedTrackedPaths()
        guard generation == coordinator.readGeneration else { return }
        if let value { self.trackedPaths = value }
    }

    /// Re-read the tracked list when a background refresh corrected the entry
    /// this panel was handed — but only if it is holding one. The list is
    /// loaded on demand for the same reason as above: fetching tens of
    /// thousands of paths for a filter nobody has typed into is the cost this
    /// panel is built to avoid, and a correction for a list we never read is
    /// not worth paying it.
    func adoptTrackedPathsRefresh() async {
        guard !coordinator.isActionRunning, !trackedPaths.isEmpty else { return }
        let generation = coordinator.readGeneration
        let value = await cachedTrackedPaths()
        guard generation == coordinator.readGeneration else { return }
        if let value, trackedPaths != value { self.trackedPaths = value }
    }

    private func cachedTrackedPaths() async -> [String]? {
        await coordinator.get(
            .trackedFiles,
            as: [String].self,
            maxAge: 60
        ) { [git] repo in
            try await git.trackedFiles(repoPath: repo)
        }
    }

    /// Read the flagged-file list. Cheap to call repeatedly — the
    /// coordinator serves it from L1 while it's warm, and any write to
    /// `.git/index` retires the key, so a flag set from the terminal shows
    /// up on the next read rather than being remembered forever.
    ///
    /// Called when the assume-unchanged view is switched on, not from
    /// `load()`: `ls-files -v` walks the whole index, and a panel showing
    /// what changed shouldn't pay for it.
    func loadAssumeUnchanged() async {
        guard !coordinator.isActionRunning else { return }
        let generation = coordinator.readGeneration
        let value = await coordinator.get(
            .assumeUnchangedFiles,
            as: [String].self,
            maxAge: 30
        ) { [git] repo in
            try await git.assumeUnchangedFiles(repoPath: repo)
        }
        guard generation == coordinator.readGeneration else { return }
        if let value {
            assumeUnchangedPaths = value
            hasLoadedAssumeUnchanged = true
        }
    }

    /// Re-read the flagged list past both caches. Used after SmallGit
    /// itself sets or clears a flag, where `loadAssumeUnchanged` would
    /// fall through to the stale disk snapshot — the same reason
    /// `forceRefresh` exists for file status.
    func refreshAssumeUnchanged() async {
        guard !coordinator.isActionRunning else { return }
        let generation = coordinator.readGeneration
        let value = await coordinator.forceRefresh(
            .assumeUnchangedFiles,
            as: [String].self
        ) { [git] repo in
            try await git.assumeUnchangedFiles(repoPath: repo)
        }
        guard generation == coordinator.readGeneration else { return }
        if let value {
            assumeUnchangedPaths = value
            hasLoadedAssumeUnchanged = true
        }
    }

    /// Drop the tracked list — on a repo switch it describes the wrong
    /// repository, and it's rebuilt on the next filter keystroke.
    func clearTrackedPaths() {
        trackedPaths = []
    }

    /// Same, for the flagged list: another repository's flags, and the
    /// view is left on so the next read refills it.
    func clearAssumeUnchangedPaths() {
        assumeUnchangedPaths = []
        hasLoadedAssumeUnchanged = false
    }

    /// Seam for tests, which have no repository behind the coordinator.
    func setTrackedPathsForTesting(_ paths: [String]) {
        trackedPaths = paths
    }

    /// Seam for tests — see `setTrackedPathsForTesting`.
    func setAssumeUnchangedPathsForTesting(_ paths: [String]) {
        assumeUnchangedPaths = paths
        hasLoadedAssumeUnchanged = true
    }

    func forceRefresh() async {
        guard !coordinator.isActionRunning else { return }
        let generation = coordinator.readGeneration
        let value = await coordinator.forceRefresh(
            .fileStatus,
            as: [GitFileStatus].self
        ) { [git, showIgnored] repo in
            try await git.status(repoPath: repo, includeIgnored: showIgnored)
        }
        // Gather the optional lists before publishing, so filtered rows and
        // flagged files belong to the same completed action as file status.
        var tracked: [String]?
        if !trackedPaths.isEmpty || !filterText.isEmpty {
            tracked = await coordinator.forceRefresh(.trackedFiles, as: [String].self) { [git] repo in
                try await git.trackedFiles(repoPath: repo)
            }
        }
        var flagged: [String]?
        if showAssumeUnchanged {
            flagged = await coordinator.forceRefresh(.assumeUnchangedFiles, as: [String].self) { [git] repo in
                try await git.assumeUnchangedFiles(repoPath: repo)
            }
        }
        guard generation == coordinator.readGeneration else { return }
        if let value, files != value { files = value }
        if let tracked, trackedPaths != tracked { trackedPaths = tracked }
        if let flagged {
            if assumeUnchangedPaths != flagged { assumeUnchangedPaths = flagged }
            hasLoadedAssumeUnchanged = true
        }
    }
}
