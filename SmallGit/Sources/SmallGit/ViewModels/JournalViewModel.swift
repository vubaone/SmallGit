import Foundation
import Observation

@MainActor
@Observable
final class JournalViewModel {

    var commits: [GitCommit] = []
    /// The focused commit — drives the diff view and Log window. Always a
    /// member of `selectedCommitIDs` when the selection is non-empty.
    var selectedCommitID: String?
    /// Full multi-selection. Single clicks collapse this to one id; cmd /
    /// shift clicks grow it (see `toggleSelection` / `extendSelection`).
    /// Used to highlight rows and to drive the range "Squash" action.
    var selectedCommitIDs: Set<String> = []
    /// Anchor for shift-click range extension — the last commit the user
    /// clicked without shift.
    var selectionAnchorID: String?
    /// True when the working-tree node at the top of the log is selected.
    ///
    /// Held apart from `selectedCommitIDs` on purpose: uncommitted work is
    /// not a commit, and letting it into that set would offer it to every
    /// range operation there — squash, cherry-pick, reset — each of which
    /// would then need to special-case a row that has no hash.
    private(set) var workingTreeSelected: Bool = false
    /// SHAs of commits ahead of the current branch's upstream — used by
    /// JournalView to render the orange "not pushed" marker.
    var unpushedHashes: Set<String> = []
    /// What the upstream holds that HEAD does not, when there is an upstream
    /// and it has drifted. Drives the incoming markers and the divergence
    /// banner, and puts the upstream into the graph — see
    /// `effectiveSelection`.
    var upstreamGap: UpstreamGap?
    /// Free-text filter applied to commit subject, author name + email,
    /// short hash. Matches are case-insensitive substring containment.
    ///
    /// Any edit forgets the gaps the user opened: clearing the field and
    /// pasting the same text back is a fresh search, and keying the
    /// expansions on the query alone brought them back open.
    var filterText: String = "" {
        didSet {
            if filterText.trimmingCharacters(in: .whitespacesAndNewlines)
                != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) {
                expandedRuns.removeAll()
            }
        }
    }
    /// Where the filter field's text is matched. `.local` filters the
    /// already-loaded commits live (the original behaviour); every other
    /// scope runs a git-backed search over the *entire* history on ⏎.
    var searchScope: JournalSearchScope = .local
    /// Non-nil while a git-backed search's results are being displayed.
    /// Replaces `commits` as the journal's data source (see
    /// `filteredCommits`) until cleared via the results banner or a repo
    /// switch. Written by `runSearch()` / `clearSearch()` (and tests).
    var searchResults: JournalSearchResults?
    /// Prevents stacked searches and drives the field's spinner.
    private(set) var isSearching: Bool = false
    /// Which refs the journal graphs — the Branches panel's checkboxes.
    /// Defaults to HEAD alone, which is the plain `git log` view. Ticking
    /// branches, remotes or tags widens it to the union of everything
    /// reachable from them, the way SmartGit's Branches view does.
    private(set) var refSelection: JournalRefSelection = .headOnly

    /// The single branch the journal is pinned to, or nil for HEAD. Kept
    /// as a derived view of `refSelection` because "one branch and
    /// nothing else" is still a distinct, nameable state — the banner
    /// says which branch, and squashing is only offered on HEAD's own
    /// history.
    var branchFilter: String? {
        guard !refSelection.head, refSelection.refs.count == 1 else { return nil }
        return refSelection.refs.first
    }
    /// `false` once a paged fetch returns fewer commits than requested —
    /// we've hit the repo root and there's no point asking again.
    var hasMore: Bool = true
    /// Prevents stacked load-more requests while one is in flight.
    private(set) var isLoadingMore: Bool = false
    /// Consecutive failed `loadMore()` attempts. Paging stops asking on
    /// its own once this hits `maxLoadMoreFailures` so a repo git can't
    /// read doesn't turn scrolling (or filtering) into an endless retry
    /// loop. Cleared by a successful page, a manual retry, or a reset.
    private(set) var loadMoreFailures: Int = 0

    /// Number of commits per page. The first `load()` fetches one page;
    /// each subsequent `loadMore()` grows the window by another page.
    static let pageSize: Int = 100
    /// How many times a failing fetch is retried before paging gives up.
    static let maxLoadMoreFailures: Int = 3
    /// While a local filter is active, how many matching rows we try to
    /// surface before we stop paging — roughly a panelful, enough that
    /// the result doesn't look like the whole answer when it isn't.
    static let filterMatchTarget: Int = 40
    /// How much deeper automatic paging may dig for a given filter
    /// query. Past this the footer's "Load more history" takes over, so
    /// a query that matches nothing can't quietly walk a huge repo's
    /// entire history in the background.
    static let filterAutoLoadLimit: Int = 2_000

    /// Commit count that automatic filter paging is allowed to grow the
    /// loaded window to, and the query it was granted for. A new query —
    /// or a click on the footer's button — grants a fresh budget; within
    /// one query the top-up stops at the ceiling no matter how many
    /// times rows scroll in and out and re-trigger it.
    private var filterLoadCeiling: Int = 0
    private var filterCeilingQuery: String?

    private let coordinator: CacheCoordinator
    private let git: GitService

    init(coordinator: CacheCoordinator, git: GitService = .shared) {
        self.coordinator = coordinator
        self.git = git
    }

    /// Commits matching `filterText` (or all commits if filter is empty).
    /// While a git-backed search is active its results *are* the journal —
    /// the local filter doesn't re-filter them.
    var filteredCommits: [GitCommit] {
        if let searchResults { return searchResults.commits }
        // Live filtering only applies in the `.local` scope — while a
        // git scope is selected the text is a pending query, and hiding
        // loaded commits as the user types it would be confusing.
        guard searchScope == .local else { return commits }
        return Self.filter(commits, query: filterText)
    }

    /// Count of commits hidden by the current filter. Surfaced in the
    /// panel header so the user knows when results are partial.
    var hiddenCount: Int {
        guard searchResults == nil, searchScope == .local else { return 0 }
        return max(0, commits.count - filteredCommits.count)
    }

    /// `true` when another page is worth asking for: history remains and
    /// the retry budget isn't spent.
    var canLoadMore: Bool { hasMore && loadMoreFailures < Self.maxLoadMoreFailures }

    /// `true` once paging gave up on repeated git failures — the footer
    /// offers a manual retry instead of silently showing a short list.
    var loadMoreFailed: Bool { loadMoreFailures >= Self.maxLoadMoreFailures }

    /// `true` when the live (loaded-commits) filter is actually narrowing
    /// the journal — the case where what's on screen depends on how deep
    /// we've paged, and paging deeper is what surfaces more matches.
    var isFilteringLocally: Bool {
        searchResults == nil && searchScope == .local && !normalizedFilter.isEmpty
    }

    private var normalizedFilter: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scopes cheap enough to run as the user types: `--grep` and
    /// `--author` read commit headers only. `-S`/`-G` diff every commit
    /// against its parent, which on a large repo is a minute-long walk —
    /// those stay on ⏎.
    var searchRunsAsYouType: Bool {
        switch searchScope {
        case .message, .author:        return true
        case .local, .content, .contentRegex: return false
        }
    }

    /// `true` when the field holds a git-scope query that hasn't been run
    /// yet. The journal is showing the *unfiltered* log in that state,
    /// which reads as a broken filter unless we say otherwise — the
    /// placeholder that explains ⏎ is gone the moment the user types.
    var hasPendingSearch: Bool {
        guard searchScope != .local, !normalizedFilter.isEmpty else { return false }
        guard let searchResults else { return true }
        return searchResults.query != normalizedFilter || searchResults.scope != searchScope
    }

    /// Identity of "what the field is currently asking for". The view
    /// keys its debounce task on this so a scope change re-runs the same
    /// text, and vice versa.
    var searchRequestKey: String { "\(searchScope.rawValue)|\(filterText)" }

    /// Everything the filter field triggers, debounced by the caller:
    /// page deeper for a local filter, run the git search for a scope
    /// that searches as you type, and drop stale results once the field
    /// is emptied or switched back to the local filter.
    func applyFilterInput() async {
        if searchScope == .local || normalizedFilter.isEmpty {
            // Results from a git scope are stale the moment the query
            // stops describing them — and a search still running for that
            // query is just a git process nobody is waiting for.
            cancelSearch()
            if searchResults != nil { clearSearch() }
        }
        if isFilteringLocally {
            await loadMoreForFilter()
        } else if searchRunsAsYouType, hasPendingSearch {
            // Supersedes any search still running: the one in flight
            // answers a query the user has already typed past.
            startSearch()
        }
    }

    // MARK: - Git-backed search

    /// The search currently running. Held so it can be cancelled: a `-S`
    /// pickaxe over a large repo walks every commit's diff for minutes,
    /// and the git process only dies when its task does.
    private var searchTask: Task<Void, Never>?
    /// Bumped on every start and cancel, so a search that finishes after
    /// being superseded can't publish its results — or clear the spinner
    /// belonging to the search that replaced it.
    private var searchGeneration: Int = 0

    /// Start the search the field describes, replacing whatever search is
    /// already running. Wired to ⏎ and to the search-as-you-type scopes.
    func startSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in await self?.runSearch() }
    }

    /// Stop the running search and leave the journal as it was. The git
    /// process gets SIGTERM through the task's cancellation handler —
    /// without this, clearing the field left a two-minute pickaxe running
    /// and the spinner spinning with no way to stop it.
    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration += 1
        isSearching = false
    }

    /// Run the search described by `filterText` + `searchScope` against
    /// git. No-op for the `.local` scope (which filters live as you type)
    /// and empty queries.
    func runSearch() async {
        guard let mode = searchScope.gitMode else { return }
        let query = normalizedFilter
        guard !query.isEmpty else { return }
        guard let repo = coordinator.activeRepoPath else { return }
        let scope = searchScope
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        defer { if generation == searchGeneration { isSearching = false } }

        do {
            // Uncached on purpose: searches are ad-hoc one-offs, and going
            // through the cache would let a stale page shadow a fresh hit.
            let revisions = refSelection.revisions
            let found = try await git.searchLog(
                repoPath: repo,
                query: query,
                mode: mode,
                revisions: revisions
            )
            guard isCurrent(generation) else { return }
            searchResults = JournalSearchResults(
                query: query, scope: scope, commits: found, failed: false
            )
            clearSelection()
        } catch {
            // A cancelled search isn't a failed one — the user moved on
            // and we killed the process on purpose. Publishing "search
            // failed" for a query they abandoned would be a lie.
            guard isCurrent(generation) else { return }
            searchResults = JournalSearchResults(
                query: query, scope: scope, commits: [], failed: true,
                timedOut: Self.isTimeout(error)
            )
            clearSelection()
        }
    }

    /// `true` while this search is still the one the user is waiting for.
    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == searchGeneration
    }

    private nonisolated static func isTimeout(_ error: Error) -> Bool {
        if case ProcessError.timedOut = error { return true }
        return false
    }

    /// Drop search results and return the journal to the loaded log.
    func clearSearch() {
        cancelSearch()
        searchResults = nil
        clearSelection()
    }

    /// Reload the log, bypassing every cache layer.
    ///
    /// What the panel refresh after a git action uses, for the reason the
    /// Files panel needs the same thing: post-action invalidation only
    /// clears L1, so a plain `load` falls through to the L2 disk snapshot —
    /// the log as it was *before* the action — and merely schedules a
    /// background refresh this view never re-reads. The commit just made
    /// would then be missing until a file-watcher tick happened to reload
    /// the journal a second time.
    func forceRefresh() async {
        await load(force: true)
    }

    func load(force: Bool = false) async {
        // Nothing ticked is an empty graph, not "everything" — and asking
        // git for it would answer with HEAD's log, which is the one thing
        // the user just switched off.
        guard !refSelection.isEmpty else {
            commits = []
            unpushedHashes = []
            upstreamGap = nil
            hasMore = false
            return
        }
        // Preserve any pages the user already scrolled into. Without
        // this, a file-watcher-triggered refresh shrinks the list back
        // to one page and the user loses their place.
        let target = max(Self.pageSize, commits.count)
        let selection = refSelection
        let headBranch = await checkedOutBranch(for: selection)
        // Whenever HEAD is in the graph, not only when it is the whole graph.
        // The marker answers "is this commit on my upstream yet", which is a
        // property of the commit and HEAD's own upstream — ticking a second
        // ref doesn't make it any less true. Suppressing it there is what
        // makes a branch one commit ahead of its remote look like a bug:
        // the local chip and the `origin/…` chip sit on different rows, with
        // nothing on screen saying the row between them hasn't been pushed.
        // Nor does it matter whether HEAD was ticked as HEAD or as the
        // branch it has checked out: a rebased branch ticked by name next to
        // another one showed no markers and no fork at all.
        let graphsHead = selection.graphsHead(checkedOut: headBranch)
        async let unpushed: Set<String> = graphsHead ? loadUnpushedHashes() : []
        async let gapValue: UpstreamGap? = graphsHead ? loadUpstreamGap() : nil

        // Before the log, because it is what decides which refs the log is
        // asked for.
        let gap = await gapValue
        self.upstreamGap = gap
        async let logValue: [GitCommit]? = fetchLog(
            Self.effectiveSelection(selection, gap: gap, checkedOut: headBranch),
            count: target,
            force: force
        )

        if let value = await logValue {
            // Only when something actually moved. `load()` is now also how a
            // corrected background refresh reaches the graph, and most of
            // those bring back exactly what is already on screen — assigning
            // an identical array would redraw every row for nothing.
            if value != commits { self.commits = value }
            // A short fetch means git ran out of commits.
            self.hasMore = value.count >= target
        }
        self.unpushedHashes = await unpushed
    }

    /// One page of log, from the cache or straight from git.
    private func fetchLog(
        _ selection: JournalRefSelection,
        count: Int,
        force: Bool
    ) async -> [GitCommit]? {
        let revisions = selection.revisions
        let fetcher: @Sendable (String) async throws -> [GitCommit] = { [git] repo in
            try await git.log(repoPath: repo, count: count, revisions: revisions)
        }
        let key = CacheKey.log(refs: selection.cacheToken)
        if force {
            return await coordinator.forceRefresh(key, as: [GitCommit].self, fetcher: fetcher)
        }
        return await coordinator.get(key, as: [GitCommit].self, maxAge: 10, fetcher: fetcher)
    }

    // MARK: - Ref selection

    /// Replace the whole selection and reload. Every mutating entry point
    /// funnels here so the reset-and-reload is written once.
    func setRefSelection(_ selection: JournalRefSelection) async {
        guard selection != refSelection else { return }
        refSelection = selection
        searchResults = nil
        commits = []
        unpushedHashes = []
        upstreamGap = nil
        clearSelection()
        resetPagination()
        await load()
    }

    /// Tick or untick one ref.
    func setRef(_ ref: String, checked: Bool) async {
        var next = refSelection
        next.set(ref, checked: checked)
        await setRefSelection(next)
    }

    /// Tick or untick a whole group — a section header or a folder node,
    /// which is how SmartGit's category checkboxes behave.
    func setRefs(_ refs: [String], checked: Bool) async {
        var next = refSelection
        next.set(refs, checked: checked)
        await setRefSelection(next)
    }

    func setHeadSelected(_ on: Bool) async {
        var next = refSelection
        next.head = on
        await setRefSelection(next)
    }

    /// Back to the default: HEAD and nothing else.
    func showHeadOnly() async {
        await setRefSelection(.headOnly)
    }

    /// Restore a persisted selection without reloading — the caller is
    /// about to load anyway (repo switch).
    func restoreRefSelection(_ selection: JournalRefSelection) {
        refSelection = selection
        resetPagination()
    }

    /// Drop ticked refs that no longer exist, reloading if any went away.
    /// A selection outlives the branches in it: someone deletes a branch,
    /// and a stale tick would otherwise keep widening the graph by a
    /// revision git can no longer resolve.
    func pruneRefSelection(keeping known: Set<String>) async {
        var next = refSelection
        next.prune(keeping: known)
        guard next != refSelection else { return }
        await setRefSelection(next)
    }

    /// Switch the Journal between HEAD and a specific branch's log — the
    /// branch context menu's "Log", which is "tick only this one".
    func setBranchFilter(_ branch: String?) async {
        guard let branch else {
            await showHeadOnly()
            return
        }
        await setRefSelection(JournalRefSelection(head: false, refs: [branch]))
    }

    /// Fetches the next page of commits and appends any new ones to the
    /// in-memory list. No-op while a load is in flight, once history is
    /// exhausted, or after the retry budget is spent.
    ///
    /// Uses `forceRefresh` rather than `get` so the bigger list is
    /// written back into both L1 and L2 — otherwise the disk cache
    /// would still hold the page-1 value and a later `load()` would
    /// shrink the journal back under the user.
    /// - Parameter pages: how many pages to grow the window by in this
    ///   one fetch. Each call re-runs `git log` from HEAD, so a top-up
    ///   that needs depth is far cheaper as a few big fetches than as
    ///   many single-page ones.
    func loadMore(pages: Int = 1) async {
        guard canLoadMore, !isLoadingMore, !refSelection.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let target = commits.count + Self.pageSize * max(1, pages)
        let selection = refSelection
        let revisions = selection.revisions
        let fetched: [GitCommit]? = await coordinator.forceRefresh(
            .log(refs: selection.cacheToken),
            as: [GitCommit].self
        ) { [git] repo in
            try await git.log(repoPath: repo, count: target, revisions: revisions)
        }
        // nil means git errored (or the repo went away) — that's a
        // failure, not the end of history, so spend a retry rather than
        // declaring the log finished.
        guard let bigger = fetched else {
            loadMoreFailures += 1
            return
        }
        loadMoreFailures = 0

        // If git returned no new rows past what we already had, we've
        // reached the root and should stop asking.
        if bigger.count <= commits.count {
            hasMore = false
            return
        }
        commits = bigger
        // A short page means git ran out — flip the flag so we stop.
        hasMore = (bigger.count >= target)
    }

    /// Page deeper until the live filter has `target` matches to show.
    /// Bounded on three sides — the match target, the per-query depth
    /// ceiling, and the shared retry budget — so a query that matches
    /// nothing can't walk a huge repo's whole history.
    private func topUp(untilMatches target: Int) async {
        let ceiling = grantedCeiling()
        // Escalating page sizes: 1, 2, 4, 8 pages. Depth gets expensive
        // linearly but the number of `git log` invocations stays small.
        var pages = 1
        while canLoadMore,
              !Task.isCancelled,
              filteredCommits.count < target,
              commits.count < ceiling {
            let before = commits.count
            await loadMore(pages: pages)
            // No growth means git ran out, errored, or another load is
            // already in flight — in every case, stop looping.
            guard commits.count > before else { break }
            pages = min(pages * 2, 8)
        }
    }

    /// The depth automatic paging may reach for the current query,
    /// granting a fresh budget the first time we see that query.
    private func grantedCeiling() -> Int {
        let query = normalizedFilter
        if filterCeilingQuery != query {
            filterCeilingQuery = query
            filterLoadCeiling = commits.count + Self.filterAutoLoadLimit
        }
        return filterLoadCeiling
    }

    /// Top up after the filter text changed. Filtering a single page of
    /// a huge repo otherwise shows two or three rows and reads like the
    /// complete answer; this pulls enough history for the filter to mean
    /// something. No-op when nothing is being filtered, or when the
    /// loaded commits already yield enough matches — we only fetch when
    /// the view actually needs it.
    func loadMoreForFilter() async {
        guard isFilteringLocally else { return }
        await topUp(untilMatches: Self.filterMatchTarget)
    }

    /// Called when the journal's last rows come on screen. Without a
    /// filter that's one more page; with one, it's however much history
    /// it takes to surface at least one further match (still bounded).
    func loadMoreIfNeeded() async {
        if isFilteringLocally {
            await topUp(untilMatches: filteredCommits.count + 1)
        } else {
            await loadMore()
        }
    }

    /// The footer button. An explicit click is a fresh intent, so it
    /// clears the retry budget before asking again — a transient git
    /// failure shouldn't wedge paging for the rest of the session.
    func loadMoreManually() async {
        loadMoreFailures = 0
        // Grant another budget from wherever we are now, so the click
        // digs further instead of hitting the same exhausted ceiling.
        filterCeilingQuery = normalizedFilter
        filterLoadCeiling = commits.count + Self.filterAutoLoadLimit
        await loadMoreIfNeeded()
    }

    /// Reset paging state. Called on repo switch / forced refresh so the
    /// next `load()` starts fresh from page 1.
    func resetPagination() {
        hasMore = true
        isLoadingMore = false
        loadMoreFailures = 0
        filterCeilingQuery = nil
        filterLoadCeiling = 0
        expandedRuns.removeAll()
    }

    /// Fetch the unpushed-SHA set directly (uncached — it's fast and
    /// shifts on every commit / push).
    private func loadUnpushedHashes() async -> Set<String> {
        guard let repo = coordinator.activeRepoPath else { return [] }
        return (try? await git.unpushedHashes(repoPath: repo)) ?? []
    }

    private func loadUpstreamGap() async -> UpstreamGap? {
        guard let repo = coordinator.activeRepoPath else { return nil }
        return (try? await git.upstreamGap(repoPath: repo)) ?? nil
    }

    /// The checked-out branch, when it matters: only a selection with HEAD
    /// unticked can be holding it by name instead.
    private func checkedOutBranch(for selection: JournalRefSelection) async -> String? {
        guard !selection.head, !selection.refs.isEmpty,
              let repo = coordinator.activeRepoPath
        else { return nil }
        return (try? await git.currentBranch(repoPath: repo)) ?? nil
    }

    /// The refs actually handed to `git log`.
    ///
    /// When the upstream holds commits HEAD does not, it joins the graph even
    /// though the user has only ticked HEAD. A squash or a rebase leaves the
    /// branch ahead *and* behind, and a log drawn from HEAD alone shows the
    /// rewritten side only — one tip, no sign of the commits still sitting on
    /// the remote, which is exactly the half worth seeing. With both in, the
    /// two tips are drawn as what they are: a fork.
    ///
    /// The user's own selection is left alone. This widens the query, not the
    /// setting, so "HEAD Only" stays the state the Branches panel reports and
    /// goes back to a plain `git log` the moment the upstream is an ancestor
    /// of HEAD again.
    static func effectiveSelection(
        _ selection: JournalRefSelection,
        gap: UpstreamGap?,
        checkedOut branch: String? = nil
    ) -> JournalRefSelection {
        guard selection.graphsHead(checkedOut: branch), let gap, !gap.isEmpty
        else { return selection }
        var out = selection
        out.refs.insert(gap.ref)
        return out
    }

    /// `true` when `commit` is ahead of the current upstream and has
    /// therefore not been pushed yet.
    func isUnpushed(_ commit: GitCommit) -> Bool {
        unpushedHashes.contains(commit.hash)
    }

    /// `true` when `commit` is on the upstream and not on HEAD — the other
    /// side of a fork, which a pull or a force push is about to settle.
    func isIncoming(_ commit: GitCommit) -> Bool {
        upstreamGap?.incoming.contains(commit.hash) ?? false
    }

    /// How far the branch and its upstream have drifted apart, or nil when
    /// they have not. Ahead is measured by the outgoing markers, which is the
    /// same question asked from the other end.
    var upstreamDivergence: (ref: String, ahead: Int, behind: Int)? {
        guard let gap = upstreamGap, !gap.isEmpty else { return nil }
        return (gap.ref, unpushedHashes.count, gap.incoming.count)
    }

    /// Whether changing this commit's message would rewrite the current
    /// branch rather than an unrelated ref shown in the graph.
    ///
    /// Follow HEAD's parent links regardless of which other refs are graphed.
    /// Published commits on HEAD remain editable: the reword sheet warns
    /// before rewriting them. Commits belonging only to another branch or a
    /// diverged upstream are excluded, including when `effectiveSelection`
    /// adds that upstream to a "HEAD Only" log. Git-backed search results
    /// stay read-only because a rewrite would leave their hashes stale.
    func canChangeMessage(of commit: GitCommit) -> Bool {
        guard searchResults == nil else { return false }
        return isOnHeadHistory(commit.hash)
    }

    /// Whether the fixup pair — commit staged work as a fixup of this row,
    /// autosquash from it — may be offered.
    ///
    /// The fixup commit lands on HEAD and autosquash rewrites HEAD's history,
    /// so a row from a pinned branch's log, or from the diverged upstream now
    /// graphed beside HEAD, would act on the wrong ref. Hidden during a
    /// git-backed search too: autosquash rewrites the history the results
    /// point into, leaving the displayed hits referring to SHAs that no
    /// longer exist.
    func canFixup(_ commit: GitCommit) -> Bool {
        guard searchResults == nil, refSelection.isHeadOnly else { return false }
        return isOnHeadHistory(commit.hash)
    }

    // MARK: - Interactive rebase

    /// What the Journal's context menu can offer for an interactive rebase on
    /// the right-clicked row.
    ///
    /// Two shapes, because one `git rebase -i <commit>` means two different
    /// things depending on where the clicked commit sits, and the menu has to
    /// say which one it is about to do.
    enum InteractiveRebaseAvailability: Equatable {
        /// The commit is on HEAD's history. It becomes the base and the
        /// commits after it — listed here, newest first — are replayed on top.
        case fromHere([GitCommit])
        /// The commit is on another line of history: a branch tip, an upstream
        /// graphed beside HEAD, anything HEAD does not descend from. It
        /// becomes the base and HEAD's own commits since the two diverged are
        /// replayed on top of it — "take that branch, put my work on its end".
        ///
        /// No commit list travels with it. That range starts at the merge-base,
        /// which is routinely older than the window the Journal has paged in,
        /// so it is asked of git when the planner opens.
        case onto
        /// Offered but disabled. The string is the menu row to draw: the
        /// command belongs on this menu, so saying why it can't run beats
        /// dropping the row and leaving the user hunting for it.
        case blocked(String)
    }

    /// Which interactive rebase this row offers, and if none, what to say.
    ///
    /// The clicked commit always becomes the *base* and is itself untouched;
    /// git replays `<commit>..HEAD` on top of it. Where the commit sits decides
    /// what that range holds, and both readings are things people ask for:
    ///
    /// - on HEAD's history — the range is the commits after it, which is the
    ///   reorder / squash / drop pass over your own recent work;
    /// - anywhere else — the range is everything HEAD has gained since the two
    ///   lines diverged, which is "rebase my branch onto that one". This used
    ///   to be refused outright as "this commit isn't on HEAD". It is the
    ///   ordinary way to move a branch onto an updated base, and git resolves
    ///   the range exactly the way the planner lists it; what was missing was
    ///   naming the direction so nobody mistakes it for the first reading.
    ///
    /// A commit on HEAD's history but below the loaded window reads as the
    /// second case, because `commitsToReplay` cannot walk to it and says so.
    /// The command it runs is still the right one — the merge-base of an
    /// ancestor and HEAD is that ancestor — so only the wording is off, and
    /// only until the journal has paged far enough to know better.
    ///
    /// Two things are refused either way:
    ///
    /// - nothing to replay — `HEAD..HEAD` is empty and git would open an empty
    ///   plan. Only checkable here for the on-HEAD reading; for the other one
    ///   `startInteractiveRebase` catches it against git and says so;
    /// - a merge in the range — `rebase -i` omits merge commits from the todo
    ///   and replays their side branches inline, flattening history without
    ///   reporting it. Same split: checked here where the graph can answer,
    ///   and against git for the range that reaches past it.
    ///
    /// Blocked during a git-backed search for the same reason as `canFixup`:
    /// a rewrite leaves the displayed hits pointing at SHAs that are gone.
    func interactiveRebaseAvailability(from commit: GitCommit) -> InteractiveRebaseAvailability {
        if searchResults != nil {
            return .blocked("Rebase Interactive — not while search results are shown")
        }
        guard let replayed = commitsToReplay(after: commit.hash) else {
            // Not on HEAD's history — the other reading, and the range is
            // git's to work out.
            return .onto
        }
        if replayed.isEmpty {
            return .blocked("Rebase Interactive — nothing comes after this commit")
        }
        if let merge = replayed.first(where: \.isMerge) {
            return .blocked("Rebase Interactive — merge \(merge.shortHash) would be flattened")
        }
        return .fromHere(replayed)
    }

    /// The commits in `<hash>..HEAD` — reachable from HEAD, not from `hash` —
    /// in log order (newest first). Nil when `hash` is not on HEAD's history,
    /// empty when `hash` *is* HEAD.
    ///
    /// Walked over the parent links already loaded rather than asked of git,
    /// for the same reason as `isOnHeadHistory`: this answers a context menu
    /// being built. It carries the same caveat — a walk that reaches a commit
    /// whose parents haven't been paged in stops there, so a `hash` below the
    /// loaded window reads as unreachable and the row is blocked rather than
    /// wrongly offered. Note that a non-nil, merge-free result is necessarily
    /// complete: every step of a single-parent chain had to be in hand for
    /// the walk to arrive at `hash` at all.
    func commitsToReplay(after hash: String) -> [GitCommit]? {
        guard let head = commits.first(where: { $0.isHead }) else { return nil }
        if head.hash == hash { return [] }

        var byHash = [String: GitCommit](minimumCapacity: commits.count)
        for commit in commits { byHash[commit.hash] = commit }

        var reached = false
        var visited: Set<String> = []
        var pending = [head.hash]
        while let next = pending.popLast() {
            // Stop at the base: it is what everything replays onto, so it
            // is deliberately not part of the range.
            if next == hash { reached = true; continue }
            guard visited.insert(next).inserted, let commit = byHash[next] else { continue }
            pending.append(contentsOf: commit.parentHashes)
        }
        guard reached else { return nil }
        // Filtered out of `commits` rather than collected during the walk so
        // the result keeps the log's own topological order.
        return commits.filter { visited.contains($0.hash) }
    }

    // MARK: - Selection

    /// `true` when `commit` is part of the current selection — used by the
    /// view to paint the row highlight.
    func isSelected(_ commit: GitCommit) -> Bool {
        selectedCommitIDs.contains(commit.id)
    }

    /// Collapse the selection to a single commit and anchor on it. Used
    /// for plain (unmodified) clicks.
    /// Select the working tree — the uncommitted node — and nothing else.
    func selectWorkingTree() {
        workingTreeSelected = true
        selectedCommitIDs = []
        selectedCommitID = nil
        selectionAnchorID = nil
    }

    func selectOnly(_ commit: GitCommit) {
        workingTreeSelected = false
        selectedCommitIDs = [commit.id]
        selectionAnchorID = commit.id
        selectedCommitID = commit.id
    }

    /// Toggle one commit in/out of the selection. Used for cmd-clicks.
    /// Anchors on the toggled commit so a follow-up shift-click extends
    /// from there, and keeps it focused for the diff view.
    func toggleSelection(_ commit: GitCommit) {
        workingTreeSelected = false
        if selectedCommitIDs.contains(commit.id) {
            selectedCommitIDs.remove(commit.id)
        } else {
            selectedCommitIDs.insert(commit.id)
        }
        selectionAnchorID = commit.id
        selectedCommitID = commit.id
    }

    /// Extend the selection from `selectionAnchorID` to `commit` along the
    /// filtered (display) order. Used for shift-clicks. Falls back to a
    /// single-commit selection when no anchor exists yet.
    func extendSelection(to commit: GitCommit) {
        workingTreeSelected = false
        let filtered = filteredCommits
        guard let anchorID = selectionAnchorID,
              let a = filtered.firstIndex(where: { $0.id == anchorID }),
              let b = filtered.firstIndex(where: { $0.id == commit.id })
        else {
            selectOnly(commit)
            return
        }
        let lo = min(a, b)
        let hi = max(a, b)
        selectedCommitIDs = Set(filtered[lo...hi].map(\.id))
        selectedCommitID = commit.id
    }

    func clearSelection() {
        selectedCommitIDs.removeAll()
        selectionAnchorID = nil
        workingTreeSelected = false
    }

    /// The selected commits as a contiguous slice of *history*, ordered
    /// newest→oldest (so `.last` is the oldest). Returns nil unless at
    /// least two commits are selected and they sit next to each other in
    /// the log — the precondition for a range squash.
    ///
    /// Contiguity is judged against the full commit list, not the
    /// filtered view: two matches of a filter look adjacent on screen
    /// while a hundred commits sit between them, and squashing that
    /// "range" would rewrite all hundred.
    var contiguousSelection: [GitCommit]? {
        guard selectedCommitIDs.count >= 2 else { return nil }
        let source = searchResults == nil ? commits : filteredCommits
        let indices = source.enumerated()
            .filter { selectedCommitIDs.contains($0.element.id) }
            .map(\.offset)
        // Every selected commit must be present, and they must form an
        // unbroken run. Otherwise we bail rather than squash a partial
        // (and wrong) range.
        guard indices.count == selectedCommitIDs.count,
              let lo = indices.first, let hi = indices.last,
              hi - lo + 1 == indices.count else { return nil }
        return Array(source[lo...hi])
    }

    /// What the Journal's context menu can offer for the current
    /// multi-selection.
    enum SquashAvailability: Equatable {
        /// A run that `rebase -i` can fold, oldest last.
        case ready([GitCommit])
        /// Selected, but not squashable. The string is the menu row to draw
        /// disabled: a command that is simply not there sends people looking
        /// for a setting they have not found, which is how "there is no
        /// squash" gets reported for a feature that has one.
        case blocked(String)
        /// Nothing multi-selected, or the selection is about other rows —
        /// no Squash row at all.
        case unavailable
    }

    /// Whether the selection can be squashed, and if not, what to say.
    ///
    /// `rebase -i` can fold a run of commits when three things hold, and all
    /// three have to be checked here because git will otherwise do something
    /// plausible and wrong rather than fail: the run must be unbroken, it
    /// must be a straight parent chain with no merge in it, and it must be
    /// on HEAD — the branch the rebase rewrites. In the default HEAD-only
    /// graph the last is free; in a graph with other refs ticked, rows from
    /// those refs sit interleaved with HEAD's own and look just as adjacent.
    ///
    /// Published commits are *not* a blocker: `prepareSquash` detects them
    /// and the sheet warns before rewriting, with a force-push-with-lease
    /// offered afterwards.
    func squashAvailability(rightClicked commit: GitCommit) -> SquashAvailability {
        guard selectedCommitIDs.count >= 2 else { return .unavailable }
        let range = contiguousSelection
        // Only speak up on a row the menu is actually about: either one the
        // user selected, or one swallowed by the span between two of them.
        guard selectedCommitIDs.contains(commit.id)
                || range?.contains(where: { $0.id == commit.id }) == true
        else { return .unavailable }

        // Hits of a git-backed search come from all over history; two that
        // sit next to each other in the results are not next to each other
        // in the log, and a rewrite would leave the shown hashes stale.
        if searchResults != nil {
            return .blocked("Squash — not while search results are shown")
        }
        guard let range else {
            return .blocked("Squash — select an unbroken run of commits")
        }
        if range.contains(where: { $0.isMerge }) {
            return .blocked("Squash — a merge commit can't be folded in")
        }
        guard isStraightRun(range) else {
            return .blocked("Squash — the selection isn't one run of history")
        }
        guard let newest = range.first, isOnHeadHistory(newest.hash) else {
            return .blocked("Squash — these commits aren't on HEAD")
        }
        return .ready(range)
    }

    /// Whether each commit in `range` is the parent of the one before it.
    /// `range` runs newest first, so that is `child.parentHashes.first`.
    private func isStraightRun(_ range: [GitCommit]) -> Bool {
        zip(range, range.dropFirst()).allSatisfy { child, parent in
            child.parentHashes.first == parent.hash
        }
    }

    /// Whether `hash` is HEAD itself or one of its ancestors, as far as the
    /// loaded window can tell.
    ///
    /// Walked over the parent links already in hand rather than asked of git:
    /// this answers a context menu being built, and the commits it walks are
    /// the ones on screen.
    func isOnHeadHistory(_ hash: String) -> Bool {
        guard let head = commits.first(where: { $0.isHead }) else { return false }
        if head.hash == hash { return true }
        var byHash = [String: GitCommit](minimumCapacity: commits.count)
        for commit in commits { byHash[commit.hash] = commit }

        var seen: Set<String> = [head.hash]
        var pending = head.parentHashes
        while let next = pending.popLast() {
            if next == hash { return true }
            guard seen.insert(next).inserted, let commit = byHash[next] else { continue }
            pending.append(contentsOf: commit.parentHashes)
        }
        return false
    }

    /// Look up a commit by id across everything the journal knows about:
    /// search results first, then the loaded log. Panes that follow the
    /// selection must go through this — a search result is a commit from
    /// anywhere in history and is usually *not* in the loaded window, and
    /// a filter can hide a commit the Log window just selected.
    func commit(withID id: String) -> GitCommit? {
        if let found = searchResults?.commits.first(where: { $0.id == id }) { return found }
        // `indexByHash` indexes the search results while they're shown,
        // so it's only a valid index into `commits` when they aren't.
        if searchResults == nil,
           let idx = graph.indexByHash[id],
           commits.indices.contains(idx) {
            return commits[idx]
        }
        return commits.first { $0.id == id }
    }

    // MARK: - Commit graph

    /// The commits the graph is laid out over. Always the *whole* loaded
    /// log, never the filtered subset: a filter's matches are scattered
    /// through history, and laying out lanes over that subsequence opens
    /// a lane per missing parent — the lane count explodes and the graph
    /// column swallows the panel. Filtering hides rows (see
    /// `displayRows`); it must not change the topology underneath them.
    private var graphCommits: [GitCommit] { searchResults?.commits ?? commits }

    /// Lazily-computed graph layout plus a hash → row index for O(1) row
    /// lookup. Both are rebuilt only when the underlying commit list
    /// actually changes: `graphLayout` is read once per rendered row, so
    /// comparing whole hash arrays there (the old approach) got costly
    /// once the journal paged thousands of commits deep.
    private struct GraphCache {
        let fingerprint: String
        let layout: CommitGraphLayout
        let indexByHash: [String: Int]
    }
    private var graphCache: GraphCache?

    /// Cheap stand-in for comparing the commit list itself, for the one
    /// thing it decides: the lane topology. The loaded window only ever
    /// grows or is replaced wholesale, so a change in count or in either
    /// endpoint covers every edit that can move a lane. It says nothing
    /// about decoration — see `decorationFingerprint`.
    private var graphFingerprint: String {
        let source = graphCommits
        let mode = searchResults == nil ? "log" : "search"
        return "\(mode)|\(source.count)|\(source.first?.hash ?? "")|\(source.last?.hash ?? "")"
    }

    /// What `graphFingerprint` cannot see: the refs `%D` put on each
    /// commit. A push moves `origin/<branch>` from one loaded commit to
    /// another and changes nothing else — same count, same endpoints —
    /// so a row cache keyed on the graph fingerprint alone keeps handing
    /// back the rows it built before the push, `origin/<branch>` chip
    /// still drawn on the commit the remote used to be at. The rows carry
    /// whole commits, so a stale row is a stale decoration.
    ///
    /// Only decorated commits are hashed. `%D` is empty for all but a
    /// handful of rows, so this walks the window but hashes almost
    /// nothing — the per-rebuild cost the caches exist to avoid was
    /// comparing every hash, not visiting every commit.
    private var decorationFingerprint: Int {
        var hasher = Hasher()
        for commit in graphCommits where !commit.refs.isEmpty {
            hasher.combine(commit.hash)
            hasher.combine(commit.refs)
        }
        return hasher.finalize()
    }

    private var graph: GraphCache {
        let fingerprint = graphFingerprint
        if let cached = graphCache, cached.fingerprint == fingerprint { return cached }
        let source = graphCommits
        // Search results are commits from all over the history with no
        // parent links between them — a topology layout there is noise.
        let layout = searchResults == nil
            ? CommitGraphLayoutEngine.compute(commits: source)
            : CommitGraphLayout.flat(count: source.count)
        var indexByHash: [String: Int] = [:]
        indexByHash.reserveCapacity(source.count)
        for (idx, commit) in source.enumerated() { indexByHash[commit.hash] = idx }
        let cache = GraphCache(fingerprint: fingerprint, layout: layout, indexByHash: indexByHash)
        graphCache = cache
        return cache
    }

    var graphLayout: CommitGraphLayout { graph.layout }

    /// Per-commit lookup by hash; nil when the commit isn't in the
    /// current view.
    func graphRow(for commit: GitCommit) -> GraphRow? {
        let graph = self.graph
        guard let idx = graph.indexByHash[commit.hash],
              graph.layout.rows.indices.contains(idx) else { return nil }
        return graph.layout.rows[idx]
    }

    // MARK: - Display rows

    /// Runs of hidden commits the user clicked open. Keyed by the run's
    /// first hidden hash, so opening one gap doesn't disturb the others.
    private(set) var expandedRuns: Set<String> = []
    /// Query the expansions were made under — a different one drops them,
    /// so revealing a gap doesn't leak into the next search.
    private var expandedQuery: String = ""

    /// Cache mirroring `graphCache` — `displayRows` is read on every list
    /// rebuild and folding thousands of commits per keystroke is real work.
    private struct RowCache {
        let fingerprint: String
        let rows: [JournalDisplayRow]
    }
    private var rowCache: RowCache?

    /// The rows to render. Unfiltered that's one row per commit; while a
    /// local filter is active, each run of non-matching commits becomes a
    /// single collapsed row so the graph stays continuous and the refs
    /// inside the gap stay visible.
    var displayRows: [JournalDisplayRow] {
        let query = isFilteringLocally ? normalizedFilter.lowercased() : ""
        // Expansions belong to the query they were made under; a new one
        // starts from a fully collapsed view.
        let expanded = expandedQuery == query ? expandedRuns : []
        let open = expanded.sorted().joined(separator: ",")
        let fingerprint = "\(graphFingerprint)|\(decorationFingerprint)|\(query)|\(open)"
        if let cached = rowCache, cached.fingerprint == fingerprint { return cached.rows }

        let source = graphCommits
        let rows: [JournalDisplayRow]
        if query.isEmpty {
            rows = source.map { .commit($0) }
        } else {
            rows = JournalRowBuilder.rows(
                commits: source,
                matches: { Self.matches($0, query: query) },
                layout: graph.layout,
                expanded: expanded
            )
        }
        rowCache = RowCache(fingerprint: fingerprint, rows: rows)
        return rows
    }

    /// Reveal the commits a collapsed row stands for — SmartGit's
    /// "Reveal" on a skipped range. Expanding is one-way; changing the
    /// query starts over.
    func expandRun(_ run: CollapsedRun) {
        expandedQuery = isFilteringLocally ? normalizedFilter.lowercased() : ""
        expandedRuns.insert(run.id)
    }

    /// Color used to render `lane`. Cycles through a fixed palette so the
    /// graph stays visually stable across rebuilds.
    nonisolated static func laneColor(_ lane: Int) -> LaneColor {
        let palette: [LaneColor] = [
            .blue, .green, .orange, .purple, .pink, .teal, .yellow, .indigo
        ]
        return palette[abs(lane) % palette.count]
    }

    /// Internal so tests can exercise the matching logic without an
    /// observable instance. `nonisolated` because the body is pure —
    /// keeping it off the main actor lets sync test contexts call it.
    nonisolated static func filter(_ commits: [GitCommit], query: String) -> [GitCommit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return commits }
        return commits.filter { matches($0, query: q) }
    }

    /// Does `commit` match `query`? `query` must already be trimmed and
    /// lowercased — this runs once per loaded commit per keystroke.
    ///
    /// The fields mirror SmartGit's default match set: message, author
    /// (name + email), refs and id.
    nonisolated static func matches(_ commit: GitCommit, query q: String) -> Bool {
        commit.subject.lowercased().contains(q)
            || commit.authorName.lowercased().contains(q)
            || commit.authorEmail.lowercased().contains(q)
            || commit.refs.lowercased().contains(q)
            || commit.shortHash.lowercased().contains(q)
            || commit.hash.lowercased().hasPrefix(q)
    }
}

/// SwiftUI-agnostic color enum used by both the layout consumer (view)
/// and tests. Mapped to a `Color` in the view layer.
enum LaneColor: Sendable {
    case blue, green, orange, purple, pink, teal, yellow, indigo
}

/// The journal filter field's scope. `.local` is the classic live filter
/// over loaded commits; the rest map to `GitService.LogSearchMode` and
/// search the whole history via git.
enum JournalSearchScope: String, CaseIterable, Identifiable, Sendable {
    case local
    case message
    case author
    case content
    case contentRegex

    var id: String { rawValue }

    /// Menu label. Kept short — it renders inside the panel header.
    var label: String {
        switch self {
        case .local:        return "Filter (loaded)"
        case .message:      return "Message"
        case .author:       return "Author"
        case .content:      return "Content (-S)"
        case .contentRegex: return "Content regex (-G)"
        }
    }

    var gitMode: GitService.LogSearchMode? {
        switch self {
        case .local:        return nil
        case .message:      return .message
        case .author:       return .author
        case .content:      return .content
        case .contentRegex: return .contentRegex
        }
    }
}

/// One completed git-backed search: what was asked and what came back.
/// `failed` marks a git error (bad regex, …) so the banner can say so
/// instead of showing a misleading "0 results".
struct JournalSearchResults: Sendable {
    let query: String
    let scope: JournalSearchScope
    let commits: [GitCommit]
    let failed: Bool
    /// The failure was git running out of time, not a bad query. Worth
    /// separating: "check the query" is unhelpful advice for a pickaxe
    /// that simply had more history to walk than its budget allowed.
    var timedOut: Bool = false
}
