import SwiftUI

struct DiffView: View {
    @Bindable var appState: AppState
    @Bindable var viewModel: DiffViewModel
    /// Whether the header offers the switch to the Terminal. The Log
    /// window's diff sets this false: it is a second view of a commit, not
    /// the main window's Changes slot, and has no terminal to swap with.
    var showsTerminalSwitch: Bool = true
    /// Whether double-clicking a line stages or unstages it.
    ///
    /// False in the Submodule window: the staging actions run against the
    /// *active* repository, and the diff there belongs to a different one —
    /// so a double-click would stage a line of B's file into A.
    var allowsStaging: Bool = true
    @Environment(\.monoFontSize) private var monoFontSize
    @Environment(\.openWindow) private var openWindow

    /// Language of the file the panel is scoped to, or `nil` when it isn't
    /// scoped to one — `source.file` is `nil` for a stash or commit diff,
    /// which spans several files at once.
    private var language: SyntaxLanguage? {
        viewModel.source.file.flatMap(SyntaxLanguage.init(path:))
    }

    /// Language for one row.
    ///
    /// For a multi-file diff this is the language of the row's *own* hunk,
    /// taken from the `diff --git` header the parser recorded. Using the
    /// view's language throughout would light a Markdown paragraph up with
    /// Swift keywords the moment a commit touched both.
    private func language(for hunk: DiffHunk) -> SyntaxLanguage? {
        language ?? hunk.file.flatMap(SyntaxLanguage.init(path:))
    }

    /// Index into `activeAnchors` of the change the user last jumped to via
    /// the ↑/↓ buttons. -1 means "before the first change". The layouts'
    /// `ScrollViewReader`s watch this and scroll the matching row to the top.
    @State private var currentAnchor: Int = -1

    /// The side-by-side row the pointer is on, which is the row the revert
    /// arrow sits on and acts on.
    @State private var hoveredRow: Int?

    /// Matches the gutter width formula in `DiffLineView` so the
    /// static background bars line up with each row's line-number cell.
    private var gutterWidth: CGFloat { max(34, monoFontSize * 3.5) }

    // MARK: - Revert arrow

    /// What the hover arrow offers for the diff on screen, or nil when it
    /// offers nothing: a source whose lines can't be reverted, or the
    /// Submodule window, whose writes would land in the wrong repo for the
    /// same reason double-click staging is off there.
    private var rowRevert: DiffRowRevert? {
        guard allowsStaging else { return nil }
        return DiffRowRevert(source: viewModel.source)
    }

    /// Diameter of the arrow. Tied to the row it sits on so it neither
    /// overflows a row at small font sizes nor gets lost at large ones.
    private var revertArrowSize: CGFloat { max(13, monoFontSize + 2) }

    /// One click for what the context menu spells out, placed where the two
    /// sides meet — Beyond Compare's copy arrow, in the only currency this
    /// panel deals in. Both panes are read-only renderings of a `git diff`,
    /// so copying left over right is a patch reverse-applied to the right
    /// pane's tree rather than one pane's text written into the other.
    private func revertButton(_ action: DiffRowRevert, lines: [DiffLine]) -> some View {
        Button {
            guard let file = viewModel.source.file else { return }
            let ids = Set(lines.map(\.id))
            let hunks = viewModel.hunks
            Task {
                switch action {
                case .unstage: await appState.unstageLines(ids, in: hunks, file: file)
                case .discard: await appState.discardLines(ids, in: hunks, file: file)
                }
            }
        } label: {
            Image(systemName: DiffRowRevert.symbol)
                .font(.system(size: revertArrowSize))
                .foregroundStyle(Color.accentBlue)
                // The divider and the right pane's line numbers both run
                // under the arrow; a filled disc behind the glyph keeps its
                // outline readable over them.
                .background(Circle().fill(Color.bgPanel).padding(1))
        }
        .buttonStyle(.plain)
        .frame(width: revertArrowSize, height: revertArrowSize)
        .help(action.help)
    }

    // MARK: - Change navigation

    /// Row indices that begin a contiguous run of changed (+/-) lines —
    /// one entry per change "section". Used to jump between changes, which
    /// matters most in the full-file view where sections are far apart.
    private func changeRunStarts(_ isChanged: [Bool]) -> [Int] {
        var starts: [Int] = []
        var prevChanged = false
        for (i, changed) in isChanged.enumerated() {
            if changed && !prevChanged { starts.append(i) }
            prevChanged = changed
        }
        return starts
    }

    private var unifiedAnchors: [Int] {
        changeRunStarts(viewModel.unifiedRows.map { $0.line.type == .add || $0.line.type == .del })
    }

    private var pairedAnchors: [Int] {
        changeRunStarts(viewModel.pairedRows.map { row in
            row.left.type == .add || row.left.type == .del ||
            row.right.type == .add || row.right.type == .del
        })
    }

    /// Anchors for whichever layout is on screen.
    private var activeAnchors: [Int] {
        switch viewModel.diffMode {
        case .unified:    return unifiedAnchors
        case .sideBySide: return pairedAnchors
        }
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

    @ViewBuilder
    private var changeNavButtons: some View {
        let count = activeAnchors.count
        Divider().frame(height: 16)
        Group {
            Button { jump(by: -1) } label: { Image(systemName: "chevron.up") }
                .help("Previous change")
            Button { jump(by: 1) } label: { Image(systemName: "chevron.down") }
                .help("Next change")
        }
        .buttonStyle(.borderless)
        .disabled(count == 0)
    }

    /// Double-click toggles staging for the line in whichever direction
    /// the current compare mode implies: HEAD vs Index → unstage,
    /// Index vs Working Tree → stage. Context (unchanged) and pad lines
    /// are ignored.
    private func activateLine(_ line: DiffLine, in hunk: DiffHunk) {
        guard allowsStaging else { return }
        guard line.type == .add || line.type == .del else { return }
        guard case .fileChanges(let file, let mode) = viewModel.source else { return }
        switch mode {
        case .headVsIndex:
            Task { await appState.unstageLine(line, in: hunk, file: file) }
        case .indexVsWorkingTree:
            Task { await appState.stageLine(line, in: hunk, file: file) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: viewModel.source.title) {
                // Only the main window's Changes panel has a terminal to
                // switch to; the Log window's diff stands alone.
                if showsTerminalSwitch {
                    PanelModeSwitch(showsTerminal: false) { appState.showTerminal(true) }
                }
            } trailing: {
                HStack(spacing: 10) {
                    // Unified / Side by Side / change navigation all describe
                    // a text diff. A submodule has none — two commits and a
                    // log — so the controls that would do nothing are gone
                    // rather than sitting there inviting a click.
                    if case .submodule = viewModel.source {
                        EmptyView()
                    } else {
                    Picker("", selection: $viewModel.diffMode) {
                        ForEach(DiffMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)

                    if let mode = viewModel.source.compareMode,
                       let file = viewModel.source.file {
                        Divider().frame(height: 16)

                        Picker(
                            "",
                            selection: Binding(
                                get: { mode },
                                set: { newMode in
                                    Task { await viewModel.loadDiff(file: file, mode: newMode) }
                                }
                            )
                        ) {
                            ForEach(DiffCompareMode.allCases, id: \.self) { m in
                                Text(m.shortLabel).tag(m)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                        .help("What to compare: HEAD↔Index shows staged changes, Index↔Working shows unstaged.")
                    }

                    }

                    DiffCopyButton(count: viewModel.selection.count) {
                        appState.copyToPasteboard(viewModel.selectedText)
                    }

                    overflowMenu

                    if !isSubmoduleSource {
                        changeNavButtons
                    }
                }
            }

            if case .conflict(let file) = viewModel.source {
                ConflictActionBanner(appState: appState, path: file)
            }

            DiffCopyShortcut(isEnabled: !viewModel.selection.isEmpty) {
                appState.copyToPasteboard(viewModel.selectedText)
            }

            if case .submodule = viewModel.source {
                submoduleContent
            } else if viewModel.hunks.isEmpty {
                emptyState
            } else {
                DiffHorizontalScroll(
                    lines: viewModel.hunks.flatMap(\.lines).map(\.content),
                    columns: viewModel.diffMode == .sideBySide ? 2 : 1
                ) {
                    switch viewModel.diffMode {
                    case .sideBySide:
                        sideBySide
                    case .unified:
                        unified
                    }
                }
            }
        }
        .background(Color.bgPanel)
        // Compact changes how much context git emits, so it needs a
        // re-fetch — and we persist the choice so it sticks next launch.
        .onChange(of: viewModel.compactMode) { _, new in
            if appState.appConfig.diffCompactMode != new {
                appState.appConfig.diffCompactMode = new
                Task { await appState.saveAppConfig() }
            }
            reloadForCurrentSource()
        }
        // Reset change navigation and hover whenever the content or layout
        // changes: a stale anchor index scrolls to the wrong row, and a stale
        // hover parks the arrow on a row that now holds a different line.
        .onChange(of: viewModel.hunks) { _, _ in
            currentAnchor = -1
            hoveredRow = nil
        }
        .onChange(of: viewModel.diffMode) { _, _ in
            currentAnchor = -1
            hoveredRow = nil
        }
    }

    private var isSubmoduleSource: Bool {
        if case .submodule = viewModel.source { return true }
        return false
    }

    /// A submodule's pointer change, with the way to the rest of it. The
    /// panel shows the commits; the sheet double-click opens adds what to
    /// *do* about them, and saying so here is how anyone finds that.
    @ViewBuilder
    private var submoduleContent: some View {
        if let change = viewModel.submoduleChange {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The two ends of the pointer first: which commits, in
                    // the shape SmartGit uses. The log between them is what
                    // Compare opens.
                    SubmoduleCommitCards(change: change) {
                        Task {
                            if await appState.openSubmoduleLog(path: change.path) {
                                openWindow(id: "submodule-log")
                            }
                        }
                    }
                    if !change.dirtyFiles.isEmpty {
                        SubmoduleDirtyFiles(change: change)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyPanelState(
                icon: "shippingbox",
                title: "Submodule",
                message: "Nothing recorded for this path yet."
            )
        }
    }

    /// Written through `AppState` rather than straight at the config field,
    /// so ticking the box in any of the three places that offer it persists
    /// and reaches every other diff view.
    private var whitespaceBinding: Binding<Bool> {
        Binding(
            get: { appState.appConfig.showWhitespace },
            set: { appState.setShowWhitespace($0) }
        )
    }

    /// Catch-all menu for low-frequency diff toggles. Pulled out of the
    /// header HStack so wider controls (the two segmented pickers) don't
    /// clip the toggle on narrow panel widths. A leading Divider keeps it
    /// visually separated from the segmented picker on its left — the
    /// borderless menu icon would otherwise crowd the picker's rounded
    /// right edge.
    @ViewBuilder
    private var overflowMenu: some View {
        Divider().frame(height: 16)
        Menu {
            // Compact is a toggle, not a layout mode: it controls how much
            // context is shown and works on top of either layout. On
            // (default) = changed regions with a few lines of context;
            // off = the whole file.
            Toggle("Compact", isOn: $viewModel.compactMode)
            Toggle("Ignore Whitespace", isOn: $viewModel.ignoreWhitespace)
            // Sits under "Ignore Whitespace" because the two are the same
            // question asked in opposite directions: hide it, or show all
            // of it. They are independent — ignoring whitespace for the
            // *diff* and drawing what whitespace remains both make sense.
            Toggle("Show Whitespace", isOn: whitespaceBinding)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Diff options")
        .onChange(of: viewModel.ignoreWhitespace) { _, _ in
            reloadForCurrentSource()
        }
    }

    private func reloadForCurrentSource() {
        switch viewModel.source {
        case .fileChanges(let f, let mode):
            Task { await viewModel.loadDiff(file: f, mode: mode) }
        case .untrackedFile(let f):
            Task { await viewModel.loadUntrackedDiff(file: f) }
        case .conflict(let f):
            Task { await viewModel.loadConflictDiff(file: f) }
        case .stash(let i, let path):
            Task { await viewModel.loadStashDiff(index: i, path: path) }
        case .commit(let hash, let short, let subject):
            // Rebuild a minimal GitCommit envelope; only hash is used by
            // GitService.commitDiff but the source case carries the
            // display strings for the title.
            let placeholder = GitCommit(
                hash: hash, shortHash: short, subject: subject,
                authorName: "", authorEmail: "",
                date: Date(), refs: ""
            )
            Task { await viewModel.loadCommitDiff(placeholder, paths: viewModel.commitPaths) }
        case .submodule(let path):
            // Whitespace and compact settings mean nothing to a log, but
            // re-reading is harmless and keeps the panel honest if the
            // submodule moved while the setting was being changed.
            Task { await viewModel.loadSubmodule(path: path) }
        case .none:
            break
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text")
                .scaledFont(28, weight: .light)
                .foregroundStyle(Color.textDisabled)
            Text(emptyStateMessage)
                .foregroundStyle(Color.textSecondary)
                .scaledFont(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateMessage: String {
        switch viewModel.source {
        case .none:  return "Select a file to see its diff"
        // Only the whole entry can be called empty: a stash narrowed to one
        // file with nothing in it is a file with no textual diff.
        case .stash(_, let path): return path == nil ? "This stash is empty" : "No differences"
        default:     return "No differences"
        }
    }

    // MARK: - Layouts

    /// Side-by-side view in a SINGLE vertical ScrollView containing
    /// HStack rows — both columns scroll together for free, matching
    /// SmartGit / Beyond-Compare expectation. Earlier this was two
    /// separate ScrollViews and the panes drifted apart on scroll,
    /// breaking the line-up between old/new lines you're trying to
    /// compare visually.
    private var sideBySide: some View {
        GeometryReader { geo in
            let colWidth = (geo.size.width - 1) / 2
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.pairedRows.enumerated()), id: \.offset) { idx, row in
                        HStack(spacing: 0) {
                            DiffLineView(
                                line: row.left,
                                side: .old,
                                selected: viewModel.selection.contains(row.left),
                                syntax: language(for: row.hunk)
                            )
                                .frame(width: colWidth, alignment: .leading)
                                .contentShape(Rectangle())
                                // Plain tap + simultaneous double-tap, not two
                                // `onTapGesture(count:)` recognizers: sharing a
                                // single- and double-tap on one view makes
                                // SwiftUI hold the single tap for the system
                                // double-click interval to disambiguate, which
                                // delayed selection by ~seconds. See JournalView.
                                .onTapGesture { viewModel.selectLine(row.left) }
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded {
                                        activateLine(row.left, in: row.hunk)
                                    }
                                )
                                .contextMenu {
                                    DiffContextMenu(
                                        line: row.left,
                                        hunk: row.hunk,
                                        source: viewModel.source,
                                        appState: appState,
                                        viewModel: viewModel
                                    )
                                }
                            Divider()
                            DiffLineView(
                                line: row.right,
                                side: .new,
                                selected: viewModel.selection.contains(row.right),
                                syntax: language(for: row.hunk)
                            )
                                .frame(width: colWidth, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { viewModel.selectLine(row.right) }
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded {
                                        activateLine(row.right, in: row.hunk)
                                    }
                                )
                                .contextMenu {
                                    DiffContextMenu(
                                        line: row.right,
                                        hunk: row.hunk,
                                        source: viewModel.source,
                                        appState: appState,
                                        viewModel: viewModel
                                    )
                                }
                        }
                        // Placed on the row rather than on the viewport: this
                        // layout scrolls vertically only, so the divider stays
                        // put under the arrow and the row carries it along.
                        //
                        // An unchanged row contributes no target lines, which
                        // is what keeps the arrow off it: the two sides
                        // already hold the same text there, so copying one
                        // over the other would write back what is there.
                        .overlay(alignment: .leading) {
                            if let action = rowRevert, hoveredRow == idx {
                                let targets = DiffRowRevert.targetLines(
                                    left: row.left, right: row.right
                                )
                                if !targets.isEmpty {
                                    revertButton(action, lines: targets)
                                        .offset(x: colWidth - revertArrowSize / 2)
                                }
                            }
                        }
                        .onHover { inside in
                            if inside {
                                hoveredRow = idx
                            } else if hoveredRow == idx {
                                hoveredRow = nil
                            }
                        }
                        .id("row-\(idx)")
                    }
                }
                .frame(minHeight: geo.size.height, alignment: .top)
                .modifier(DiffDragSelection(
                    selection: $viewModel.selection,
                    rowHeight: monoRowHeight(for: monoFontSize)
                ) { range, startX in
                    let rows = viewModel.pairedRows
                    return range.compactMap { i in
                        guard rows.indices.contains(i) else { return nil }
                        return startX < colWidth ? rows[i].left : rows[i].right
                    }
                })
            }
            .background(alignment: .topLeading) {
                sideBySideGutterBackground(colWidth: colWidth)
            }
            .onChange(of: currentAnchor) { _, idx in
                scrollToAnchor(idx, proxy: proxy)
            }
            }
        }
    }

    private var unified: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.unifiedRows.enumerated()), id: \.offset) { idx, row in
                        DiffLineView(
                            line: row.line,
                            side: .new,
                            selected: viewModel.selection.contains(row.line),
                            syntax: language(for: row.hunk)
                        )
                            .frame(width: geo.size.width, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.selectLine(row.line) }
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    activateLine(row.line, in: row.hunk)
                                }
                            )
                            .contextMenu {
                                DiffContextMenu(
                                    line: row.line,
                                    hunk: row.hunk,
                                    source: viewModel.source,
                                    appState: appState,
                                    viewModel: viewModel
                                )
                            }
                            .id("row-\(idx)")
                    }
                }
                .frame(minHeight: geo.size.height, alignment: .top)
                .modifier(DiffDragSelection(
                    selection: $viewModel.selection,
                    rowHeight: monoRowHeight(for: monoFontSize)
                ) { range, _ in
                    let rows = viewModel.unifiedRows
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
            }
        }
    }

    /// Scrolls the row that begins change `idx` to the top of the viewport.
    private func scrollToAnchor(_ idx: Int, proxy: ScrollViewProxy) {
        let anchors = activeAnchors
        guard idx >= 0, idx < anchors.count else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("row-\(anchors[idx])", anchor: .top)
        }
    }

    /// Static gutter columns painted behind the side-by-side ScrollView
    /// so short diffs don't end in a torn-off line-number band — the
    /// gutter visually continues all the way to the bottom of the panel.
    private func sideBySideGutterBackground(colWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.bgPanelHeader.frame(width: gutterWidth)
            Spacer(minLength: 0).frame(width: max(0, colWidth - gutterWidth))
            Color.borderColor.frame(width: 1)
            Color.bgPanelHeader.frame(width: gutterWidth)
            Spacer(minLength: 0)
        }
    }
}

/// Quick-action strip shown above the inline diff when the current file
/// is conflicted — mirrors SmartGit's per-file action row so the user
/// can resolve without opening the full 4-pane window.
private struct ConflictActionBanner: View {
    let appState: AppState
    let path: String

    private var kind: ConflictKind? {
        appState.filesVM.files.first { $0.path == path }?.conflictKind
    }

    /// What the banner calls itself. A modify/delete says so here, because
    /// "Conflicted" alone leaves the user hunting for markers that a
    /// delete conflict never has.
    private var headline: String {
        guard let kind, kind.isDeleteConflict else { return "Conflicted" }
        return kind.label
    }

    private var subtitle: String {
        guard let kind, kind.isDeleteConflict else { return "— resolve before staging" }
        return "— one side deleted this file; keep it or finish the delete"
    }

    /// "Take Ours" is the wrong promise when our side has no version of
    /// the file: the button deletes it. Each side is named for what it
    /// actually does, so the destructive one is not a surprise.
    private var oursLabel: String {
        guard let kind, kind.isDeleteConflict else { return "Take Ours" }
        return kind.hasOurs ? "Keep File (ours)" : "Delete File (ours)"
    }

    private var theirsLabel: String {
        guard let kind, kind.isDeleteConflict else { return "Take Theirs" }
        return kind.hasTheirs ? "Keep File (theirs)" : "Delete File (theirs)"
    }

    /// A delete conflict has no marker block to hand-edit, so "Mark
    /// Resolved" — stage whatever is on disk — would quietly resolve it
    /// as "keep the file" and read like a no-op. The two named buttons
    /// already cover both outcomes.
    private var showsMarkResolved: Bool {
        !(kind?.isDeleteConflict ?? false)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(headline)
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(Color.textPrimary)
            Text(subtitle)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Button("Conflict Solver") {
                appState.openCompareOrMerge(path: path, isConflict: true)
            }
            .controlSize(.small)
            Button(oursLabel) {
                Task { await appState.acceptOurs(path: path) }
            }
            .controlSize(.small)
            Button(theirsLabel) {
                Task { await appState.acceptTheirs(path: path) }
            }
            .controlSize(.small)
            if showsMarkResolved {
                Button("Mark Resolved") {
                    Task { await appState.markConflictResolved(path: path) }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.orange.opacity(0.5)).frame(height: 0.5)
        }
    }
}
