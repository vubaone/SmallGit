import Foundation
import Observation

/// What the Diff panel is currently showing. Single source of truth for
/// the diff title, whether stage/unstage make sense, and which compare
/// mode we're displaying.
enum DiffSource: Sendable, Hashable {
    case none
    /// Diff of a tracked file in the working copy, parameterized by which
    /// two trees to compare (HEAD vs Index, or Index vs Working Tree).
    case fileChanges(file: String, mode: DiffCompareMode)
    /// File git has never seen — the diff is `--no-index` against
    /// `/dev/null`, so every line shows as an addition. Distinct from
    /// `.fileChanges` because the file isn't in the index; `git apply
    /// --cached` would fail on per-line/per-hunk staging with "does not
    /// exist in index". Whole-file staging via `git add` is still fine
    /// and routed through the toolbar / context-menu "Stage" button.
    case untrackedFile(file: String)
    /// File git records as conflicted (stages 1/2/3 populated). Loaded
    /// via `git diff HEAD -- file` so the working-tree content — markers
    /// and all — shows up as additions, matching SmartGit's preview.
    case conflict(file: String)
    /// A stash entry. `path` narrows it to one of the files the entry
    /// holds; nil shows everything in it at once.
    case stash(index: Int, path: String?)
    /// Multi-file diff for a single commit. Loaded when the user clicks
    /// a row in the Journal panel.
    case commit(hash: String, shortHash: String, subject: String)
    /// A submodule row. Not a file diff at all: git records a gitlink, so
    /// `git diff` answers with two SHAs and no content. What belongs on
    /// screen is the log between them, which `DiffViewModel.submoduleChange`
    /// carries.
    case submodule(path: String)

    var title: String {
        switch self {
        case .none:                  return "Changes"
        case .fileChanges(let f, let mode):
            switch mode {
            case .headVsIndex:        return "Staged changes of \(f)"
            case .indexVsWorkingTree: return "Changes of \(f)"
            }
        case .untrackedFile(let f):  return "New file \(f)"
        case .conflict(let f):       return "Conflict in \(f)"
        case .stash(let i, let path):
            guard let path else { return "Stash @{\(i)}" }
            return "Stash @{\(i)} — \(path)"
        case .commit(_, let s, let m): return "Commit \(s) — \(m)"
        case .submodule(let p):      return "Submodule \((p as NSString).lastPathComponent)"
        }
    }

    /// File path for actions that need one (Stage Hunk, Stage Line).
    /// Returns `nil` for diffs that can span multiple files (stash,
    /// commit).
    var file: String? {
        switch self {
        case .fileChanges(let f, _), .untrackedFile(let f), .conflict(let f): return f
        // A stash narrowed to one file names it — not to offer staging
        // (`isStageable` still says no) but so the view can syntax-colour
        // the rows for the language that file is written in.
        case .stash(_, let path): return path
        // Deliberately nil: Stage Hunk / Stage Line have no meaning for a
        // gitlink, and offering them would produce a patch git rejects.
        case .none, .commit, .submodule: return nil
        }
    }

    /// Compare mode for the file-changes case; `nil` for any other
    /// source. Drives the second segmented picker in the diff toolbar.
    var compareMode: DiffCompareMode? {
        if case .fileChanges(_, let mode) = self { return mode }
        return nil
    }

    /// True when the diff lines can be staged/unstaged via
    /// `git apply --cached`. Both file-change compare modes qualify;
    /// untracked files and conflicts are excluded for their own reasons.
    var isStageable: Bool {
        switch self {
        case .fileChanges:
            return true
        case .none, .untrackedFile, .conflict, .stash, .commit, .submodule:
            return false
        }
    }

    /// True for diffs of the staged index (reversed stage = unstage).
    var staged: Bool {
        if case .fileChanges(_, .headVsIndex) = self { return true }
        return false
    }
}

@MainActor
@Observable
final class DiffViewModel {

    var hunks: [DiffHunk] = []
    /// Set while `source` is `.submodule`, and nil otherwise. A gitlink has
    /// no hunks to put in `hunks`; this is what the panel renders instead.
    var submoduleChange: SubmoduleChange?
    var source: DiffSource = .none
    /// The files a `.commit` source is narrowed to; empty for the whole
    /// commit. Kept beside `source` so a whitespace or context toggle
    /// re-reads the same files rather than widening back to every one.
    private(set) var commitPaths: [String] = []
    var diffMode: DiffMode = .sideBySide
    /// Orthogonal to `diffMode`: the *amount of context* fetched. On (the
    /// default) = the short diff — only the changed regions plus a few
    /// lines of surrounding context. Off = the full file. Combines with
    /// either layout. Changing it re-fetches the diff (see the loaders),
    /// since git, not the view, decides how much context to emit.
    var compactMode: Bool = true
    var ignoreWhitespace: Bool = false

    /// Rows currently highlighted in the diff view. Drives "Stage Selection
    /// / Unstage Selection / Discard Selection" and "Copy Selection".
    /// Cleared whenever the diff source reloads — line ids are freshly
    /// minted each parse, so an old selection names nothing.
    var selection = DiffLineSelection()

    private let coordinator: CacheCoordinator
    private let git: GitService

    init(coordinator: CacheCoordinator, git: GitService = .shared) {
        self.coordinator = coordinator
        self.git = git
    }

    // MARK: - Loaders

    var unifiedRows: [(line: DiffLine, hunk: DiffHunk)] {
        hunks.flatMap { hunk in hunk.lines.map { (line: $0, hunk: hunk) } }
    }

    var pairedRows: [(left: DiffLine, right: DiffLine, hunk: DiffHunk)] {
        DiffPairing.pairs(from: hunks)
    }

    func loadDiff(file: String, mode: DiffCompareMode) async {
        source = .fileChanges(file: file, mode: mode)
        clearSelection()
        self.hunks = await cachedDiff(file: file, mode: mode) ?? []
    }

    /// Re-read the diff on screen when a background refresh corrected the
    /// entry it was drawn from.
    ///
    /// The panel refresh that follows an action reloads Files, Branches and
    /// the Journal but never this pane, so an edit made in another editor
    /// leaves the cached hunks describing the file as it was — and `get`
    /// answers with them, then refreshes behind the caller's back. This is
    /// the other half of that read: the corrected hunks, once they exist.
    ///
    /// Keys for anything else — a file the user has since clicked away from —
    /// are left alone.
    func adoptRefresh(of key: CacheKey) async {
        guard case .fileChanges(let file, let mode) = source,
              key == .diff(file: file, mode: mode, compact: compactMode),
              let value = await cachedDiff(file: file, mode: mode),
              Self.contentSignature(of: value) != Self.contentSignature(of: hunks) else {
            return
        }
        // Only now, and only because the hunks really did change: the
        // selection is line numbers into a diff that no longer exists.
        clearSelection()
        self.hunks = value
    }

    private func cachedDiff(file: String, mode: DiffCompareMode) async -> [DiffHunk]? {
        await coordinator.get(
            .diff(file: file, mode: mode, compact: compactMode),
            as: [DiffHunk].self,
            maxAge: 2
        ) { [git, ignoreWhitespace, compactMode] repo in
            try await git.diff(
                repoPath: repo,
                file: file,
                mode: mode,
                ignoreWhitespace: ignoreWhitespace,
                fullFile: !compactMode
            )
        }
    }

    /// What two hunk lists have to differ in for the pane to be redrawn.
    ///
    /// Not `==`: every parse mints fresh `UUID`s for hunks and lines, so two
    /// readings of an unchanged diff are never equal and the pane would throw
    /// the user's selection away on every background refresh.
    private static func contentSignature(of hunks: [DiffHunk]) -> [String] {
        hunks.map { hunk in
            let header = "\(hunk.oldStart),\(hunk.oldCount),\(hunk.newStart),\(hunk.newCount)"
            let body = hunk.lines
                .map { "\($0.type)\($0.oldLineNumber ?? -1)\($0.newLineNumber ?? -1)\($0.content)" }
                .joined(separator: "\n")
            return header + ":" + body
        }
    }

    /// Re-runs the active `.fileChanges` source via `forceRefresh`, so
    /// both L1 and L2 caches are bypassed. Use this after an external
    /// write (e.g. the in-place editor in the Compare dialog) — the
    /// normal `loadDiff` would otherwise read the pre-write L2 snapshot
    /// and show stale hunks until the cache catches up.
    func forceReloadCurrent() async {
        guard case .fileChanges(let file, let mode) = source else { return }
        clearSelection()
        let value = await coordinator.forceRefresh(
            .diff(file: file, mode: mode, compact: compactMode),
            as: [DiffHunk].self
        ) { [git, ignoreWhitespace, compactMode] repo in
            try await git.diff(
                repoPath: repo,
                file: file,
                mode: mode,
                ignoreWhitespace: ignoreWhitespace,
                fullFile: !compactMode
            )
        }
        self.hunks = value ?? []
    }

    /// Load a submodule's pointer change — the commits between what the
    /// parent records and what is checked out.
    ///
    /// Uncached, and deliberately so: it reads the submodule's own HEAD and
    /// log, neither of which the parent's cache keys know anything about,
    /// and it is a single selection's worth of work.
    func loadSubmodule(path: String) async {
        guard let repoPath = coordinator.activeRepoPath else { return }
        source = .submodule(path: path)
        hunks = []
        submoduleChange = await git.submoduleChange(repoPath: repoPath, path: path)
    }

    /// Re-run the current diff when it reflects mutable repo state (working
    /// tree / index / conflict / untracked), bypassing the cache. Commit and
    /// stash diffs are immutable snapshots, so they're left untouched. Call
    /// after any mutation (stage, unstage, discard, conflict resolve) so the
    /// panel's hunks never go stale under the user.
    func reloadIfLive() async {
        switch source {
        case .fileChanges:           await forceReloadCurrent()
        case .conflict(let file):    await loadConflictDiff(file: file)
        case .untrackedFile(let file): await loadUntrackedDiff(file: file)
        case .submodule(let path):   await loadSubmodule(path: path)
        case .none, .commit, .stash: break
        }
    }

    /// Refresh after a stage/unstage/discard. A stage moves content between
    /// the working tree and the index, so it changes *every* compare mode
    /// for the file — not just the one on screen. We re-fetch and show the
    /// current mode, and purge the other modes from L1+L2 so switching to
    /// them re-runs the diff fresh instead of serving the pre-change disk
    /// snapshot. Non-`fileChanges` sources fall back to a plain reload.
    func reloadAfterStaging() async {
        guard case .fileChanges(let file, _) = source else {
            await reloadIfLive()
            return
        }
        // A stage changes both the short and full-file variants of every
        // compare mode, so purge all four (2 modes × compact/full).
        let keys = Set(DiffCompareMode.allCases.flatMap { mode in
            [CacheKey.diff(file: file, mode: mode, compact: true),
             CacheKey.diff(file: file, mode: mode, compact: false)]
        })
        await coordinator.purge(keys)
        // Repopulates the current mode (L1+L2) fresh and updates `hunks`.
        await forceReloadCurrent()
    }

    /// Convenience for callers that still think in `staged: Bool` —
    /// kept so commit/checkout flows that don't yet know about the new
    /// picker don't need to map booleans by hand.
    func loadDiff(file: String, staged: Bool) async {
        await loadDiff(file: file, mode: staged ? .headVsIndex : .indexVsWorkingTree)
    }

    /// Switch the compare mode for the currently shown file without
    /// changing which file we're looking at. No-op when the source isn't
    /// a `.fileChanges` (combined picker is only visible in that case).
    func setCompareMode(_ mode: DiffCompareMode) async {
        guard case .fileChanges(let file, let current) = source, current != mode else { return }
        await loadDiff(file: file, mode: mode)
    }

    /// Conflicted files don't have a single staged blob — the index holds
    /// stages 1/2/3. Plain `git diff` against the index returns nothing
    /// usable, so we diff working-tree against HEAD; the result includes
    /// the `<<<<<<<` / `=======` / `>>>>>>>` markers as additions.
    func loadConflictDiff(file: String) async {
        source = .conflict(file: file)
        clearSelection()
        guard let repoPath = coordinator.activeRepoPath else {
            hunks = []
            return
        }
        do {
            hunks = try await git.conflictDiff(
                repoPath: repoPath,
                file: file,
                ignoreWhitespace: ignoreWhitespace,
                fullFile: !compactMode
            )
        } catch {
            hunks = []
        }
    }

    /// Untracked files don't have a baseline in git, so plain `git diff`
    /// returns nothing. This variant diffs the file against `/dev/null`
    /// so every line shows up as an addition in the Diff panel.
    func loadUntrackedDiff(file: String) async {
        source = .untrackedFile(file: file)
        clearSelection()
        guard let repoPath = coordinator.activeRepoPath else {
            hunks = []
            return
        }
        do {
            hunks = try await git.untrackedDiff(
                repoPath: repoPath,
                file: file,
                ignoreWhitespace: ignoreWhitespace
            )
        } catch {
            hunks = []
        }
    }

    /// Show the diff of a specific commit. Multi-file commits render as
    /// one flat hunk list (per-file boundaries currently elided — the
    /// hunk headers preserve the line-number anchor). Passing `paths`
    /// narrows the diff to those files within the commit — used by the
    /// Log window's Files pane to preview the rows it has selected without
    /// losing the surrounding commit context (title, source).
    func loadCommitDiff(_ commit: GitCommit, paths: [String] = []) async {
        source = .commit(hash: commit.hash, shortHash: commit.shortHash, subject: commit.subject)
        commitPaths = paths
        clearSelection()
        guard let repoPath = coordinator.activeRepoPath else {
            hunks = []
            return
        }
        do {
            hunks = try await git.commitDiff(
                repoPath: repoPath,
                hash: commit.hash,
                paths: paths,
                ignoreWhitespace: ignoreWhitespace,
                fullFile: !compactMode
            )
        } catch {
            hunks = []
        }
    }

    /// Show the diff of a stash entry. Passing `path` narrows it to one of
    /// the files the entry holds — what the Stash window's file list picks —
    /// and passing nil shows every file in the entry as one flat hunk list.
    func loadStashDiff(index: Int, path: String? = nil) async {
        source = .stash(index: index, path: path)
        clearSelection()
        guard let repoPath = coordinator.activeRepoPath else {
            hunks = []
            return
        }
        do {
            self.hunks = try await git.stashDiff(
                repoPath: repoPath,
                index: index,
                path: path,
                ignoreWhitespace: ignoreWhitespace,
                fullFile: !compactMode
            )
        } catch {
            self.hunks = []
        }
    }

    func clear() {
        hunks = []
        source = .none
        clearSelection()
    }

    // MARK: - Selection

    /// Flat list of every diff line in current source order. Used by the
    /// shift-click range extension to figure out which lines sit between
    /// two anchors. Empty pad lines are skipped — they have no underlying
    /// content and shouldn't be selectable.
    var flatLines: [DiffLine] {
        hunks.flatMap { $0.lines }.filter { $0.type != .empty }
    }

    /// Line ids currently selected. Kept as a name of its own because the
    /// staging commands ask for the set and nothing else about it.
    var selectedLineIDs: Set<UUID> { selection.ids }

    func clearSelection() {
        selection.clear()
    }

    /// The three click gestures, over the rows this diff is showing.
    func selectLine(_ line: DiffLine) {
        selection.click(line, within: flatLines)
    }

    /// What "Copy Selection" puts on the pasteboard.
    var selectedText: String {
        selection.text(of: flatLines)
    }
}
