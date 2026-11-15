import Foundation
import AppKit
import CoreText

/// A caret position inside one compare pane: a diff row, and a character
/// offset into that row's text *as rendered*.
///
/// Rendered, not raw, because "show whitespace" expands tabs to their column
/// stops before the line reaches the screen — an offset into the raw line
/// would point at the wrong character in exactly the mode that exists to make
/// whitespace visible.
struct ComparePoint: Equatable, Comparable, Sendable {
    var row: Int
    var column: Int

    static func < (a: ComparePoint, b: ComparePoint) -> Bool {
        a.row == b.row ? a.column < b.column : a.row < b.row
    }
}

/// A drag selection across the rows of *one* compare pane.
///
/// One pane, because the two columns of a side-by-side diff are two different
/// documents: a selection running across the divider would produce a
/// clipboard nobody asked for, interleaving HEAD and WORKING line by line.
/// Dragging in the other pane starts a new selection there.
///
/// `anchor` is where the drag began and `focus` where it is now, so a drag
/// upwards is as ordinary as a drag downwards; `start`/`end` put them back in
/// document order for everything that reads the selection.
struct CompareSelection: Equatable, Sendable {
    var side: ComparePaneSide
    var anchor: ComparePoint
    var focus: ComparePoint

    var start: ComparePoint { min(anchor, focus) }
    var end: ComparePoint { max(anchor, focus) }

    /// A click without a drag. Selects nothing and copies nothing — it is the
    /// caret, which this view has no other use for.
    var isEmpty: Bool { anchor == focus }

    func covers(row: Int) -> Bool { row >= start.row && row <= end.row }

    /// The characters selected on `row`, given how many that row renders.
    /// Nil where the row is outside the selection or contributes no
    /// characters to it — the first row of a selection that starts at its
    /// very end, say, which contributes only its line break.
    func range(onRow row: Int, length: Int) -> Range<Int>? {
        guard covers(row: row) else { return nil }
        let lower = row == start.row ? min(max(0, start.column), length) : 0
        let upper = row == end.row ? min(max(0, end.column), length) : length
        guard lower < upper else { return nil }
        return lower..<upper
    }

    /// Whether the line break at the end of `row` is inside the selection —
    /// true for every row but the last. Rows draw it as a trailing blank
    /// cell, the way any editor shows a selected newline.
    func includesLineBreak(after row: Int) -> Bool {
        covers(row: row) && row < end.row
    }
}

/// One entry of a pane's vertical layout: the diff row drawn there, and how
/// tall it is. `row` is nil for anything that holds space without holding a
/// line — a fold marker, or a drafted block's cell on the WORKING side.
struct CompareRowMetric: Equatable, Sendable {
    let row: Int?
    let height: CGFloat
}

/// Maps a Y offset inside a pane's scrolling content back to the diff row
/// drawn at it.
///
/// Arithmetic over the row list rather than a measurement of the views: the
/// split panes pin every row to one computed height precisely so this can be
/// exact, which is the same reason block editing pins its line height. A
/// measured scheme would need a `GeometryReader` per row, and the panes draw
/// every row they display.
struct CompareRowLayout: Sendable {
    let metrics: [CompareRowMetric]

    /// The row at `y`, clamped into the content: a drag that runs off the top
    /// lands on the first row and one that runs off the bottom on the last,
    /// which is what makes dragging past the edge extend the selection rather
    /// than drop it.
    ///
    /// A `y` inside a fold marker resolves to the row above it — the marker
    /// stands for lines that are not on screen, and there is nothing there to
    /// select.
    func row(atY y: CGFloat) -> Int? {
        let drawn = metrics.compactMap(\.row)
        guard let first = drawn.first, let last = drawn.last else { return nil }
        guard y > 0 else { return first }

        var top: CGFloat = 0
        var previous: Int?
        for metric in metrics {
            let bottom = top + metric.height
            // Zero-height entries — a row the alignment hides, a block cell
            // that has been emptied — never contain a point, and fall through.
            if y < bottom {
                if let row = metric.row { return row }
                return previous ?? first
            }
            if let row = metric.row { previous = row }
            top = bottom
        }
        return last
    }
}

/// Turns an X offset inside a rendered line into a character offset.
///
/// CoreText rather than "x divided by the advance width": the panes render
/// Vietnamese diacritics, CJK and emoji, none of which occupy one monospace
/// cell, and this is the same engine `WhitespaceOverlay` measures with — so a
/// column resolved here is the column the glyph is drawn at.
enum CompareTextHitTest {

    static func column(in text: String, fontSize: CGFloat, x: CGFloat) -> Int {
        guard !text.isEmpty else { return 0 }
        guard x > 0 else { return 0 }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        let utf16 = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        guard utf16 != kCFNotFound else { return text.count }
        return characterOffset(utf16Offset: utf16, in: text)
    }

    /// CoreText counts in UTF-16; the selection counts in characters, because
    /// that is what `AttributedString` slices and what a `String` subscript
    /// takes. An offset landing inside a surrogate pair rounds down to the
    /// start of its character, which is where a caret belongs anyway.
    private static func characterOffset(utf16Offset: Int, in text: String) -> Int {
        let utf16Count = text.utf16.count
        let clamped = max(0, min(utf16Offset, utf16Count))
        guard clamped < utf16Count else { return text.count }
        guard let index = String.Index(
            String.Index(utf16Offset: clamped, in: text),
            within: text
        ) else {
            return text.count
        }
        return text.distance(from: text.startIndex, to: index)
    }
}
