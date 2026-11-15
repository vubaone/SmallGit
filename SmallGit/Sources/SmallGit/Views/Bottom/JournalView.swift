import SwiftUI
import AppKit

struct JournalView: View {
    @Bindable var appState: AppState
    @Bindable var viewModel: JournalViewModel
    @Environment(\.openWindow) private var openWindow

    /// Message and author search run as you type; the content scopes
    /// cost a full diff walk, so their prompt still says ⏎.
    private var placeholder: String {
        switch viewModel.searchScope {
        case .local:
            return "Filter commits"
        case .message, .author:
            return "Search \(viewModel.searchScope.label.lowercased())"
        case .content, .contentRegex:
            return "Search \(viewModel.searchScope.label.lowercased()) — ⏎"
        }
    }

    /// Whether the working-tree row is on screen. A search replaces the
    /// list with results from anywhere in history, and uncommitted work is
    /// not one of them.
    private var showsWorkingTreeRow: Bool {
        appState.changedFileCount > 0 && viewModel.searchResults == nil
    }

    private var graphColumnWidth: CGFloat {
        CommitGraphCell.columnWidth(lanes: viewModel.graphLayout.maxLanes)
    }

    private static let authorColumnWidth: CGFloat = 28
    private static let dateColumnWidth:   CGFloat = 110

    /// Routes a single click to the right selection action based on the
    /// modifier held at click time: cmd toggles the commit in/out, shift
    /// extends a range from the anchor, plain click collapses to one.
    /// Mirrors the line-selection gesture in DiffView.
    /// Set when the selection moved because the user clicked a row.
    ///
    /// A clicked row is under the pointer, so it is on screen by
    /// definition: scrolling it to the middle only moves the list out from
    /// under the click. Programmatic selections — the Log window picking a
    /// parent, a context-menu action — still scroll, because there the row
    /// may be anywhere, including a page away.
    @State private var selectionCameFromClick = false

    private func select(_ commit: GitCommit) {
        // Only when the click will actually move the selection. Clicking the
        // selected row again fires no change, and the flag would then sit
        // set until some later programmatic selection swallowed its scroll.
        selectionCameFromClick = viewModel.selectedCommitID != commit.id
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            viewModel.toggleSelection(commit)
        } else if flags.contains(.shift) {
            viewModel.extendSelection(to: commit)
        } else {
            viewModel.selectOnly(commit)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Journal") {
                BottomPanelsDisclosure(collapsed: false) {
                    appState.setBottomPanelsCollapsed(true)
                }
            } trailing: {
                HStack(spacing: 8) {
                    if appState.canUseActiveRepo {
                        if let results = viewModel.searchResults {
                            Text("\(results.commits.count) results")
                                .scaledFont(10)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        } else if viewModel.isFilteringLocally {
                            // Matches, not hidden-count: the skipped
                            // commits now say so on their own rows, and
                            // "3,156 hidden" tells the user nothing about
                            // what they were looking for.
                            Text("\(viewModel.filteredCommits.count) matches")
                                .scaledFont(10)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        } else {
                            Text("\(viewModel.commits.count) commits")
                                .scaledFont(10)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        // Scope picker: "Filter (loaded)" keeps the classic
                        // live filter; the other scopes search the *whole*
                        // history via git when the user presses ⏎.
                        Menu {
                            Picker("Search scope", selection: $viewModel.searchScope) {
                                ForEach(JournalSearchScope.allCases) { scope in
                                    Text(scope.label).tag(scope)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            Image(systemName: viewModel.searchScope == .local
                                ? "line.3.horizontal.decrease.circle"
                                : "magnifyingglass.circle.fill")
                                .scaledFont(12)
                                .foregroundStyle(viewModel.searchScope == .local
                                    ? Color.textSecondary : Color.accentColor)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Search scope: \(viewModel.searchScope.label)")

                        if viewModel.isSearching {
                            ProgressView().controlSize(.mini)
                            Button {
                                viewModel.cancelSearch()
                            } label: {
                                Image(systemName: "stop.circle.fill")
                                    .scaledFont(12)
                                    .foregroundStyle(Color.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("Stop the running search")
                        }

                        TextField(
                            placeholder,
                            text: $viewModel.filterText
                        )
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 90, idealWidth: 160, maxWidth: 200)
                            .scaledFont(11)
                            .onSubmit {
                                viewModel.startSearch()
                            }
                    }
                }
            }

            if appState.activeRepo == nil {
                EmptyPanelState(
                    icon: "clock.arrow.circlepath",
                    title: "No repository open",
                    message: "Open a repository to browse its commit history."
                )
            } else if let issue = appState.activeRepositoryIssue,
                      let repo = appState.activeRepo {
                EmptyPanelState(
                    icon: issue.emptyStateIcon,
                    title: issue.emptyStateTitle,
                    message: issue.emptyStateMessage(path: repo.path)
                )
            } else {
                journalContent
            }
        }
        .background(Color.bgPanel)
    }

    /// Pulled out so `body` can switch cleanly between the empty
    /// state and the live commit list. Renders the branch banner
    /// and the scrollable commit list. The column header row was
    /// dropped to match SmartGit — at the panel's typical width the
    /// "Graph" label wrapped onto two lines and looked broken, and
    /// the columns are self-evident (graph dot on the left, author
    /// initials + relative date on the right).
    @ViewBuilder
    private var journalContent: some View {
        if let divergence = viewModel.upstreamDivergence {
            UpstreamDivergenceBanner(divergence: divergence)
        }
        if !viewModel.refSelection.isHeadOnly {
            RefSelectionBanner(appState: appState, viewModel: viewModel)
        }
        if let results = viewModel.searchResults {
            SearchResultsBanner(results: results, viewModel: viewModel)
        }
        // A content query hasn't run yet — say so, because the rows
        // underneath are the whole log and look like the filter failed.
        if viewModel.hasPendingSearch, !viewModel.searchRunsAsYouType {
            PendingSearchBanner(viewModel: viewModel)
        }

        // ScrollView + LazyVStack gives pixel-perfect control over
        // row-to-row spacing — both List and Table on macOS inject a
        // few points of implicit row gap that no public modifier
        // removes, which made the graph's vertical strokes look
        // broken between rows. LazyVStack(spacing: 0) is the only
        // container that guarantees the next row's top edge is
        // exactly the previous row's bottom edge.
        ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Uncommitted work, above the history it is not part
                        // of yet. Shown in every repository — a log that
                        // looks the same clean or dirty is a log that lets
                        // someone forget they have not committed.
                        if showsWorkingTreeRow {
                            WorkingTreeRow(
                                fileCount: appState.changedFileCount,
                                selected: viewModel.workingTreeSelected,
                                totalLanes: viewModel.graphLayout.maxLanes,
                                graphColumnWidth: graphColumnWidth
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.selectWorkingTree() }
                        }
                        let rows = viewModel.displayRows
                        // Trigger another page once the user gets within
                        // a screenful of the bottom. A filter narrows the
                        // *loaded* commits, so hitting the end of a
                        // filtered list is exactly when more history is
                        // worth fetching — `loadMoreIfNeeded` keeps
                        // paging there until another match shows up.
                        let prefetchIndex = max(0, rows.count - 20)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                            Group {
                                switch row {
                                case .commit(let commit):
                                    // Only the topmost row carries the other
                                    // half of the connector — it is the one
                                    // the uncommitted work sits on.
                                    commitRow(commit, dashedIncoming: idx == 0 && showsWorkingTreeRow)
                                case .collapsed(let run):
                                    // Clicking a skipped range reveals the
                                    // commits inside it — SmartGit's
                                    // "Reveal" on a collapsed row.
                                    CollapsedRunRow(
                                        run: run,
                                        totalLanes: viewModel.graphLayout.maxLanes,
                                        graphColumnWidth: graphColumnWidth
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture { viewModel.expandRun(run) }
                                }
                            }
                            .id(row.id)
                            .onAppear {
                                guard viewModel.searchResults == nil,
                                      idx >= prefetchIndex else { return }
                                Task { await viewModel.loadMoreIfNeeded() }
                            }
                        }
                        if viewModel.searchResults == nil {
                            JournalFooter(viewModel: viewModel)
                        }
                    }
                }
                // Everything the filter field triggers, once the typing
                // settles: page deeper behind a local filter so a match
                // count of three doesn't read as "three in the whole
                // repo", and run the message / author search as you type.
                // Debounced because each of those is a real `git log` —
                // `.task(id:)` cancels the pending one on every change,
                // so only the settled query costs a process.
                .task(id: viewModel.searchRequestKey) {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    await viewModel.applyFilterInput()
                }
                .onChange(of: viewModel.selectedCommitID) { _, new in
                    let cameFromClick = selectionCameFromClick
                    selectionCameFromClick = false
                    // Resolve against everything loaded, not just the
                    // rows on screen: a filter can hide the commit the
                    // Log window just selected, and its diff should still
                    // load. `scrollTo` simply no-ops when the row isn't
                    // rendered.
                    guard let id = new, let commit = viewModel.commit(withID: id) else {
                        return
                    }
                    if !cameFromClick {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(commit.id, anchor: .center)
                        }
                    }
                    Task { await appState.showCommitDiff(commit) }
                }
            }
    }

    /// One commit row plus its gestures. Extracted from the list body so
    /// the `ForEach` can switch between commit and collapsed rows.
    @ViewBuilder
    private func commitRow(_ commit: GitCommit, dashedIncoming: Bool = false) -> some View {
        JournalRow(
            commit: commit,
            viewModel: viewModel,
            appState: appState,
            dashedIncoming: dashedIncoming,
            graphColumnWidth: graphColumnWidth,
            authorColumnWidth: Self.authorColumnWidth,
            dateColumnWidth: Self.dateColumnWidth,
            selected: viewModel.isSelected(commit)
        )
        .contentShape(Rectangle())
        // Single tap selects *immediately*. Double tap opens the Log
        // window. These are declared as a plain tap + a
        // `simultaneousGesture` rather than two `onTapGesture(count:)`
        // calls on purpose: when a single- and double-tap recognizer
        // share a view, SwiftUI holds the single tap until the system
        // double-click interval elapses (up to ~1s) to disambiguate,
        // which made selection feel laggy. As simultaneous gestures the
        // single fires on the first click; a second click additionally
        // opens.
        .onTapGesture {
            select(commit)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                selectionCameFromClick = viewModel.selectedCommitID != commit.id
                viewModel.selectOnly(commit)
                openWindow(id: "log")
            }
        )
        .contextMenu {
            JournalContextMenu(commit: commit, appState: appState)
        }
    }
}

// MARK: - Row

/// Metrics every row in the Journal list is built from — commit rows,
/// collapsed-run rows and the working-tree row alike.
///
/// Shared rather than repeated because the failure mode is invisible until
/// it is on screen: a row inset four points differently, or missing the
/// marker column every commit row reserves, is not obviously wrong in the
/// code and unmistakably wrong in the graph.
enum JournalRowLayout {
    /// Outer inset of a row.
    static let horizontalPadding: CGFloat = 10
    /// Gap between the graph column and the content beside it.
    static let columnSpacing: CGFloat = 8
    /// Gap between the pieces of a row's content.
    static let contentSpacing: CGFloat = 6
    /// Width of the "not pushed" marker. Every commit row reserves it
    /// whether or not it shows one, so anything else in this list has to
    /// reserve it too or its text starts a marker's width to the left.
    static let markerWidth: CGFloat = 3
}

/// One row of the Journal. Pinned to `CommitGraphCell.rowHeight` so
/// the graph's vertical strokes meet at row boundaries exactly. The
/// selection background is applied here rather than relying on a
/// container's selection styling so it can paint the full row width
/// without any inter-row gap.
private struct JournalRow: View {
    let commit: GitCommit
    @Bindable var viewModel: JournalViewModel
    @Bindable var appState: AppState
    /// True for the row directly under the working-tree node.
    var dashedIncoming: Bool = false
    let graphColumnWidth: CGFloat
    let authorColumnWidth: CGFloat
    let dateColumnWidth: CGFloat
    let selected: Bool

    var body: some View {
        HStack(spacing: JournalRowLayout.columnSpacing) {
            Group {
                if let row = viewModel.graphRow(for: commit) {
                    CommitGraphCell(
                        row: row,
                        totalLanes: viewModel.graphLayout.maxLanes,
                        dotOverride: syncState.dotColor,
                        dashedIncoming: dashedIncoming
                    )
                } else {
                    Color.clear
                }
            }
            .frame(width: graphColumnWidth, alignment: .leading)

            HStack(spacing: JournalRowLayout.contentSpacing) {
                SyncMarker(state: syncState)
                ForEach(RefParser.parse(commit.refs)) { label in
                    RefBadge(label: label)
                }
                Text(commit.subject)
                    .scaledFont(12)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AuthorBadge(commit: commit) {
                if viewModel.filterText == commit.authorName {
                    viewModel.filterText = ""
                } else {
                    viewModel.filterText = commit.authorName
                }
            }
            .frame(width: authorColumnWidth, alignment: .center)

            Text(DateFormatters.relative(from: commit.date))
                .scaledFont(10)
                .foregroundStyle(Color.textSecondary)
                .help(DateFormatters.absolute.string(from: commit.date))
                .frame(width: dateColumnWidth, alignment: .leading)
        }
        .padding(.horizontal, JournalRowLayout.horizontalPadding)
        .frame(height: CommitGraphCell.rowHeight)
        .background(selected ? Color.bgSelected : Color.clear)
    }

    private var syncState: CommitSyncState {
        if viewModel.isUnpushed(commit) { return .outgoing }
        if viewModel.isIncoming(commit) { return .incoming }
        return .inSync
    }
}

/// One run of filtered-out commits. Keeps the graph continuous where
/// the matches don't touch, and surfaces the refs buried in the gap so
/// a branch tip between two matches is still findable. Clicking it
/// reveals the commits it stands for.
private struct CollapsedRunRow: View {
    let run: CollapsedRun
    let totalLanes: Int
    let graphColumnWidth: CGFloat

    /// Ref chips get crowded fast — a merge-heavy gap can hold dozens.
    /// Show a couple and count the rest, the way SmartGit does.
    private static let visibleRefs = 2

    var body: some View {
        HStack(spacing: JournalRowLayout.columnSpacing) {
            CommitGraphGapCell(gap: run.gap, totalLanes: totalLanes)
                .frame(width: graphColumnWidth, alignment: .leading)

            HStack(spacing: JournalRowLayout.contentSpacing) {
                Text("\(run.count) hidden")
                    .scaledFont(10)
                    .foregroundStyle(Color.textDisabled)
                ForEach(run.refs.prefix(Self.visibleRefs)) { label in
                    RefBadge(label: label)
                        .opacity(0.65)
                }
                if run.refs.count > Self.visibleRefs {
                    Text("+\(run.refs.count - Self.visibleRefs) refs")
                        .scaledFont(10)
                        .foregroundStyle(Color.textDisabled)
                }
                Rectangle()
                    .fill(Color.textDisabled.opacity(0.25))
                    .frame(height: 1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, JournalRowLayout.horizontalPadding)
        .frame(height: CommitGraphCell.rowHeight)
        .help("\(run.count) commit\(run.count == 1 ? "" : "s") don't match the filter — click to reveal")
    }
}

// MARK: - Ref selection banner

/// Shown whenever the journal is graphing something other than plain
/// HEAD — one branch pinned via the branch context menu's "Log", or a
/// wider set ticked in the Branches panel. Without it the graph silently
/// stops being "your current branch" and there's nothing on screen to
/// say what it became, or how to get back.
private struct RefSelectionBanner: View {
    @Bindable var appState: AppState
    @Bindable var viewModel: JournalViewModel

    private var selection: JournalRefSelection { viewModel.refSelection }

    private var icon: String {
        selection.isEmpty ? "eye.slash" : "arrow.triangle.branch"
    }

    private var tint: Color {
        selection.isEmpty ? .orange : .accentColor
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .scaledFont(10)
                .foregroundStyle(tint)
            if selection.isEmpty {
                Text("No refs selected — tick a branch in the Branches panel")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            } else if let branch = viewModel.branchFilter {
                Text("Showing log of")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                Text(branch)
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Graphing")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                Text(summary)
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(selection.revisions.joined(separator: "\n"))
            }
            Spacer()
            Button {
                Task { await appState.showJournalHeadOnly() }
            } label: {
                Label("HEAD Only", systemImage: "xmark.circle.fill")
                    .scaledFont(10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textSecondary)
            .help("Go back to graphing the checked-out branch")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(tint.opacity(0.30)).frame(height: 0.5)
        }
    }

    /// "HEAD + 3 refs" / "4 refs" — the count matters more than the
    /// names, which are on the tooltip and in the panel that set them.
    private var summary: String {
        let count = selection.refs.count
        let refs = "\(count) ref\(count == 1 ? "" : "s")"
        return selection.head ? "HEAD + \(refs)" : refs
    }
}

/// Shown while a git-backed scope holds a query that hasn't run. Without
/// it the journal silently displays the unfiltered log: the field's
/// "— ⏎" hint is hidden the moment there's text in it, and every row
/// still shows every author.
private struct PendingSearchBanner: View {
    @Bindable var viewModel: JournalViewModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "return")
                .scaledFont(10)
                .foregroundStyle(Color.orange)
            Text("Press ⏎ to search \(viewModel.searchScope.label.lowercased()) — the list below is unfiltered")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
            Spacer()
            Button {
                viewModel.startSearch()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
                    .scaledFont(10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.orange.opacity(0.30)).frame(height: 0.5)
        }
    }
}

// MARK: - Search results banner

/// Shown above the commit list while a git-backed search's results are
/// displayed. States the query + scope and the hit count (or the failure,
/// e.g. a bad regex), with a close button returning to the loaded log.
private struct SearchResultsBanner: View {
    let results: JournalSearchResults
    @Bindable var viewModel: JournalViewModel

    private var summary: String {
        if results.timedOut {
            return "Search timed out — narrow it down or try another scope"
        }
        if results.failed {
            return "Search failed — check the query"
        }
        let n = results.commits.count
        return "\(n) result\(n == 1 ? "" : "s") for"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .scaledFont(10)
                .foregroundStyle(results.failed ? Color.red : Color.accentColor)
            Text(summary)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
            if !results.failed {
                Text("“\(results.query)”")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text("in \(results.scope.label)")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            Button {
                viewModel.clearSearch()
            } label: {
                Label("Clear", systemImage: "xmark.circle.fill")
                    .scaledFont(10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textSecondary)
            .help("Return to the loaded log")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background((results.failed ? Color.red : Color.accentColor).opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill((results.failed ? Color.red : Color.accentColor).opacity(0.30))
                .frame(height: 0.5)
        }
    }
}

// MARK: - Pagination footer

/// Shown at the bottom of the journal: a spinner while a page is in
/// flight, or "End of history" once we've fetched everything. Gives
/// the user explicit feedback that no further commits exist instead
/// of leaving them wondering why scrolling stopped working.
private struct JournalFooter: View {
    @Bindable var viewModel: JournalViewModel

    var body: some View {
        HStack(spacing: 6) {
            if viewModel.isLoadingMore {
                ProgressView().controlSize(.small)
                Text("Loading more…")
                    .scaledFont(10)
                    .foregroundStyle(Color.textSecondary)
            } else if viewModel.loadMoreFailed {
                // Automatic paging stopped after three failed fetches.
                // Say so and let the user ask again rather than looking
                // like the history simply ends here.
                Text("Couldn't load more commits")
                    .scaledFont(10)
                    .foregroundStyle(Color.textSecondary)
                Button("Retry") {
                    Task { await viewModel.loadMoreManually() }
                }
                .buttonStyle(.link)
                .scaledFont(10)
            } else if !viewModel.hasMore && !viewModel.commits.isEmpty {
                Text("End of history")
                    .scaledFont(10)
                    .foregroundStyle(Color.textDisabled)
            } else if viewModel.isFilteringLocally && viewModel.hasMore {
                // A filtered view can run out of matches long before it
                // runs out of history, and the automatic top-up stops at
                // a bounded depth — this is how the user goes deeper.
                Button("Load more history") {
                    Task { await viewModel.loadMoreManually() }
                }
                .buttonStyle(.link)
                .scaledFont(10)
                Text("\(viewModel.commits.count) searched")
                    .scaledFont(10)
                    .foregroundStyle(Color.textDisabled)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
    }
}

// MARK: - Decorations

/// Orange vertical bar shown to the left of unpushed commits.
private enum CommitSyncState {
    /// On HEAD, not on the upstream — waiting for a push.
    case outgoing
    /// On the upstream, not on HEAD — waiting for a pull, or about to be
    /// replaced by a force push after a squash or a rebase.
    case incoming
    case inSync

    var color: Color? {
        switch self {
        case .outgoing: return .orange
        case .incoming: return .cyan
        case .inSync:   return nil
        }
    }

    /// The graph dot follows the marker, so a fork reads as two coloured
    /// lanes from across the panel rather than as two identical ones.
    var dotColor: Color? { color }

    var help: String {
        switch self {
        case .outgoing: return "Not yet pushed"
        case .incoming: return "On the remote, not on this branch"
        case .inSync:   return ""
        }
    }
}

private struct SyncMarker: View {
    let state: CommitSyncState
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(state.color ?? .clear)
            .frame(width: JournalRowLayout.markerWidth, height: 14)
            .help(state.help)
    }
}

/// Says that the branch and its upstream have forked, which is what the
/// second lane in the graph below is.
///
/// Worth its own line: after a squash or a rebase the rewritten commit is
/// the one the user is looking for and it is right there at the top, so the
/// old commits still sitting on the remote are easy to miss — and they are
/// the reason the next push needs a force.
private struct UpstreamDivergenceBanner: View {
    let divergence: (ref: String, ahead: Int, behind: Int)

    private var tint: Color { divergence.ahead > 0 ? .orange : .cyan }

    private var summary: String {
        // Behind only: the ref is already named beside this, so the count
        // says what it is a count *of* instead of repeating it.
        guard divergence.ahead > 0 else {
            let n = divergence.behind
            return "\(n) commit\(n == 1 ? "" : "s") not in this branch"
        }
        return "\(divergence.ahead) here, \(divergence.behind) on \(divergence.ref)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: divergence.ahead > 0
                  ? "arrow.triangle.branch"
                  : "arrow.down.circle")
                .scaledFont(10)
                .foregroundStyle(tint)
            Text(divergence.ahead > 0 ? "Diverged from" : "Behind")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
            Text(divergence.ref)
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\u{00B7} \(summary)")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(tint.opacity(0.30)).frame(height: 0.5)
        }
        .help("The remote branch is graphed below alongside this one, so both tips are visible.")
    }
}

/// The working tree as a row in the log: what is not committed yet.
///
/// Drawn like a commit row with an open circle where a commit's filled dot
/// goes — the shape says "this is where the next commit will be", which is
/// what uncommitted work is.
private struct WorkingTreeRow: View {
    let fileCount: Int
    let selected: Bool
    let totalLanes: Int
    let graphColumnWidth: CGFloat

    var body: some View {
        // Column for column with `JournalRow`: same outer spacing, same
        // graph column width and alignment, same row height. A row that is
        // nearly aligned reads as a bug in the graph.
        HStack(spacing: JournalRowLayout.columnSpacing) {
            WorkingTreeGraphCell(totalLanes: totalLanes)
                .frame(width: graphColumnWidth, alignment: .leading)

            HStack(spacing: JournalRowLayout.contentSpacing) {
                // The marker column every commit row reserves, reserved here
                // too and empty: without it this row's text starts three
                // points left of every subject under it.
                SyncMarker(state: .inSync)
                Text("Uncommitted changes")
                    .scaledFont(12, weight: .medium)
                    .foregroundStyle(selected ? Color.white : Color.textPrimary)
                Text("\(fileCount) file\(fileCount == 1 ? "" : "s")")
                    .scaledFont(10)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.textSecondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, JournalRowLayout.horizontalPadding)
        .frame(height: CommitGraphCell.rowHeight)
        .background(selected ? Color.bgSelected : Color.clear)
    }
}

private struct AuthorBadge: View {
    let commit: GitCommit
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            Text(commit.authorTag)
                .scaledFont(9, weight: .bold)
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 3).fill(commit.authorColor))
        }
        .buttonStyle(.plain)
        .help("Filter journal by \(commit.authorName)")
    }
}

private extension GitCommit {
    var authorTag: String {
        let trimmed = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(1)).uppercased()
    }

    var authorColor: Color {
        let hash = authorEmail.isEmpty ? authorName : authorEmail
        let sum = hash.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Color.authorBadgePalette[abs(sum) % Color.authorBadgePalette.count]
    }
}

// MARK: - Author badge palette

/// Nine fills for the initials badge, keyed off a hash of the author's
/// email so the same person keeps the same colour.
///
/// All nine are mid-dark in *both* themes, because the badge draws its
/// initials in white and nothing else. SwiftUI's stock `.yellow` and `.mint`
/// — which this used to pick from — are near-white in light appearance, and
/// white-on-yellow at 9pt bold was unreadable the moment the app could be
/// light.
extension Palette {
    static let authorBadge = [
        themed("authorPurple", light: 0x7E4BC4, dark: 0x8B5CD6),
        themed("authorOrange", light: 0xB55E0A, dark: 0xB0600F),
        themed("authorBlue",   light: 0x1668C7, dark: 0x2A7FD6),
        themed("authorRed",    light: 0xB93A2C, dark: 0xD1483A),
        themed("authorTeal",   light: 0x0E7373, dark: 0x14807F),
        themed("authorOlive",  light: 0x8A6D00, dark: 0x907516),
        themed("authorPink",   light: 0xB93670, dark: 0xD14C87),
        themed("authorIndigo", light: 0x4A4AC4, dark: 0x5C5CD6),
        themed("authorMint",   light: 0x1A8459, dark: 0x1D8E63)
    ]
}

extension Color {
    static let authorBadgePalette = Palette.authorBadge.map(Color.init(nsColor:))
}
