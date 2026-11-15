import SwiftUI
import AppKit

/// One column of a side-by-side compare view: colored title row on top,
/// arbitrary content below (typically a `ReadOnlyTextPane` or
/// `EditableTextPane`). Shared between the 3-pane conflict resolver
/// and the 2-pane "compare any file" view so both look identical.
struct ComparePane<Content: View>: View {
    let title: String
    let subtitle: String
    let tint: Color
    let content: Content

    init(
        title: String,
        subtitle: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            ComparePaneHeader(title: title, subtitle: subtitle, tint: tint)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.bgInput)
        }
    }
}

/// Shared heading for every compare/resolver code column.
struct ComparePaneHeader: View {
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(title)
                .scaledFont(10, weight: .semibold)
                .foregroundStyle(Color.textPrimary)
            Text(subtitle)
                .scaledFont(9)
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.bgPanelHeader)
    }
}

/// Read-only monospaced text pane. Wraps a `ScrollView + Text` so the
/// content can grow horizontally without word-wrap mangling code, and
/// the text stays selectable for copy-paste.
struct ReadOnlyTextPane: View {
    let text: String
    @Environment(\.monoFontSize) private var monoSize

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.mono(size: monoSize))
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}

/// Read-only monospaced pane that draws each line as its own row so
/// individual lines can carry a background color. Used by the conflict
/// resolver to wash conflict regions in pink, the way Beyond Compare
/// does. Within a highlighted region the line belonging to the
/// focused chunk gets a brighter shade so it stands out against any
/// other conflicts in the same file.
struct HighlightedTextPane: View {
    let text: String
    /// 1-based inclusive line ranges to wash with the conflict color.
    let highlights: [ConflictResolutionViewModel.HighlightRange]
    /// When set, the chunk whose ID matches gets the brighter shade.
    let focusedChunkID: UUID?
    /// When set, `ScrollViewReader` scrolls the pane to put this
    /// chunk's first highlighted line near the top.
    let scrollToChunkID: UUID?
    /// Syntax-colour the source when set. Composes with the conflict wash
    /// rather than competing with it: the wash is a background, syntax is a
    /// foreground, exactly as in the compare views.
    var syntax: SyntaxLanguage? = nil
    /// Find-bar state, and which of its columns this pane is.
    var find: TextFindState?
    var findColumn: Int = 0

    /// Per-line tokens for `text`, recomputed only when the text changes.
    ///
    /// Held in state rather than computed in `body` because each of these
    /// panes holds a whole file: scanning it on every render — and this view
    /// re-renders whenever the focused chunk moves — would put a full-file
    /// pass behind every click.
    @State private var syntaxLines: [[SyntaxToken]] = []

    @Environment(\.monoFontSize) private var monoSize

    var body: some View {
        let rows = displayRows
        let rowMinWidth = estimatedRowWidth(lines: lines)
        ScrollViewReader { proxy in
            // GeometryReader supplies the viewport height so short content can
            // be pinned to the top. A *two-axis* ScrollView centres content
            // smaller than its viewport — unlike a single-axis one — which
            // left a small file's lines floating in the middle of the pane,
            // looking like the view had scrolled somewhere odd. Same fix as
            // the compare view's split panes.
            GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.indices, id: \.self) { i in
                        row(rows[i], minWidth: rowMinWidth)
                    }
                }
                .padding(.vertical, 8)
                // Both axes, not just height. A two-axis `ScrollView`
                // centres content smaller than its viewport, so a file whose
                // longest line is narrower than the pane had its text floating
                // in the middle of the column — which reads as a rendering
                // fault, and makes the three panes impossible to compare line
                // for line. Fixing only `minHeight` left exactly that.
                .frame(
                    minWidth: geo.size.width,
                    minHeight: geo.size.height,
                    alignment: .topLeading
                )
            }
            .background(Color.bgInput)
            .onChange(of: scrollToChunkID) { _, newValue in
                guard let id = newValue,
                      let h = highlights.first(where: { $0.chunkID == id }) else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(h.startLine, anchor: .top)
                }
            }
            // Keyed on the text so switching conflicted files rescans, and a
            // pane whose content hasn't moved doesn't.
            .task(id: text) { rescanSyntax() }
            // Scroll this pane when the find bar lands on one of *its* hits.
            .onChange(of: find?.current) { _, match in
                guard let match, match.column == findColumn else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(match.line + 1, anchor: .center)
                }
            }
            }
        }
    }

    private func rescanSyntax() {
        guard let syntax else {
            syntaxLines = []
            return
        }
        // Whole document, not line by line: these panes hold complete file
        // versions, so a block comment or a multi-line string is coloured
        // across every line it spans.
        syntaxLines = SyntaxHighlighter.highlight(document: text, language: syntax)
    }

    private func tokens(forLine lineNumber: Int) -> [SyntaxToken] {
        guard lineNumber >= 1, lineNumber <= syntaxLines.count else { return [] }
        return syntaxLines[lineNumber - 1]
    }

    /// One line as an attributed run. Falls back to plain text when the file
    /// has no known language, which is what every pane did before.
    private func attributed(_ line: String, lineNumber: Int) -> AttributedString {
        var out = AttributedString()
        let matches = find?.matches(onLine: lineNumber - 1, column: findColumn) ?? []
        let current = find?.current
        for run in CompareTextLayout.runs(
            spans: [DiffSpan(text: line, kind: .same)],
            syntax: tokens(forLine: lineNumber),
            searchMatches: matches,
            currentMatch: current?.column == findColumn ? current : nil
        ) {
            var piece = AttributedString(run.text)
            // Explicit attribute key rather than the dynamic-member setter,
            // which forms a non-Sendable KeyPath under strict concurrency.
            piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = run.kind.color
            switch run.search {
            case .current:
                piece[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color.searchCurrentBg
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color.black
            case .match:
                piece[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color.searchMatchBg
            case nil:
                break
            }
            out.append(piece)
        }
        return out
    }

    /// One row in the rendered pane — either a real source line or a
    /// padding row inserted to keep the conflict region aligned with
    /// the tallest side's block.
    private enum DisplayRow {
        case line(text: String, lineNumber: Int, highlight: ConflictResolutionViewModel.HighlightRange?)
        case padding(highlight: ConflictResolutionViewModel.HighlightRange)
    }

    /// Walks the source lines and interleaves trailing-padding rows
    /// where a highlighted region needs more height to match its
    /// siblings. Building the list eagerly here lets `LazyVStack`
    /// drive `ForEach` over a single homogeneous index range.
    private var displayRows: [DisplayRow] {
        var out: [DisplayRow] = []
        let renderedLines = lines
        for (i, text) in renderedLines.enumerated() {
            let lineNumber = i + 1
            let hl = highlight(for: lineNumber)
            out.append(.line(text: text, lineNumber: lineNumber, highlight: hl))
            if let hl, hl.endLine == lineNumber, hl.trailingPadding > 0 {
                for _ in 0..<hl.trailingPadding {
                    out.append(.padding(highlight: hl))
                }
            }
        }
        return out
    }

    @ViewBuilder
    private func row(_ row: DisplayRow, minWidth: CGFloat) -> some View {
        switch row {
        case .line(let text, let lineNumber, let hl):
            HStack(spacing: 0) {
                Text(text.isEmpty ? AttributedString(" ") : attributed(text, lineNumber: lineNumber))
                    .font(.mono(size: monoSize))
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                Spacer(minLength: 0)
            }
            .frame(minWidth: minWidth, alignment: .leading)
            .background(background(for: hl))
            .id(lineNumber)

        case .padding(let hl):
            HStack(spacing: 0) {
                // Single space keeps the row at the same metric
                // height as a content row — the diagonal hatch is
                // drawn behind it via `paddingBackground`.
                Text(" ")
                    .font(.mono(size: monoSize))
                    .padding(.horizontal, 8)
                Spacer(minLength: 0)
            }
            .frame(minWidth: minWidth, alignment: .leading)
            .background(paddingBackground(for: hl))
        }
    }

    private var lines: [String] {
        text.components(separatedBy: "\n")
    }

    /// Width to reserve for every row so the highlight wash reaches
    /// the right edge of the widest line. SF Mono's advance width is
    /// ~0.6× the point size; we overshoot slightly so the wash never
    /// stops exactly at the last glyph.
    private func estimatedRowWidth(lines: [String]) -> CGFloat {
        let maxLineLength = lines.map(\.count).max() ?? 0
        let advance = monoSize * 0.62
        return CGFloat(maxLineLength) * advance + 32
    }

    private func highlight(for line: Int) -> ConflictResolutionViewModel.HighlightRange? {
        // Most files have a handful of chunks at most, so a linear
        // scan is cheap enough — avoids the complexity of building an
        // interval tree we'd otherwise need to invalidate.
        highlights.first { line >= $0.startLine && line <= $0.endLine }
    }

    @ViewBuilder
    private func background(for hl: ConflictResolutionViewModel.HighlightRange?) -> some View {
        if let hl {
            (hl.chunkID == focusedChunkID
             ? Color.conflictHighlightFocused
             : Color.conflictHighlight)
        } else {
            Color.clear
        }
    }

    /// Diagonal-hatch wash for padding rows — visually "this side has
    /// nothing here, the row exists only to align with the taller
    /// side." Beyond Compare uses the same pattern for missing-content
    /// rows. Tinted with the focused-chunk shade so the eye reads the
    /// entire conflict block (real + padding) as one unit.
    @ViewBuilder
    private func paddingBackground(for hl: ConflictResolutionViewModel.HighlightRange) -> some View {
        let base = hl.chunkID == focusedChunkID
            ? Color.conflictHighlightFocused
            : Color.conflictHighlight
        ZStack {
            base
            DiagonalHatch()
                .stroke(Color.textDisabled.opacity(0.5), lineWidth: 0.6)
        }
    }
}

/// Cheap diagonal-stripe shape — used as a "missing content" marker
/// in conflict pane padding rows. Each stripe is 5pt of slope; the
/// pattern repeats across whatever rect it's drawn into.
private struct DiagonalHatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing: CGFloat = 5
        let diagonal = rect.width + rect.height
        var x = -rect.height
        while x < diagonal {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.height))
            x += spacing
        }
        return path
    }
}

/// Editable monospaced text pane. Driven by a binding so the parent
/// view (or view model) owns the buffer that gets written back to disk.
///
/// An `NSTextView` rather than SwiftUI's `TextEditor`, for two reasons:
///
/// - `TextEditor` binds to a `String` on macOS 14 — attributed text arrived
///   in 15 — so syntax colouring is simply not expressible through it, and
///   this is the pane where the merge is actually written.
/// - `TextEditor` inherits AppKit's automatic substitutions. In a pane whose
///   entire contents are source code, having the system rewrite `"` as a
///   typographic quote is not a cosmetic issue; it silently produces code
///   that doesn't compile. They are all switched off below.
struct EditableTextPane: NSViewRepresentable {
    @Binding var text: String
    var syntax: SyntaxLanguage? = nil
    // Not private: the Coordinator reads it when a debounced restyle fires.
    @Environment(\.monoFontSize) var monoSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        // AppKit's own find bar, which an editor should have: ⌘F inside this
        // pane brings up find-and-replace, which the app's read-only find bar
        // deliberately doesn't offer.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.insertionPointColor = Palette.textPrimary
        textView.string = text

        context.coordinator.highlight(textView, syntax: syntax, fontSize: monoSize)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        // Only touch the buffer when the change came from outside — a "Take
        // Ours", an undo in the view model, a different file. Reassigning it
        // while the user is typing would drop the selection and clear undo.
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let clamped = NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0
            )
            textView.setSelectedRange(clamped)
            context.coordinator.highlight(textView, syntax: syntax, fontSize: monoSize)
        } else if context.coordinator.needsRestyle(syntax: syntax, fontSize: monoSize) {
            context.coordinator.highlight(textView, syntax: syntax, fontSize: monoSize)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditableTextPane
        private var lastSyntax: SyntaxLanguage??
        private var lastFontSize: CGFloat?
        private var restyleWork: DispatchWorkItem?

        init(_ parent: EditableTextPane) {
            self.parent = parent
        }

        func needsRestyle(syntax: SyntaxLanguage?, fontSize: CGFloat) -> Bool {
            lastSyntax != .some(syntax) || lastFontSize != fontSize
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string

            // Re-colouring rescans the document, so doing it per keystroke
            // would put a full pass between the key and the glyph. Debounced:
            // the text stays plain for a moment while typing and settles into
            // colour when the user pauses.
            restyleWork?.cancel()
            let syntax = parent.syntax
            let fontSize = parent.monoSize
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.highlight(textView, syntax: syntax, fontSize: fontSize)
            }
            restyleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        /// Applies font and syntax colour to the whole document.
        ///
        /// Attribute-only changes: they do not register with the undo manager
        /// and do not move the insertion point, so this is safe to run under
        /// the user's cursor.
        func highlight(_ textView: NSTextView, syntax: SyntaxLanguage?, fontSize: CGFloat) {
            guard let storage = textView.textStorage else { return }
            lastSyntax = .some(syntax)
            lastFontSize = fontSize

            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let full = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.setAttributes(
                [.font: font, .foregroundColor: Palette.textPrimary],
                range: full
            )
            if let syntax {
                applySyntax(syntax, to: storage, text: textView.string)
            }
            storage.endEditing()
        }

        private func applySyntax(_ syntax: SyntaxLanguage, to storage: NSTextStorage, text: String) {
            let lines = text.components(separatedBy: "\n")
            let perLine = SyntaxHighlighter.highlight(document: text, language: syntax)
            let starts = SyntaxTextRanges.lineStarts(of: lines)

            for (index, line) in lines.enumerated() {
                guard index < perLine.count, index < starts.count else { continue }
                for styled in SyntaxTextRanges.utf16Ranges(
                    line: line, tokens: perLine[index], lineStart: starts[index]
                ) {
                    guard NSMaxRange(styled.range) <= storage.length else { continue }
                    storage.addAttribute(
                        .foregroundColor,
                        value: styled.kind.nsColor,
                        range: styled.range
                    )
                }
            }
        }
    }
}
