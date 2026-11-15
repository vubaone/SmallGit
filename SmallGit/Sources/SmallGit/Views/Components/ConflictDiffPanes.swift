import SwiftUI

/// Three-way, line-aligned viewer used by Resolve Conflict.
///
/// Its interaction contract intentionally matches `FileCompareView`:
/// wrapping uses one row-major vertical scroller, non-wrapping panes mirror
/// both scroll axes, unchanged context can fold and expand inline, searches
/// reveal folded rows, and genuinely absent cells use `DiffAbsentHatch`.
struct ConflictDiffPanes: View {
    let oursText: String
    let baseText: String
    let theirsText: String
    let hasBase: Bool
    /// Sides the merge left with no blob at all — a modify/delete. Their
    /// column is empty on purpose, and the header says so rather than
    /// letting it look like nothing loaded.
    let deletedSides: Set<ConflictLineSide>
    let oursHighlights: [ConflictResolutionViewModel.HighlightRange]
    let baseHighlights: [ConflictResolutionViewModel.HighlightRange]
    let theirsHighlights: [ConflictResolutionViewModel.HighlightRange]
    let focusedChunkID: UUID?
    let language: SyntaxLanguage?
    let find: TextFindState
    let wrapLines: Bool
    let collapseUnchanged: Bool
    let showContext: Bool
    /// The aligned row the line inspector below is describing, outlined in
    /// all three panes because it is one row of one alignment, not three
    /// separate selections.
    let selectedRowID: Int?
    /// Reports a clicked row and the chunk it belongs to, if any. The panes
    /// own the alignment, so the row itself travels up rather than an index
    /// the parent would have to resolve against data it does not hold.
    let onSelectRow: (ConflictLineRow, UUID?) -> Void

    @State private var rows: [ConflictLineRow] = []
    @State private var syntaxLines: [ConflictLineSide: [[SyntaxToken]]] = [:]
    @State private var expandedFolds: Set<String> = []
    @StateObject private var scrollSync = SynchronizedPaneScrollGroup<ConflictLineSide>()

    @Environment(\.monoFontSize) private var monoSize

    private static let contextLineCount = 3

    init(
        oursText: String,
        baseText: String,
        theirsText: String,
        hasBase: Bool,
        deletedSides: Set<ConflictLineSide> = [],
        oursHighlights: [ConflictResolutionViewModel.HighlightRange],
        baseHighlights: [ConflictResolutionViewModel.HighlightRange],
        theirsHighlights: [ConflictResolutionViewModel.HighlightRange],
        focusedChunkID: UUID?,
        language: SyntaxLanguage?,
        find: TextFindState,
        wrapLines: Bool,
        collapseUnchanged: Bool,
        showContext: Bool,
        selectedRowID: Int?,
        onSelectRow: @escaping (ConflictLineRow, UUID?) -> Void
    ) {
        self.oursText = oursText
        self.baseText = baseText
        self.theirsText = theirsText
        self.hasBase = hasBase
        self.deletedSides = deletedSides
        self.oursHighlights = oursHighlights
        self.baseHighlights = baseHighlights
        self.theirsHighlights = theirsHighlights
        self.focusedChunkID = focusedChunkID
        self.language = language
        self.find = find
        self.wrapLines = wrapLines
        self.collapseUnchanged = collapseUnchanged
        self.showContext = showContext
        self.selectedRowID = selectedRowID
        self.onSelectRow = onSelectRow

        _rows = State(initialValue: ConflictLineDiff.compute(
            base: hasBase ? LineDiff.split(baseText) : [],
            ours: LineDiff.split(oursText),
            theirs: LineDiff.split(theirsText),
            hasBase: hasBase
        ))
        if let language {
            _syntaxLines = State(initialValue: [
                .ours: SyntaxHighlighter.highlight(document: oursText, language: language),
                .base: hasBase
                    ? SyntaxHighlighter.highlight(document: baseText, language: language)
                    : [],
                .theirs: SyntaxHighlighter.highlight(document: theirsText, language: language)
            ])
        }
    }

    private struct AlignmentInput: Hashable {
        let ours: String
        let base: String
        let theirs: String
        let hasBase: Bool
    }

    private var alignmentInput: AlignmentInput {
        AlignmentInput(
            ours: oursText,
            base: baseText,
            theirs: theirsText,
            hasBase: hasBase
        )
    }


    private var displayRows: [ConflictDiffDisplayRow] {
        guard collapseUnchanged else {
            return rows.indices.map { .row($0) }
        }
        return ConflictLineDiff.collapse(
            rows: rows,
            contextLines: showContext ? Self.contextLineCount : 0,
            expandedFolds: expandedFolds
        )
    }

    var body: some View {
        Group {
            if wrapLines {
                wrappedPanes
            } else {
                splitPanes
            }
        }
        .background(Color.bgInput)
        .task(id: alignmentInput) {
            rebuild()
        }
    }

    // MARK: - Shared headers

    private func header(for side: ConflictLineSide) -> some View {
        ComparePaneHeader(
            title: title(for: side),
            subtitle: subtitle(for: side),
            tint: tint(for: side)
        )
    }

    private func title(for side: ConflictLineSide) -> String {
        switch side {
        case .ours: "OURS"
        case .base: "BASE"
        case .theirs: "THEIRS"
        }
    }

    private func subtitle(for side: ConflictLineSide) -> String {
        if deletedSides.contains(side) {
            return side == .ours ? "deleted on this branch" : "deleted on the incoming branch"
        }
        switch side {
        case .ours: return "current branch"
        case .base: return hasBase ? "common ancestor" : "(none)"
        case .theirs: return "incoming"
        }
    }

    private func tint(for side: ConflictLineSide) -> Color {
        switch side {
        case .ours: .blue
        case .base: .gray
        case .theirs: .green
        }
    }

    private var paneSeparator: some View {
        Rectangle().fill(Color.strongBorder).frame(width: 1)
    }

    // MARK: - Wrap on: one shared vertical scroller

    private var wrappedPanes: some View {
        GeometryReader { geometry in
            let paneWidth = max(0, (geometry.size.width - 2) / 3)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    header(for: .ours).frame(width: paneWidth)
                    paneSeparator
                    header(for: .base).frame(width: paneWidth)
                    paneSeparator
                    header(for: .theirs).frame(width: paneWidth)
                }

                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(displayRows, id: \.id) { entry in
                                wrappedEntry(entry, paneWidth: paneWidth)
                                    .id(entry.id)
                            }
                        }
                    }
                    .onChange(of: focusedChunkID) { _, id in
                        scrollToFocusedChunk(id, proxy: proxy, selecting: true)
                    }
                    .onChange(of: find.current) { _, match in
                        scrollToMatch(match, proxy: proxy)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func wrappedEntry(
        _ entry: ConflictDiffDisplayRow,
        paneWidth: CGFloat
    ) -> some View {
        switch entry {
        case .row(let index):
            if rows.indices.contains(index) {
                let row = rows[index]
                HStack(alignment: .top, spacing: 0) {
                    cell(row: row, side: .ours, wrap: true, minWidth: paneWidth)
                        .frame(width: paneWidth)
                    paneSeparator
                    cell(row: row, side: .base, wrap: true, minWidth: paneWidth)
                        .frame(width: paneWidth)
                    paneSeparator
                    cell(row: row, side: .theirs, wrap: true, minWidth: paneWidth)
                        .frame(width: paneWidth)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        case .fold(_, let count):
            ConflictFoldRow(hiddenCount: count) {
                expandedFolds.insert(entry.id)
            }
            .frame(width: paneWidth * 3 + 2)
        }
    }

    // MARK: - Wrap off: three synchronized two-axis scrollers

    private var splitPanes: some View {
        GeometryReader { geometry in
            let paneWidth = max(0, (geometry.size.width - 2) / 3)
            HStack(spacing: 0) {
                splitColumn(side: .ours, paneWidth: paneWidth)
                paneSeparator
                splitColumn(side: .base, paneWidth: paneWidth)
                paneSeparator
                splitColumn(side: .theirs, paneWidth: paneWidth)
            }
        }
    }

    private func splitColumn(side: ConflictLineSide, paneWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            header(for: side)
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(displayRows, id: \.id) { entry in
                                splitEntry(
                                    entry,
                                    side: side,
                                    minWidth: max(paneWidth, geometry.size.width)
                                )
                                .id(entry.id)
                            }
                        }
                        .frame(
                            minWidth: geometry.size.width,
                            minHeight: geometry.size.height,
                            alignment: .topLeading
                        )
                        .background(EnclosingScrollViewFinder { scrollView in
                            scrollSync.register(scrollView, as: side)
                        })
                    }
                    .onChange(of: focusedChunkID) { _, id in
                        // Only the first column reports it: three panes share
                        // one alignment, and three identical selections of
                        // one row is two too many.
                        scrollToFocusedChunk(id, proxy: proxy, selecting: side == .ours)
                    }
                    .onChange(of: find.current) { _, match in
                        scrollToMatch(match, proxy: proxy)
                    }
                }
            }
        }
        .frame(width: paneWidth, alignment: .leading)
        .clipped()
    }

    @ViewBuilder
    private func splitEntry(
        _ entry: ConflictDiffDisplayRow,
        side: ConflictLineSide,
        minWidth: CGFloat
    ) -> some View {
        switch entry {
        case .row(let index):
            if rows.indices.contains(index) {
                cell(row: rows[index], side: side, wrap: false, minWidth: minWidth)
            }
        case .fold(_, let count):
            ConflictFoldHalfRow(
                hiddenCount: count,
                showLabel: side == .ours,
                minRowWidth: minWidth
            ) {
                expandedFolds.insert(entry.id)
            }
        }
    }

    // MARK: - Rows, highlighting, syntax, and search

    private func cell(
        row: ConflictLineRow,
        side: ConflictLineSide,
        wrap: Bool,
        minWidth: CGFloat
    ) -> some View {
        let cell = row.cell(for: side)
        let cellChunkID = cell.flatMap { chunkID(side: side, line: $0.lineNumber) }
        let rowChunk = chunkID(for: row)
        return ConflictDiffCell(
            side: side,
            row: row,
            cell: cell,
            cellChunkID: cellChunkID,
            rowChunkID: rowChunk,
            isSelected: row.id == selectedRowID,
            focusedChunkID: focusedChunkID,
            syntax: syntax(for: cell?.lineNumber, side: side),
            searchMatches: cell.map {
                find.matches(onLine: $0.lineNumber - 1, column: side.rawValue)
            } ?? [],
            currentMatch: find.current?.column == side.rawValue ? find.current : nil,
            wrapLines: wrap,
            minRowWidth: minWidth
        )
        .contentShape(Rectangle())
        // A click asks "what happens to this line?" — the inspector's own
        // question — so it selects the row, from whichever pane the eye was
        // already on.
        .onTapGesture { onSelectRow(row, rowChunk) }
    }

    private func ranges(for side: ConflictLineSide) -> [ConflictResolutionViewModel.HighlightRange] {
        switch side {
        case .ours: oursHighlights
        case .base: baseHighlights
        case .theirs: theirsHighlights
        }
    }

    private func chunkID(side: ConflictLineSide, line: Int) -> UUID? {
        ranges(for: side).first {
            line >= $0.startLine && line <= $0.endLine
        }?.chunkID
    }

    private func chunkID(for row: ConflictLineRow) -> UUID? {
        for side in ConflictLineSide.allCases {
            if let line = row.cell(for: side)?.lineNumber,
               let id = chunkID(side: side, line: line) {
                return id
            }
        }
        return nil
    }

    private func syntax(for line: Int?, side: ConflictLineSide) -> [SyntaxToken] {
        guard let line, line >= 1,
              let document = syntaxLines[side], line <= document.count
        else { return [] }
        return document[line - 1]
    }

    private func rowIndex(for match: TextSearchMatch) -> Int? {
        guard let side = ConflictLineSide(rawValue: match.column) else { return nil }
        return rows.firstIndex {
            $0.cell(for: side)?.lineNumber == match.line + 1
        }
    }

    private func rowIndex(for chunkID: UUID) -> Int? {
        rows.firstIndex { self.chunkID(for: $0) == chunkID }
    }

    private func reveal(row index: Int) {
        guard let fold = displayRows.first(where: { entry in
            guard case .fold(let start, let count) = entry else { return false }
            return index >= start && index < start + count
        }) else { return }
        expandedFolds.insert(fold.id)
    }

    private func scrollToFocusedChunk(
        _ chunkID: UUID?,
        proxy: ScrollViewProxy,
        selecting: Bool
    ) {
        guard let chunkID, let index = rowIndex(for: chunkID) else { return }
        reveal(row: index)
        // Moving to a chunk points the inspector at its first line, so the
        // panel below is never blank right after Next or a click in the
        // chunk list.
        //
        // Unless the selection is already inside that chunk: clicking a line
        // focuses its chunk too, and without this a click on the third line
        // of an unfocused chunk would be answered about the first one.
        let selectionIsInChunk = rows
            .first { $0.id == selectedRowID }
            .map { self.chunkID(for: $0) == chunkID } ?? false
        if selecting, !selectionIsInChunk, rows.indices.contains(index) {
            onSelectRow(rows[index], chunkID)
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(ConflictDiffDisplayRow.row(index).id, anchor: .top)
        }
    }

    private func scrollToMatch(
        _ match: TextSearchMatch?,
        proxy: ScrollViewProxy
    ) {
        guard let match, let index = rowIndex(for: match) else { return }
        reveal(row: index)
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(ConflictDiffDisplayRow.row(index).id, anchor: .center)
        }
    }

    private func rebuild() {
        let baseLines = hasBase ? LineDiff.split(baseText) : []
        rows = ConflictLineDiff.compute(
            base: baseLines,
            ours: LineDiff.split(oursText),
            theirs: LineDiff.split(theirsText),
            hasBase: hasBase
        )
        expandedFolds.removeAll()

        guard let language else {
            syntaxLines = [:]
            return
        }
        syntaxLines = [
            .ours: SyntaxHighlighter.highlight(document: oursText, language: language),
            .base: hasBase
                ? SyntaxHighlighter.highlight(document: baseText, language: language)
                : [],
            .theirs: SyntaxHighlighter.highlight(document: theirsText, language: language)
        ]
    }
}

private struct ConflictDiffCell: View {
    let side: ConflictLineSide
    let row: ConflictLineRow
    let cell: ConflictLineCell?
    let cellChunkID: UUID?
    let rowChunkID: UUID?
    let isSelected: Bool
    let focusedChunkID: UUID?
    let syntax: [SyntaxToken]
    let searchMatches: [TextSearchMatch]
    let currentMatch: TextSearchMatch?
    let wrapLines: Bool
    let minRowWidth: CGFloat

    @Environment(\.monoFontSize) private var monoSize

    private static let gutterWidth: CGFloat = 44

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(cell.map { String($0.lineNumber) } ?? "")
                .font(.mono(size: max(9, monoSize - 2)))
                .foregroundStyle(Color.textDisabled)
                .frame(width: Self.gutterWidth, alignment: .trailing)
                .padding(.trailing, 4)
                .padding(.top, 2)
                .frame(maxHeight: .infinity, alignment: .topTrailing)
                .background(Color.bgPanelHeader.opacity(0.7))
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(gutterAccent)
                        .frame(width: 2)
                }

            ZStack(alignment: .topLeading) {
                cellBackground
                if let cell {
                    SpanText(
                        spans: [DiffSpan(text: cell.text, kind: .same)],
                        syntax: syntax,
                        searchMatches: searchMatches,
                        currentMatch: currentMatch,
                        fontSize: monoSize,
                        changeBackground: side == .theirs
                            ? Color.diffAddWordBg
                            : Color.diffDelWordBg,
                        wrapLines: wrapLines,
                        // Selectable only once the row is selected. A text
                        // view that can be selected swallows the click that
                        // lands on it, so with this always on, clicking a
                        // line — the obvious way to ask about it — did
                        // nothing unless the pointer happened to miss the
                        // text. The first click picks the row; the text is
                        // there to select on the next one.
                        selectable: isSelected
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                } else {
                    Text(" ")
                        .font(.mono(size: monoSize))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                }
            }
            .frame(
                minWidth: max(0, minRowWidth - (Self.gutterWidth + 6)),
                maxWidth: wrapLines ? .infinity : nil,
                minHeight: monoRowHeight(for: monoSize),
                alignment: .topLeading
            )
        }
        .frame(minWidth: minRowWidth, alignment: .leading)
        // Outlined rather than filled: the fills here already mean something
        // — conflict region, focused chunk, changed line — and a fourth one
        // would be a fourth thing to decode.
        .overlay {
            if isSelected {
                Rectangle()
                    .strokeBorder(Color.accentBlue.opacity(0.9), lineWidth: 1)
            }
        }
        // Non-wrapped rows stay exactly one code row tall. Wrapped rows are
        // allowed to accept the HStack's tallest-cell height so all three
        // backgrounds and gutters cover the same aligned block.
        .fixedSize(horizontal: false, vertical: !wrapLines)
    }

    @ViewBuilder
    private var cellBackground: some View {
        if cell == nil {
            ZStack {
                if rowChunkID == focusedChunkID, rowChunkID != nil {
                    Color.conflictHighlightFocused
                }
                DiffAbsentHatch()
            }
        } else if let cellChunkID {
            cellChunkID == focusedChunkID
                ? Color.conflictHighlightFocused
                : Color.conflictHighlight
        } else if row.isChange {
            switch side {
            case .ours: Color.diffDelBg.opacity(0.45)
            case .base: Color.clear
            case .theirs: Color.diffAddBg.opacity(0.45)
            }
        } else {
            Color.clear
        }
    }

    private var gutterAccent: Color {
        if let cellChunkID {
            return cellChunkID == focusedChunkID
                ? Color.orange.opacity(0.9)
                : Color.orange.opacity(0.45)
        }
        guard row.isChange, cell != nil else { return .clear }
        switch side {
        case .ours: return Color.diffDelText.opacity(0.7)
        case .base: return .clear
        case .theirs: return Color.diffAddText.opacity(0.7)
        }
    }
}

private struct ConflictFoldRow: View {
    let hiddenCount: Int
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down.circle")
                Text("\(hiddenCount) unchanged line\(hiddenCount == 1 ? "" : "s") hidden")
                Spacer()
            }
            .scaledFont(11)
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bgPanelHeader.opacity(0.7))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.borderColor).frame(height: 0.5)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.borderColor).frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the \(hiddenCount) hidden lines inline")
    }
}

private struct ConflictFoldHalfRow: View {
    let hiddenCount: Int
    let showLabel: Bool
    let minRowWidth: CGFloat
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down.circle")
                    .scaledFont(11)
                if showLabel {
                    Text("\(hiddenCount) unchanged line\(hiddenCount == 1 ? "" : "s") hidden")
                        .scaledFont(11)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: minRowWidth, alignment: .leading)
            .background(Color.bgPanelHeader.opacity(0.7))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.borderColor).frame(height: 0.5)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.borderColor).frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the \(hiddenCount) hidden lines inline")
    }
}
