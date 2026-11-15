import SwiftUI

extension DiffLineType {
    // Main-actor because the add/remove colours are user-settable and read
    // from `DiffPalette` at draw time. Every caller is a view body already.
    @MainActor var backgroundColor: Color {
        switch self {
        case .add:     return Color.diffAddBg
        case .del:     return Color.diffDelBg
        case .context: return .clear
        case .empty:   return Color.diffEmptyBg
        }
    }

    @MainActor var textColor: Color {
        switch self {
        case .add:     return Color.diffAddText
        case .del:     return Color.diffDelText
        case .context: return Color.textPrimary
        case .empty:   return .clear
        }
    }

    var marker: String {
        switch self {
        case .add:     return "+"
        case .del:     return "-"
        case .context: return " "
        case .empty:   return " "
        }
    }
}

struct DiffLineView: View {
    let line: DiffLine
    let side: DiffSide
    /// Drawn behind the row when the user has multi-selected this line
    /// via click / cmd-click / shift-click. Used by the diff context
    /// menu's "Stage Selection / Unstage Selection / Discard Selection"
    /// actions.
    var selected: Bool = false
    /// Syntax-colour the content when set. Off by default so the main diff
    /// panel keeps its solid red/green lines, which is what makes a long
    /// unified diff scannable at a glance.
    ///
    /// With it on, add/del is carried by the row background and the `+` / `-`
    /// marker instead of by the text colour — the same division GitHub and
    /// VS Code use, and the only one available once the text colour is
    /// spoken for.
    ///
    /// Highlighting here is per line, with no knowledge of the lines around
    /// it: callers that render hunks don't have the file, so a `/* … */`
    /// opened above the hunk reads as ordinary code. `FileCompareView`, which
    /// does have both documents, scans them whole instead.
    var syntax: SyntaxLanguage? = nil
    /// Find-bar hits on this line, and the one the bar is sitting on.
    var searchMatches: [TextSearchMatch] = []
    var currentMatch: TextSearchMatch?
    @Environment(\.monoFontSize) private var monoFontSize
    @Environment(\.showWhitespace) private var showWhitespace
    /// Set inside a `DiffHorizontalScroll`: the text is laid out at full
    /// length and slid left by this much instead of being cut off.
    @Environment(\.diffHorizontalOffset) private var horizontalOffset

    /// Width of the line-number gutter and the `+` / `-` cell — the part of
    /// a row that stays put while its text scrolls sideways.
    static func leadingWidth(fontSize: CGFloat) -> CGFloat {
        max(34, fontSize * 3.5) + 12 + max(12, fontSize)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(lineNumberText)
                .frame(width: max(34, monoFontSize * 3.5), alignment: .trailing)
                .padding(.horizontal, 6)
                .foregroundStyle(Color.textDisabled)
                .background(Color.bgPanelHeader)
            Text(line.type.marker)
                .frame(width: max(12, monoFontSize), alignment: .center)
                .foregroundStyle(line.type.textColor)
                .background(line.type.backgroundColor)
            textCell
                .foregroundStyle(line.type.textColor)
                // Same hatching the compare window uses for a side with no
                // counterpart — the side-by-side layout here poses the
                // reader the identical question.
                .background {
                    if line.type == .empty {
                        DiffAbsentHatch()
                    } else {
                        line.type.backgroundColor
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
        }
        .frame(height: monoRowHeight(for: monoFontSize))
        .font(.mono(size: monoFontSize))
        .overlay(
            Rectangle()
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 1)
        )
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
    }

    /// The text at full length and slid by the shared offset when the diff
    /// scrolls sideways, or cut to the column with an ellipsis when it
    /// doesn't.
    @ViewBuilder
    private var textCell: some View {
        if let horizontalOffset {
            content
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .offset(x: -horizontalOffset)
                // Accept the column's proposed width even when the text's
                // intrinsic width is larger. maxWidth alone keeps that
                // intrinsic minimum, so clipping still lets the left line
                // paint across the divider and over the right column.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        }
    }

    /// The `.foregroundStyle` applied outside is the fallback: when syntax
    /// colouring is on, every run carries its own colour and overrides it.
    @ViewBuilder
    private var content: some View {
        // The plain path is the fast one, but it can't show glyphs — so
        // revealing whitespace routes every line through the attributed
        // builder the same way syntax colouring and a find hit do.
        if syntax != nil || !searchMatches.isEmpty || showWhitespace {
            Text(attributed)
                .whitespaceMarkers(revealed, fontSize: monoFontSize)
        } else {
            Text(line.content)
        }
    }

    /// Marker positions for this line, or nil when whitespace isn't being
    /// revealed. The text they're measured against is the same one the
    /// runs above spell out.
    private var revealed: RevealedLine? {
        showWhitespace ? CompareTextLayout.revealed(line.content) : nil
    }

    /// There is no word-level diff in a hunk-based view, so the whole line is
    /// handed over as a single unchanged span and only the syntax and search
    /// layers do any cutting.
    private var attributed: AttributedString {
        let tokens = syntax.map { SyntaxHighlighter.highlight(line: line.content, language: $0) } ?? []
        let runs = CompareTextLayout.runs(
            spans: [DiffSpan(text: line.content, kind: .same)],
            syntax: tokens,
            searchMatches: searchMatches,
            currentMatch: currentMatch,
            revealWhitespace: showWhitespace
        )

        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            // Explicit attribute key rather than the `.foregroundColor = …`
            // dynamic member, which forms a non-Sendable KeyPath under strict
            // concurrency. Same reason as in `FileCompareView`'s SpanText.
            // Without a language the run kind is `.plain`, whose colour would
            // override the row's add/delete tint — so leave the foreground
            // alone in that case and let `.foregroundStyle` outside apply.
            if run.isWhitespace {
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color.whitespaceGlyph
            } else if syntax != nil {
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = run.kind.color
            }
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

    private var lineNumberText: String {
        switch side {
        case .old: return line.oldLineNumber.map(String.init) ?? ""
        case .new: return line.newLineNumber.map(String.init) ?? ""
        }
    }
}
