import SwiftUI

/// History of a single file: every commit that touched `path`
/// (`git log --follow`), with the diff that each selected commit
/// introduced. Surfaced from the Files panel right-click as
/// "Log" — the daily-driver feature Fork and SmartGit
/// expose as "Log selected file" / "Show History".
struct FileHistoryView: View {
    @Bindable var appState: AppState
    let path: String
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    /// This view is scoped to one file, so unlike the main diff panel there
    /// is never any ambiguity about which language applies.
    private var language: SyntaxLanguage? { SyntaxLanguage(path: path) }

    @State private var commits: [GitCommit] = []
    @State private var selection: String?
    @State private var hunks: [DiffHunk] = []
    @State private var loading = true
    @State private var diffMode: DiffMode = .unified
    @State private var compactMode = true
    @State private var currentAnchor: Int = -1
    /// Rows the user has clicked in the diff pane, so more than one line
    /// can be copied out of a revision. Nothing here is editable, so that
    /// is all it does. Distinct from `selection`, which is the commit.
    @State private var lineSelection = DiffLineSelection()
    /// Row height the drag maps its Y offsets onto — every diff row is
    /// pinned to it, so the arithmetic is exact.
    @Environment(\.monoFontSize) private var monoFontSize

    private var fileName: String { (path as NSString).lastPathComponent }

    private var selectedCommit: GitCommit? {
        commits.first { $0.hash == selection }
    }

    private var unifiedRows: [(line: DiffLine, hunk: DiffHunk)] {
        hunks.flatMap { hunk in hunk.lines.map { (line: $0, hunk: hunk) } }
    }

    private var pairedRows: [(left: DiffLine, right: DiffLine, hunk: DiffHunk)] {
        DiffPairing.pairs(from: hunks)
    }

    /// Every selectable row in one order, shared by both layouts — a
    /// side-by-side row holds the same `DiffLine` values, paired up. Pad
    /// rows stand for a line that isn't there and have nothing to copy.
    private var selectableLines: [DiffLine] {
        hunks.flatMap(\.lines).filter { $0.type != .empty }
    }

    private var unifiedAnchors: [Int] {
        changeRunStarts(unifiedRows.map { $0.line.type == .add || $0.line.type == .del })
    }

    private var pairedAnchors: [Int] {
        changeRunStarts(pairedRows.map { row in
            row.left.type == .add || row.left.type == .del ||
            row.right.type == .add || row.right.type == .del
        })
    }

    private var activeAnchors: [Int] {
        switch diffMode {
        case .unified: return unifiedAnchors
        case .sideBySide: return pairedAnchors
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if commits.isEmpty {
                emptyState
            } else {
                VSplitView {
                    commitTable
                        .frame(minHeight: 160)
                    diffPane
                        .frame(minHeight: 160)
                }
            }

            footer
        }
        .background(
            DiffCopyShortcut(isEnabled: !lineSelection.isEmpty) {
                appState.copyToPasteboard(lineSelection.text(of: selectableLines))
            }
        )
        .padding(18)
        .frame(minWidth: 760, minHeight: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgPanel)
        .task {
            commits = await appState.fileHistory(path: path)
            loading = false
            // Preselect the most recent commit so the diff pane isn't empty.
            if selection == nil { selection = commits.first?.hash }
        }
        .task(id: "\(selection ?? ""):\(compactMode)") {
            await loadDiff()
        }
        .onChange(of: hunks) { _, _ in
            currentAnchor = -1
            // Line ids are minted fresh by each parse, so a selection made
            // against the previous revision names nothing.
            lineSelection.clear()
        }
        .onChange(of: diffMode) { _, _ in currentAnchor = -1 }
        .onExitCommand {
            closeFromEscape()
        }
        .onDisappear {
            if appState.fileHistoryTarget?.path == path {
                appState.fileHistoryTarget = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("History: \(fileName)").font(.title3.bold())
                Text(path)
                    .scaledFont(10, design: .monospaced)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(commits.count) commit\(commits.count == 1 ? "" : "s")")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var commitTable: some View {
        Table(of: GitCommit.self, selection: $selection) {
            TableColumn("Message") { commit in
                Text(commit.subject)
                    .scaledFont(12)
                    .lineLimit(1)
            }
            TableColumn("Author") { commit in
                Text(commit.authorName)
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }
            .width(140)
            TableColumn("Hash") { commit in
                Text(commit.shortHash)
                    .scaledFont(11, design: .monospaced)
                    .foregroundStyle(Color.textSecondary)
            }
            .width(80)
            TableColumn("When") { commit in
                Text(DateFormatters.relative(from: commit.date))
                    .scaledFont(10)
                    .foregroundStyle(Color.textSecondary)
            }
            .width(110)
        } rows: {
            ForEach(commits) { commit in
                TableRow(commit)
            }
        }
        // `primaryAction` is Table's double-click, so this works on any
        // column rather than only the one a gesture happened to be attached
        // to. The same closure backs the context menu's first item, so the
        // action is discoverable rather than only guessable.
        .contextMenu(forSelectionType: String.self) { ids in
            if let commit = commit(for: ids) {
                Button("Compare This Version…") { openCompare(commit) }
                Divider()
                Button("Copy Hash") { appState.copyToPasteboard(commit.hash) }
                Button("Copy Subject") { appState.copyToPasteboard(commit.subject) }
            }
        } primaryAction: { ids in
            guard let commit = commit(for: ids) else { return }
            openCompare(commit)
        }
    }

    private func commit(for ids: Set<String>) -> GitCommit? {
        guard let hash = ids.first else { return nil }
        return commits.first { $0.id == hash }
    }

    /// Opens the full compare window for this file at `commit`.
    ///
    /// Presented directly rather than by setting `appState.commitCompareTarget`:
    /// that route depends on an opener view being mounted, and the only one
    /// lives in the Log window — so from a File History opened over the main
    /// window it would have set a value nothing was listening for, and the
    /// double-click would have done nothing at all.
    private func openCompare(_ commit: GitCommit) {
        selection = commit.id
        CompareWindowPresenter.presentCommitCompare(
            appState: appState, commit: commit, path: path
        )
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            diffToolbar
            if selectedCommit == nil {
                placeholder("Select a commit to see what it changed.")
            } else if hunks.isEmpty {
                placeholder("No textual diff for this revision (binary, or first appearance).")
            } else {
                DiffHorizontalScroll(
                    lines: hunks.flatMap(\.lines).map(\.content),
                    columns: diffMode == .sideBySide ? 2 : 1
                ) {
                    switch diffMode {
                    case .unified:
                        unifiedDiff
                    case .sideBySide:
                        sideBySideDiff
                    }
                }
            }
        }
        .background(Color.bgPanel)
    }

    private var diffToolbar: some View {
        HStack(spacing: 10) {
            Text("Diff")
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Picker("", selection: $diffMode) {
                ForEach(DiffMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)

            Toggle("Compact", isOn: $compactMode)
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Compact: changed regions with context. Off: full file.")

            DiffCopyButton(count: lineSelection.count) {
                appState.copyToPasteboard(lineSelection.text(of: selectableLines))
            }

            Divider().frame(height: 16)

            Button {
                jump(by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(activeAnchors.isEmpty)
            .help("Previous change")

            Button {
                jump(by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(activeAnchors.isEmpty)
            .help("Next change")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.bgPanelHeader)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.strongBorder).frame(height: 0.5)
        }
    }

    private var unifiedDiff: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(unifiedRows.enumerated()), id: \.offset) { idx, row in
                            DiffLineView(line: row.line, side: .new,
                                         selected: lineSelection.contains(row.line),
                                         syntax: language)
                                .frame(width: geo.size.width, alignment: .leading)
                                .modifier(DiffRowSelection(
                                    line: row.line, selection: $lineSelection,
                                    lines: selectableLines, appState: appState
                                ))
                                .id("row-\(idx)")
                        }
                    }
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .modifier(DiffDragSelection(
                        selection: $lineSelection,
                        rowHeight: monoRowHeight(for: monoFontSize)
                    ) { range, _ in
                        let rows = unifiedRows
                        return range.compactMap { rows.indices.contains($0) ? rows[$0].line : nil }
                    })
                }
                .background(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        Color.bgPanelHeader.frame(width: 46)
                        Spacer(minLength: 0)
                    }
                }
                .onChange(of: currentAnchor) { _, idx in
                    scrollToAnchor(idx, proxy: proxy)
                }
            }
        }
    }

    private var sideBySideDiff: some View {
        GeometryReader { geo in
            let colWidth = (geo.size.width - 1) / 2
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(pairedRows.enumerated()), id: \.offset) { idx, row in
                            HStack(spacing: 0) {
                                DiffLineView(line: row.left, side: .old,
                                             selected: lineSelection.contains(row.left),
                                             syntax: language)
                                    .frame(width: colWidth, alignment: .leading)
                                    .modifier(DiffRowSelection(
                                        line: row.left, selection: $lineSelection,
                                        lines: selectableLines, appState: appState
                                    ))
                                Divider()
                                DiffLineView(line: row.right, side: .new,
                                             selected: lineSelection.contains(row.right),
                                             syntax: language)
                                    .frame(width: colWidth, alignment: .leading)
                                    .modifier(DiffRowSelection(
                                        line: row.right, selection: $lineSelection,
                                        lines: selectableLines, appState: appState
                                    ))
                            }
                            .id("row-\(idx)")
                        }
                    }
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .modifier(DiffDragSelection(
                        selection: $lineSelection,
                        rowHeight: monoRowHeight(for: monoFontSize)
                    ) { range, startX in
                        let rows = pairedRows
                        return range.compactMap { i in
                            guard rows.indices.contains(i) else { return nil }
                            return startX < colWidth ? rows[i].left : rows[i].right
                        }
                    })
                }
                .onChange(of: currentAnchor) { _, idx in
                    scrollToAnchor(idx, proxy: proxy)
                }
            }
        }
    }

    private func changeRunStarts(_ isChanged: [Bool]) -> [Int] {
        var starts: [Int] = []
        var previous = false
        for (index, changed) in isChanged.enumerated() {
            if changed && !previous { starts.append(index) }
            previous = changed
        }
        return starts
    }

    private func jump(by delta: Int) {
        let anchors = activeAnchors
        guard !anchors.isEmpty else { return }
        if currentAnchor < 0 {
            currentAnchor = delta > 0 ? 0 : anchors.count - 1
        } else {
            currentAnchor = max(0, min(anchors.count - 1, currentAnchor + delta))
        }
    }

    private func scrollToAnchor(_ idx: Int, proxy: ScrollViewProxy) {
        let anchors = activeAnchors
        guard idx >= 0, idx < anchors.count else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("row-\(anchors[idx])", anchor: .top)
        }
    }

    private func loadDiff() async {
        guard let hash = selection else {
            hunks = []
            return
        }
        hunks = await appState.fileDiff(path: path, atCommit: hash, compact: compactMode)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .scaledFont(11)
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Copy Hash") {
                if let commit = selectedCommit { appState.copyToPasteboard(commit.hash) }
            }
            .disabled(selectedCommit == nil)

            Spacer()

            Button("Done") { close() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func closeFromEscape() {
        guard appState.appConfig.escapeClosesSubwindows else { return }
        close()
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock")
                .scaledFont(28, weight: .light)
                .foregroundStyle(Color.textDisabled)
            Text("No history for this file")
                .foregroundStyle(Color.textSecondary)
            Text("It may be untracked, or not yet committed.")
                .scaledFont(10)
                .foregroundStyle(Color.textDisabled)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}
