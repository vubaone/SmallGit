import SwiftUI
import AppKit

/// Standalone Log window — opens via ⌘L or the Journal context-menu
/// "Log" item. Same data as the inline Journal panel in MainWindow,
/// but reorganised to be the focus, with a per-commit Files list and
/// a commit-detail side panel.
///
/// Layout (matching SmartGit's Log window):
///
///   ┌────────────┬────────────┬───────────┐
///   │  Journal   │   Files    │  Commit   │
///   │  (graph +  │  changed   │  details  │
///   │   table)   │  in commit │  (body +  │
///   │            │            │   parents)│
///   ├────────────┴────────────┴───────────┤
///   │  Diff of selected commit            │
///   └─────────────────────────────────────┘
///
/// Single-instance window (`Window(_:id:)`) — ⌘L brings the existing
/// window to the front rather than spawning duplicates.
struct LogWindow: View {
    @Bindable var appState: AppState

    var body: some View {
        VSplitView {
            HSplitView {
                JournalView(appState: appState, viewModel: appState.journalVM)
                    .frame(minWidth: 380)
                CommitFilesPane(appState: appState)
                    .frame(minWidth: 200, idealWidth: 260)
                CommitDetailPane(appState: appState)
                    .frame(minWidth: 240, idealWidth: 320)
            }
            .frame(minHeight: 240)

            DiffView(appState: appState, viewModel: appState.diffVM, showsTerminalSwitch: false)
                .frame(minHeight: 220)
        }
        .toolbar { ToolbarView(appState: appState) }
        .background(
            ToolbarDisplayApplier(showLabels: appState.appConfig.toolbarShowsLabels)
        )
        // Built-in fallback for a per-file double-click when no external
        // diff tool is configured (see CommitFilesPane.openInDiffTool).
        // Presented as an AppKit modal window so it blocks the Log window
        // like a sheet but remains freely resizable.
        .background(CommitCompareWindowOpener(appState: appState))
        .sheet(item: $appState.blameTarget) { target in
            BlameView(appState: appState, path: target.path)
        }
        .frame(minWidth: 1100, minHeight: 660)
        .navigationTitle("\(appState.activeRepo?.name ?? "SmallGit") — Log")
        .preferredColorScheme(appState.appConfig.appearance.colorScheme)
        // Same zoom env the MainWindow injects so ⌘+/- works here too.
        .environment(\.monoFontSize, appState.appConfig.monoFontSize)
        .environment(\.uiScale, appState.appConfig.monoFontSize / 12)
        .environment(\.showWhitespace, appState.appConfig.showWhitespace)
    }
}

private struct CommitCompareWindowOpener: View {
    @Bindable var appState: AppState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: appState.commitCompareTarget) { _, new in
                guard let new else { return }
                // Cleared immediately — it's a request to open a window, not a
                // record of the one that's open. See `CompareWindowOpener`.
                appState.commitCompareTarget = nil
                CompareWindowPresenter.presentCommitCompares(
                    appState: appState, commit: new.commit, paths: new.paths
                )
            }
    }
}

// MARK: - Commit Files pane (middle column)

/// Lists the files touched by the currently-selected commit — the
/// middle column SmartGit shows between the journal and the commit
/// detail. Selecting rows narrows the Diff panel to just those files
/// within the commit; ⌘/⇧-click picks several to compare at once.
private struct CommitFilesPane: View {
    @Bindable var appState: AppState
    @State private var files: [GitFileStatus] = []
    @State private var loadingHash: String?
    /// The working-tree table's row. It previews one file at a time, the
    /// way the main window's Files panel does.
    @State private var selectedPath: String?
    /// The commit table's rows — several at once, so they can be read
    /// together in the Diff panel and opened as one tab group.
    @State private var selectedCommitPaths: Set<String> = []
    /// Clicking a column header sorts by it; clicking again reverses.
    /// Empty until the first click, which leaves the rows in git's own
    /// order — the order the diff was reported in.
    ///
    /// One per table: the two show different words in their State column
    /// (a commit's files are all staged, so only the short code tells them
    /// apart) and so sort by different keys.
    @State private var commitSort: [FileSortComparator] = []
    @State private var workingTreeSort: [FileSortComparator] = []

    private var commit: GitCommit? {
        guard let id = appState.journalVM.selectedCommitID else { return nil }
        // Through the view model, not `commits`: a search result is a
        // commit from anywhere in history and is usually not in the
        // loaded window, which left this pane empty for a selected row.
        return appState.journalVM.commit(withID: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Files") {
                if !files.isEmpty {
                    Text("\(files.count)")
                        .scaledFont(10)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            if appState.journalVM.workingTreeSelected {
                workingTreeFiles
            } else if commit == nil {
                emptyState("Select a commit")
            } else if files.isEmpty, loadingHash != nil {
                emptyState("Loading…")
            } else if files.isEmpty {
                emptyState("(no files)")
            } else {
                let rows = sortedCommitFiles
                Table(of: GitFileStatus.self, selection: $selectedCommitPaths, sortOrder: $commitSort) {
                    TableColumn("Name", sortUsing: FileSortComparator(field: .name)) { file in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(file.state.swatch)
                                .frame(width: 8, height: 8)
                            Text(file.name)
                                .scaledFont(12)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .help(file.path)
                    }
                    TableColumn("State", sortUsing: FileSortComparator(field: .stateCode)) { file in
                        Text(file.state.rawValue)
                            .scaledFont(10)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .width(44)
                } rows: {
                    ForEach(rows) { file in
                        TableRow(file)
                            .contextMenu {
                                fileContextMenu(file, rows: rows)
                            }
                    }
                }
                .background {
                    // The double-click arrives as a row *index*, so it has to
                    // be read against the rows on screen — sorted — and not
                    // the order git listed them in.
                    TableDoubleClickBridge { rowIndex in
                        guard rowIndex >= 0, rowIndex < rows.count else { return }
                        openInDiffTool(files: [rows[rowIndex]])
                    }
                }
            }
        }
        .background(Color.bgPanel)
        .task(id: commit?.hash) { await reload() }
        // Narrow the bottom Diff panel to just the files the user picked
        // in this list. Clearing the selection (e.g. when reload() resets
        // it after a commit switch) restores the full commit diff,
        // matching the JournalView click path.
        .onChange(of: selectedCommitPaths) { _, newPaths in
            // The working-tree table drives its own diff; this one is for a
            // selected commit's files.
            guard !appState.journalVM.workingTreeSelected, let commit else { return }
            // In the order the table shows them, so the diff reads top to
            // bottom like the list does.
            let paths = sortedCommitFiles.map(\.path).filter(newPaths.contains)
            Task { await appState.diffVM.loadCommitDiff(commit, paths: paths) }
        }
        // Switching between the working tree and a commit invalidates the
        // row selection either way: the two lists hold different paths.
        .onChange(of: appState.journalVM.workingTreeSelected) { _, _ in
            selectedPath = nil
            selectedCommitPaths = []
        }
    }

    /// The uncommitted files, from the same status the Files panel shows.
    /// Selecting one puts its working-tree diff in the Changes pane below —
    /// the same diff the main window would show, in the window the user is
    /// already looking at.
    @ViewBuilder
    private var workingTreeFiles: some View {
        let rows = sorted(appState.filesVM.files, using: workingTreeSort)
        if rows.isEmpty {
            emptyState("Nothing uncommitted")
        } else {
            Table(of: GitFileStatus.self, selection: $selectedPath, sortOrder: $workingTreeSort) {
                TableColumn("Name", sortUsing: FileSortComparator(field: .name)) { file in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(file.state.swatch)
                            .frame(width: 8, height: 8)
                        Text(file.name)
                            .scaledFont(12)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .help(file.path)
                }
                TableColumn("State", sortUsing: FileSortComparator(field: .state)) { file in
                    Text(file.stateDisplay)
                        .scaledFont(10)
                        .foregroundStyle(Color.textSecondary)
                }
                .width(80)
            } rows: {
                ForEach(rows) { file in
                    TableRow(file)
                }
            }
            .onChange(of: selectedPath) { _, path in
                guard let path, let file = rows.first(where: { $0.path == path }) else { return }
                Task { await appState.selectFile(file) }
            }
        }
    }

    private var sortedCommitFiles: [GitFileStatus] {
        sorted(files, using: commitSort)
    }

    /// An empty comparator list means "however they arrived" — `sort(using:)`
    /// on one is not guaranteed to leave the rows where they were.
    private func sorted(
        _ rows: [GitFileStatus],
        using comparators: [FileSortComparator]
    ) -> [GitFileStatus] {
        comparators.isEmpty ? rows : rows.sorted(using: comparators)
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.plaintext")
                .scaledFont(22, weight: .light)
                .foregroundStyle(Color.textDisabled)
            Text(text)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() async {
        guard let commit, let repo = appState.activeRepo?.path else {
            files = []
            return
        }
        loadingHash = commit.hash
        defer { loadingHash = nil }
        files = (try? await appState.git.commitFiles(repoPath: repo, hash: commit.hash)) ?? []
        // Reset row selection when we switch commits.
        selectedCommitPaths = []
    }

    /// If the right-clicked row is in the selection, act on the whole
    /// selection; otherwise on just that row — the same rule as the main
    /// window's Files panel.
    private func contextFiles(focused: GitFileStatus, rows: [GitFileStatus]) -> [GitFileStatus] {
        guard selectedCommitPaths.contains(focused.path) else { return [focused] }
        return rows.filter { selectedCommitPaths.contains($0.path) }
    }

    @ViewBuilder
    private func fileContextMenu(_ file: GitFileStatus, rows: [GitFileStatus]) -> some View {
        let targets = contextFiles(focused: file, rows: rows)
        Button(targets.count > 1 ? "Compare \(targets.count) Files…" : "Compare…") {
            openInDiffTool(files: targets)
        }
        Divider()
        Button("Log") {
            appState.fileHistoryTarget = .init(path: file.path)
        }
        Button("Blame") {
            appState.blameTarget = .init(path: file.path)
        }
        .disabled(file.state == .deleted)

        if let abs = absolutePath(for: file) {
            Divider()
            Button("Open") { appState.openInFinder(path: abs) }
                .disabled(file.state == .deleted)
            Button("Reveal in Finder") { appState.revealInFinder(path: abs) }
            Button("Open in Editor") { appState.openInEditor(path: abs) }
                .disabled(file.state == .deleted)
            Divider()
            Button("Copy Name") { appState.copyToPasteboard(file.name) }
            Button("Copy Path") { appState.copyToPasteboard(abs) }
            Button("Copy Relative Path") { appState.copyToPasteboard(file.path) }
        }
    }

    /// Compare `files` at the selected commit vs its first parent. Tries the
    /// configured external diff tool for each first; whatever it can't take
    /// (all of them, in the built-in case) opens in the built-in read-only
    /// compare window, one tab per file, so a compare always surfaces.
    private func openInDiffTool(files: [GitFileStatus]) {
        guard let commit, !files.isEmpty else { return }
        Task {
            var builtInPaths: [String] = []
            for file in files {
                if !(await appState.openExternalCommitDiff(commit: commit, path: file.path)) {
                    builtInPaths.append(file.path)
                }
            }
            guard !builtInPaths.isEmpty else { return }
            appState.commitCompareTarget = AppState.CommitCompareTarget(
                commit: commit, paths: builtInPaths
            )
        }
    }

    private func absolutePath(for file: GitFileStatus) -> String? {
        guard let root = appState.activeRepo?.path else { return nil }
        return (root as NSString).appendingPathComponent(file.path)
    }
}

// MARK: - Commit detail pane (right column)

private struct CommitDetailPane: View {
    @Bindable var appState: AppState
    @State private var messageBody: String = ""
    @State private var loadingHash: String?
    /// Containment keyed by commit — `git branch --contains` is slow on a
    /// big repo, and re-walking every ref each time the user clicks back
    /// to a commit they already looked at is the kind of wait that makes
    /// a pane feel broken.
    @State private var containment: [String: CommitContainment] = [:]
    @State private var loadingContainmentHash: String?
    /// Set once the user asks to see a long branch list in full.
    @State private var showAllBranches = false

    private var commit: GitCommit? {
        guard let id = appState.journalVM.selectedCommitID else { return nil }
        // Through the view model, not `commits`: a search result is a
        // commit from anywhere in history and is usually not in the
        // loaded window, which left this pane empty for a selected row.
        return appState.journalVM.commit(withID: id)
    }

    /// What the working-tree node has instead of commit metadata: how much
    /// is uncommitted, split the way it has to be dealt with — staged
    /// content is ready to commit, the rest is not.
    private var workingTreeDetail: some View {
        let files = appState.filesVM.files
        let staged = files.filter(\.isStaged).count
        let unstaged = files.filter { !$0.isStaged }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Uncommitted changes")
                    .scaledFont(13, weight: .medium)
                Text("\(files.count) file\(files.count == 1 ? "" : "s") — \(staged) staged, \(unstaged) not staged")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                Divider()
                Text("Nothing here is in the history yet. Commit from the toolbar, or from the main window's Files panel.")
                    .scaledFont(11)
                    .foregroundStyle(Color.textDisabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: appState.journalVM.workingTreeSelected ? "Working Tree" : "Commit")
            if appState.journalVM.workingTreeSelected {
                workingTreeDetail
            } else if let commit {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(commit)
                        Divider()
                        bodySection
                        if !commit.parentHashes.isEmpty {
                            Divider()
                            parentsSection(commit)
                        }
                        if !commit.refs.isEmpty {
                            Divider()
                            refsSection(commit)
                        }
                        Divider()
                        containmentSection(commit)
                    }
                    .padding(14)
                }
                .task(id: commit.hash) {
                    showAllBranches = false
                    await loadBody(for: commit)
                    await loadContainment(for: commit)
                }
                // Containment is a statement about where the refs are, so
                // a fetch, a new branch or a repo switch retires every
                // cached answer.
                .onChange(of: refFingerprint) { _, _ in containment.removeAll() }
            } else {
                emptyState
            }
        }
        .background(Color.bgPanel)
    }

    private func header(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(commit.shortHash)
                    .scaledFont(12, design: .monospaced)
                    .foregroundStyle(Color.accentBlue)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    appState.copyToPasteboard(commit.hash)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .scaledFont(10)
                }
                .buttonStyle(.borderless)
                .help("Copy full SHA")
            }
            Text(commit.subject)
                .scaledFont(13, weight: .semibold)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(commit.authorName)
                    .scaledFont(11)
                Text("<\(commit.authorEmail)>")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }
            Text(DateFormatters.absolute.string(from: commit.date))
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MESSAGE")
                .scaledFont(10, weight: .medium)
                .foregroundStyle(Color.textSecondary)
            if messageBody.isEmpty {
                Text(loadingHash != nil ? "Loading…" : "(no body)")
                    .scaledFont(11)
                    .foregroundStyle(Color.textDisabled)
            } else {
                Text(messageBody)
                    .scaledFont(12, design: .monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func parentsSection(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PARENT\(commit.parentHashes.count > 1 ? "S" : "")")
                .scaledFont(10, weight: .medium)
                .foregroundStyle(Color.textSecondary)
            ForEach(commit.parentHashes, id: \.self) { parent in
                Button {
                    if let p = appState.journalVM.commit(withID: parent) {
                        appState.journalVM.selectedCommitID = p.id
                    } else {
                        appState.copyToPasteboard(parent)
                    }
                } label: {
                    Text(String(parent.prefix(7)))
                        .scaledFont(12, design: .monospaced)
                        .foregroundStyle(Color.accentBlue)
                }
                .buttonStyle(.plain)
                .help(parent)
            }
        }
    }

    private func refsSection(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("REFS")
                .scaledFont(10, weight: .medium)
                .foregroundStyle(Color.textSecondary)
            FlowRefBadges(refs: commit.refs)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text")
                .scaledFont(28, weight: .light)
                .foregroundStyle(Color.textDisabled)
            Text("Select a commit")
                .scaledFont(12)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// SmartGit's "closest tags …" / "on branches …" lines: what already
    /// carries this commit, as opposed to `refsSection`, which is what
    /// points at it.
    @ViewBuilder
    private func containmentSection(_ commit: GitCommit) -> some View {
        let found = containment[commit.hash]
        VStack(alignment: .leading, spacing: 4) {
            Text("CONTAINED IN")
                .scaledFont(10, weight: .medium)
                .foregroundStyle(Color.textSecondary)

            if found == nil {
                Text(loadingContainmentHash == commit.hash ? "Loading…" : "—")
                    .scaledFont(11)
                    .foregroundStyle(Color.textDisabled)
            } else if let found, found.isEmpty {
                Text("No branch or tag contains this commit")
                    .scaledFont(11)
                    .foregroundStyle(Color.textDisabled)
            } else if let found {
                if let tag = found.closestTag {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("closest tag")
                            .scaledFont(11)
                            .foregroundStyle(Color.textSecondary)
                        Text(tag)
                            .scaledFont(11, weight: .medium)
                            .textSelection(.enabled)
                    }
                }
                if !found.branches.isEmpty {
                    branchList(found.branches)
                }
            }
        }
    }

    /// A long list is the normal case on a shared repo — a commit near
    /// the root is contained in every branch. Show a readable handful and
    /// let the user ask for the rest.
    @ViewBuilder
    private func branchList(_ branches: [String]) -> some View {
        let limit = 12
        let shown = showAllBranches ? branches : Array(branches.prefix(limit))
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("on branches")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                Text("\(branches.count)")
                    .scaledFont(10)
                    .foregroundStyle(Color.textDisabled)
            }
            Text(shown.joined(separator: ", "))
                .scaledFont(11)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if branches.count > limit, !showAllBranches {
                Button("Show all \(branches.count)") { showAllBranches = true }
                    .buttonStyle(.link)
                    .scaledFont(10)
            }
        }
    }

    private var refFingerprint: String {
        let branches = appState.branchesVM
        return [
            appState.activeRepo?.path ?? "-",
            String(branches.localBranches.count),
            String(branches.remoteBranches.count),
            String(branches.tags.count),
            branches.currentBranch ?? "-"
        ].joined(separator: "|")
    }

    private func loadContainment(for commit: GitCommit) async {
        guard containment[commit.hash] == nil else { return }
        guard let repo = appState.activeRepo?.path else { return }
        loadingContainmentHash = commit.hash
        defer {
            if loadingContainmentHash == commit.hash { loadingContainmentHash = nil }
        }
        let found = try? await appState.git.containment(repoPath: repo, hash: commit.hash)
        // The selection may have moved on while git walked the refs —
        // store the answer under its own hash either way, and let the
        // pane pick up whichever commit it is showing now.
        containment[commit.hash] = found ?? .empty
    }

    private func loadBody(for commit: GitCommit) async {
        loadingHash = commit.hash
        defer { loadingHash = nil }
        guard let repo = appState.activeRepo?.path else { return }
        do {
            self.messageBody = try await appState.git.commitBody(repoPath: repo, hash: commit.hash)
        } catch {
            self.messageBody = "(failed to load: \(error.localizedDescription))"
        }
    }
}

/// Flow-wrapped ref badges for the commit detail pane (the inline
/// journal version uses HStack since rows are single-line).
private struct FlowRefBadges: View {
    let refs: String

    var body: some View {
        let labels = RefParser.parse(refs)
        if labels.isEmpty {
            EmptyView()
        } else {
            // SwiftUI doesn't ship a flow layout < macOS 14 LayoutKit, but
            // for the small handful of refs a commit usually carries a
            // plain HStack with wrap is good enough — fall back to a
            // vertical stack when there's > 3 to avoid overflow.
            if labels.count <= 3 {
                HStack(spacing: 4) {
                    ForEach(labels) { RefBadge(label: $0) }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(labels) { RefBadge(label: $0) }
                }
            }
        }
    }
}
