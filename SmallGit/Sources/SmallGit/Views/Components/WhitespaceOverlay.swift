import SwiftUI
import AppKit
import CoreText

/// Paints the whitespace markers over a line of monospaced text: a middle
/// dot in each space, an arrow at each tab, a pilcrow past the end.
///
/// They are painted rather than written into the string because a `Text`
/// copies exactly the characters it holds. With the glyphs inline, dragging
/// a line out of a diff produced `wait·for·check·avatar·can·like·or·not`,
/// which cannot be pasted into a search box — the mode is for *seeing*
/// whitespace, not for changing what the text is.
///
/// Positions come from CoreText rather than from a column count times an
/// advance width: the same layout engine SwiftUI's `Text` draws with, so
/// the markers stay put through Vietnamese diacritics, CJK, and anything
/// else whose cell isn't one advance wide.
struct WhitespaceOverlay: View {
    /// The line exactly as rendered — `CompareTextLayout.revealed(_:).text`,
    /// with tabs already expanded.
    let text: String
    let marks: [WhitespaceMark]
    let fontSize: CGFloat

    /// Radius of the dot drawn inside a space. Small enough to read as a
    /// marker rather than as a character.
    private static let dotRadius: CGFloat = 1.1

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(in: context, size: size)
        }
        // Decoration only: every click belongs to the text underneath,
        // including the drag that starts a selection.
        .allowsHitTesting(false)
    }

    private var font: NSFont {
        .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// CoreText's own layout of this line — the same engine SwiftUI's
    /// `Text` draws with, so an offset here is where the character is.
    private func makeLine() -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        guard !marks.isEmpty else { return }
        let line = makeLine()
        let midY = size.height / 2
        let color = Color.whitespaceGlyph

        for mark in marks {
            let x = CTLineGetOffsetForStringIndex(line, mark.utf16Offset, nil)
            // A wrapped line lays out over several visual rows while this
            // is one row's worth of canvas; markers past the fold fall
            // outside and are simply not drawn.
            guard x <= size.width else { continue }

            switch mark.kind {
            case .space:
                let next = CTLineGetOffsetForStringIndex(line, mark.utf16Offset + 1, nil)
                let centre = x + max(0, next - x) / 2
                let r = Self.dotRadius
                context.fill(
                    Path(ellipseIn: CGRect(x: centre - r, y: midY - r, width: r * 2, height: r * 2)),
                    with: .color(color)
                )
            case .tab:
                draw(WhitespaceGlyph.tab, at: x, midY: midY, in: context, color: color)
            case .lineEnd:
                draw(WhitespaceGlyph.lineEnd, at: x, midY: midY, in: context, color: color)
            }
        }
    }

    private func draw(
        _ character: Character,
        at x: CGFloat,
        midY: CGFloat,
        in context: GraphicsContext,
        color: Color
    ) {
        let glyph = Text(String(character))
            .font(.mono(size: fontSize))
            .foregroundStyle(color)
        context.draw(context.resolve(glyph), at: CGPoint(x: x, y: midY), anchor: .leading)
    }
}

extension View {
    /// Paint `revealed`'s markers over this text. A no-op when whitespace
    /// isn't being revealed, so callers can apply it unconditionally.
    @ViewBuilder
    func whitespaceMarkers(_ revealed: RevealedLine?, fontSize: CGFloat) -> some View {
        if let revealed, !revealed.marks.isEmpty {
            // The trailing cell is where the end-of-line marker goes. An
            // overlay is sized by what it covers, so without it the
            // canvas ends at the last character and the pilcrow — drawn
            // just past that — is clipped away.
            self
                .padding(.trailing, fontSize)
                .overlay(alignment: .leading) {
                    WhitespaceOverlay(
                        text: revealed.text,
                        marks: revealed.marks,
                        fontSize: fontSize
                    )
                }
        } else {
            self
        }
    }
}
