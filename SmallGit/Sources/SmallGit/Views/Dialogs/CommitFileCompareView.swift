import SwiftUI

/// Read-only side-by-side compare for one file at a single commit — the
/// file as it stood at the commit's parent (left) vs. at the commit
/// itself (right). Opened by double-clicking a file in the Log window
/// when no external diff tool is configured, so the built-in path shows
/// a compare window too instead of silently doing nothing.
///
/// The same window also shows HEAD against the index, for the commit
/// dialog: there the question is "what will this commit record", which is
/// exactly one commit's worth of change that simply hasn't been made yet.
///
/// Unlike `FileCompareView` (a HEAD-vs-working editor), this is a
/// non-editable snapshot, so there's no save/stage affordance.
struct CommitFileCompareView: View {
    /// What the two sides are.
    enum Source {
        /// The commit's parent against the commit.
        case commit(GitCommit)
        /// HEAD against the index — the commit about to be made.
        case staged
    }

    @Bindable var appState: AppState
    let source: Source
    let path: String
    /// Repository the commit belongs to, when it is not the active one —
    /// a submodule's commit, opened from the Submodule window.
    var repoPathOverride: String? = nil
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.monoFontSize) private var monoFontSize

    @State private var hunks: [DiffHunk] = []
    @State private var loading = true
    @State private var diffMode: DiffMode = .sideBySide
    @State private var compactMode = true
    @State private var currentAnchor: Int = -1
    /// Rows the user has clicked, so more than one line can be copied out.
    /// This window is read-only, so that is all a selection does here.
    @State private var selection = DiffLineSelection()

    /// ⌘F over the hunks on screen.
    @State private var find = TextFindState()
    @FocusState private var findFocused: Bool

    private var fileName: String { (path as NSString).lastPathComponent }

    private var sourceKey: String {
        switch source {
        case .commit(let commit): return commit.hash
        case .staged:             return "index"
        }
    }

    private var sourceDescription: String {
        switch source {
        case .commit(let commit): return "\(commit.shortHash) — \(commit.subject)"
        case .staged:             return "HEAD vs Index — what the commit will record"
        }
    }

    private var paneTitles: (left: (title: String, subtitle: String), right: (title: String, subtitle: String)) {
        switch source {
        case .commit(let commit):
            return (("Parent", "before this commit"), ("This commit", commit.shortHash))
        case .staged:
            return (("HEAD", "last committed"), ("Index", "staged to commit"))
        }
    }

    private var placeholderTitle: String {
        switch source {
        case .commit: return "No textual diff for this revision"
        case .staged: return "Nothing staged in this file"
        }
    }

    private var placeholderDetail: String {
        switch source {
        case .commit: return "The file may be binary, or this is its first appearance."
        case .staged: return "The file may be binary, or its changes have been unstaged since."
        }
    }
    private var gutterWidth: CGFloat { max(34, monoFontSize * 3.5) }

    /// `nil` for a file the highlighter doesn't know, which renders the diff
    /// exactly as it did before. Only the hunks are on hand here, not the two
    /// file versions, so each line is coloured on its own — see `DiffLineView`.
    private var language: SyntaxLanguage? { SyntaxLanguage(path: path) }

    private var unifiedRows: [(line: DiffLine, hunk: DiffHunk)] {
        hunks.flatMap { hunk in hunk.lines.map { (line: $0, hunk: hunk) } }
    }

    /// Every selectable row in one order, which both layouts share: the two
    /// sides of a side-by-side row are the same `DiffLine` values the
    /// unified list holds, paired up. Pad rows stand for a line that isn't
    /// there and have nothing to copy.
    private var selectableLines: [DiffLine] {
        hunks.flatMap(\.lines).filter { $0.type != .empty }
    }

    private var pairedRows: [(left: DiffLine, right: DiffLine, hunk: DiffHunk)] {
        DiffPairing.pairs(from: hunks)
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
        VStack(spacing: 0) {
            header
            Divider()
            if find.isPresented {
                FindBar(state: find, isFocused: $findFocused)
            }
            content
            DiffCopyShortcut(isEnabled: !selection.isEmpty) {
                appState.copyToPasteboard(selection.text(of: selectableLines))
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgPanel)
        .task(id: "\(sourceKey):\(compactMode)") {
            await loadDiff()
        }
        .findBarShortcuts(find, focus: $findFocused)
        .onChange(of: hunks) { _, _ in
            currentAnchor = -1
            // Line ids are minted fresh by each parse, so a selection made
            // against the previous one names nothing.
            selection.clear()
            // The rows the offsets point into have just been replaced.
            configureFind()
        }
        .onChange(of: diffMode) { _, _ in
            currentAnchor = -1
            // Unified and side-by-side number their rows differently, so a
            // match found in one layout points at the wrong row in the other.
            configureFind()
        }
        .onExitCommand {
            if find.isPresented { find.dismiss() } else { closeFromEscape() }
        }
    }

    // MARK: - Header

    /// Written through `AppState` rather than straight at the config field,
    /// so ticking the box in any of the three places that offer it persists
    /// and reaches every other diff view.
    private var whitespaceBinding: Binding<Bool> {
        Binding(
            get: { appState.appConfig.showWhitespace },
            set: { appState.setShowWhitespace($0) }
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x1")
                .foregroundStyle(Color.accentBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare \(fileName)")
                    .scaledFont(13, weight: .semibold)
                Text(sourceDescription)
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(path)
                .scaledFont(10, design: .monospaced)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

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

            Toggle("Whitespace", isOn: whitespaceBinding)
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show spaces as \u{00B7}, tabs as \u{2192} and line ends as \u{00B6}")

            DiffCopyButton(count: selection.count) {
                appState.copyToPasteboard(selection.text(of: selectableLines))
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bgPanelHeader)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hunks.isEmpty {
            placeholder
        } else {
            DiffHorizontalScroll(
                lines: hunks.flatMap(\.lines).map(\.content),
                columns: diffMode == .sideBySide ? 2 : 1
            ) {
                switch diffMode {
                case .unified:
                    unified
                case .sideBySide:
                    sideBySide
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text")
                .scaledFont(28, weight: .light)
                .foregroundStyle(Color.textDisabled)
            Text(placeholderTitle)
                .foregroundStyle(Color.textSecondary)
                .scaledFont(12)
            Text(placeholderDetail)
                .scaledFont(10)
                .foregroundStyle(Color.textDisabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Column titles plus the paired rows in one shared vertical
    /// ScrollView so the two sides scroll together — same structure as
    /// the main Diff panel's side-by-side layout.
    private var sideBySide: some View {
        GeometryReader { geo in
            let colWidth = (geo.size.width - 1) / 2
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        Section {
                            ForEach(Array(pairedRows.enumerated()), id: \.offset) { idx, row in
                                HStack(spacing: 0) {
                                    DiffLineView(line: row.left, side: .old,
                                                 selected: selection.contains(row.left),
                                                 syntax: language,
                                                 searchMatches: find.matches(onLine: idx, column: 0),
                                                 currentMatch: find.current)
                                        .frame(width: colWidth, alignment: .leading)
                                        .modifier(DiffRowSelection(
                                            line: row.left, selection: $selection,
                                            lines: selectableLines, appState: appState
                                        ))
                                    Divider()
                                    DiffLineView(line: row.right, side: .new,
                                                 selected: selection.contains(row.right),
                                                 syntax: language,
                                                 searchMatches: find.matches(onLine: idx, column: 1),
                                                 currentMatch: find.current)
                                        .frame(width: colWidth, alignment: .leading)
                                        .modifier(DiffRowSelection(
                                            line: row.right, selection: $selection,
                                            lines: selectableLines, appState: appState
                                        ))
                                }
                                .id("row-\(idx)")
                            }
                        } header: {
                            paneHeaders(colWidth: colWidth)
                        }
                    }
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .modifier(DiffDragSelection(
                        selection: $selection,
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
                .onChange(of: find.current) { _, match in
                    guard let match else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("row-\(match.line)", anchor: .center)
                    }
                }
            }
        }
    }

    private var unified: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(unifiedRows.enumerated()), id: \.offset) { idx, row in
                            DiffLineView(line: row.line, side: .new,
                                         selected: selection.contains(row.line),
                                         syntax: language,
                                         searchMatches: find.matches(onLine: idx, column: 0),
                                         currentMatch: find.current)
                                .frame(width: geo.size.width, alignment: .leading)
                                .modifier(DiffRowSelection(
                                    line: row.line, selection: $selection,
                                    lines: selectableLines, appState: appState
                                ))
                                .id("row-\(idx)")
                        }
                    }
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .modifier(DiffDragSelection(
                        selection: $selection,
                        rowHeight: monoRowHeight(for: monoFontSize)
                    ) { range, _ in
                        let rows = unifiedRows
                        return range.compactMap { rows.indices.contains($0) ? rows[$0].line : nil }
                    })
                }
                .background(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        Color.bgPanelHeader.frame(width: gutterWidth)
                        Spacer(minLength: 0)
                    }
                }
                .onChange(of: currentAnchor) { _, idx in
                    scrollToAnchor(idx, proxy: proxy)
                }
                .onChange(of: find.current) { _, match in
                    guard let match else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("row-\(match.line)", anchor: .center)
                    }
                }
            }
        }
    }

    /// Points the find bar at whichever layout is on screen.
    private func configureFind() {
        find.configure(columns: {
            switch diffMode {
            case .unified:
                return [unifiedRows.map { $0.line.content }]
            case .sideBySide:
                return [
                    pairedRows.map { $0.left.content },
                    pairedRows.map { $0.right.content }
                ]
            }
        })
        find.recompute()
    }

    private func loadDiff() async {
        loading = true
        switch source {
        case .commit(let commit):
            hunks = await appState.fileDiff(
                path: path,
                atCommit: commit.hash,
                compact: compactMode,
                repoPath: repoPathOverride
            )
        case .staged:
            hunks = await appState.stagedFileDiff(
                path: path,
                compact: compactMode,
                repoPath: repoPathOverride
            )
        }
        loading = false
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

    private func paneHeaders(colWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            paneTitle(paneTitles.left.title, subtitle: paneTitles.left.subtitle, tint: .blue)
                .frame(width: colWidth, alignment: .leading)
            Divider()
            paneTitle(paneTitles.right.title, subtitle: paneTitles.right.subtitle, tint: .green)
                .frame(width: colWidth, alignment: .leading)
        }
        .background(Color.bgPanelHeader)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.borderColor).frame(height: 0.5)
        }
    }

    private func paneTitle(_ title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(title).scaledFont(11, weight: .semibold)
            Text(subtitle)
                .scaledFont(10)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if case .commit(let commit) = source {
                Button("Copy Hash") {
                    appState.copyToPasteboard(commit.hash)
                }
            }
            Spacer()
            Button("Close") { close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bgPanelHeader)
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
}
