import XCTest
@testable import SmallGit

/// Covers the arithmetic behind dragging across the rows of a compare pane.
///
/// The failure mode here is not a crash: it is a selection that highlights
/// one set of lines and copies another, which looks right on screen and is
/// wrong in the clipboard. So the row-range maths, the Y hit-testing and the
/// CoreText column lookup are each pinned separately.
final class CompareSelectionTests: XCTestCase {

    private func selection(
        from: (Int, Int),
        to: (Int, Int),
        side: ComparePaneSide = .left
    ) -> CompareSelection {
        CompareSelection(
            side: side,
            anchor: ComparePoint(row: from.0, column: from.1),
            focus: ComparePoint(row: to.0, column: to.1)
        )
    }

    // MARK: - Ordering

    /// A drag upwards has to select exactly what the same drag downwards
    /// does — the anchor is where the mouse went down, not where the
    /// selection starts.
    func testDraggingUpwardsSelectsTheSameRange() {
        let down = selection(from: (2, 3), to: (5, 7))
        let up = selection(from: (5, 7), to: (2, 3))
        XCTAssertEqual(down.start, up.start)
        XCTAssertEqual(down.end, up.end)
        XCTAssertEqual(up.start, ComparePoint(row: 2, column: 3))
        XCTAssertEqual(up.end, ComparePoint(row: 5, column: 7))
    }

    func testClickWithoutMovementSelectsNothing() {
        XCTAssertTrue(selection(from: (4, 2), to: (4, 2)).isEmpty)
        XCTAssertFalse(selection(from: (4, 2), to: (4, 3)).isEmpty)
    }

    // MARK: - Per-row ranges

    /// The shape every multi-row selection has: partial at both ends, whole
    /// lines in between.
    func testMiddleRowsTakeTheWholeLine() {
        let sel = selection(from: (1, 4), to: (3, 2))
        XCTAssertEqual(sel.range(onRow: 1, length: 10), 4..<10)
        XCTAssertEqual(sel.range(onRow: 2, length: 10), 0..<10)
        XCTAssertEqual(sel.range(onRow: 3, length: 10), 0..<2)
        XCTAssertNil(sel.range(onRow: 0, length: 10))
        XCTAssertNil(sel.range(onRow: 4, length: 10))
    }

    /// Dragging left-to-right inside one line is still the common case, and
    /// must not pick up anything of the rows around it.
    func testSingleRowSelectionStaysOnItsRow() {
        let sel = selection(from: (7, 2), to: (7, 6))
        XCTAssertEqual(sel.range(onRow: 7, length: 20), 2..<6)
        XCTAssertNil(sel.range(onRow: 6, length: 20))
        XCTAssertNil(sel.range(onRow: 8, length: 20))
    }

    /// Columns come from a hit test against text that may since have been
    /// re-rendered shorter — a clamp rather than a trap.
    func testColumnsPastTheEndOfTheLineClamp() {
        let sel = selection(from: (1, 0), to: (1, 99))
        XCTAssertEqual(sel.range(onRow: 1, length: 4), 0..<4)
    }

    /// A row the selection touches but takes no characters from — it started
    /// at the very end of that line — contributes only its line break.
    func testRowContributingNoCharactersHasNoRange() {
        let sel = selection(from: (1, 10), to: (2, 3))
        XCTAssertNil(sel.range(onRow: 1, length: 10))
        XCTAssertTrue(sel.includesLineBreak(after: 1))
    }

    func testOnlyTheLastRowExcludesItsLineBreak() {
        let sel = selection(from: (1, 0), to: (3, 4))
        XCTAssertTrue(sel.includesLineBreak(after: 1))
        XCTAssertTrue(sel.includesLineBreak(after: 2))
        XCTAssertFalse(sel.includesLineBreak(after: 3))
        XCTAssertFalse(sel.includesLineBreak(after: 4))
    }

    // MARK: - Y hit-testing

    private func layout(_ metrics: [(Int?, CGFloat)]) -> CompareRowLayout {
        CompareRowLayout(metrics: metrics.map { CompareRowMetric(row: $0.0, height: $0.1) })
    }

    func testRowAtYWalksUniformRows() {
        let rows = layout((0..<5).map { ($0, CGFloat(18)) })
        XCTAssertEqual(rows.row(atY: 0), 0)
        XCTAssertEqual(rows.row(atY: 17.9), 0)
        XCTAssertEqual(rows.row(atY: 18), 1)
        XCTAssertEqual(rows.row(atY: 71), 3)
    }

    /// Drag off the top or the bottom and the selection extends to the end
    /// of the pane rather than stopping — otherwise a drag that overshoots
    /// silently drops the last rows.
    func testDragPastEitherEndClampsToTheEdgeRows() {
        let rows = layout((0..<3).map { ($0, CGFloat(18)) })
        XCTAssertEqual(rows.row(atY: -40), 0)
        XCTAssertEqual(rows.row(atY: 0), 0)
        XCTAssertEqual(rows.row(atY: 9_000), 2)
    }

    /// A fold marker stands for lines that are not on screen. Landing in one
    /// resolves to the row above it, so the selection stops at the last line
    /// the user can actually see.
    func testFoldMarkersResolveToTheRowAbove() {
        let rows = layout([(0, 18), (1, 18), (nil, 30), (2, 18)])
        XCTAssertEqual(rows.row(atY: 40), 1)
        XCTAssertEqual(rows.row(atY: 60), 1)
        XCTAssertEqual(rows.row(atY: 66), 2)
    }

    /// A fold at the very top has no row above it to fall back on.
    func testFoldBeforeTheFirstRowResolvesForwards() {
        let rows = layout([(nil, 30), (4, 18), (5, 18)])
        XCTAssertEqual(rows.row(atY: 10), 4)
    }

    /// The hidden half of a remove+add pair draws nothing and takes no
    /// height, so it must never swallow a point.
    func testZeroHeightEntriesAreSkipped() {
        let rows = layout([(0, 18), (nil, 0), (2, 18)])
        XCTAssertEqual(rows.row(atY: 0), 0)
        XCTAssertEqual(rows.row(atY: 18), 2)
        XCTAssertEqual(rows.row(atY: 35), 2)
    }

    func testEmptyLayoutHasNoRows() {
        XCTAssertNil(layout([]).row(atY: 10))
        XCTAssertNil(layout([(nil, 30)]).row(atY: 10))
    }

    // MARK: - X hit-testing

    /// Monospaced, so the columns are evenly spaced — the point of the
    /// CoreText lookup is that it stays true for text that isn't.
    func testColumnFollowsTheAdvanceWidth() {
        let text = "let value = 1"
        XCTAssertEqual(CompareTextHitTest.column(in: text, fontSize: 12, x: -20), 0)
        XCTAssertEqual(CompareTextHitTest.column(in: text, fontSize: 12, x: 0), 0)
        XCTAssertEqual(CompareTextHitTest.column(in: text, fontSize: 12, x: 10_000), text.count)

        // Somewhere in the middle resolves to a character inside the line,
        // and further right never resolves to an earlier one.
        let middle = CompareTextHitTest.column(in: text, fontSize: 12, x: 30)
        XCTAssertGreaterThan(middle, 0)
        XCTAssertLessThan(middle, text.count)
        XCTAssertGreaterThanOrEqual(
            CompareTextHitTest.column(in: text, fontSize: 12, x: 60),
            middle
        )
    }

    func testEmptyLineHasOnlyColumnZero() {
        XCTAssertEqual(CompareTextHitTest.column(in: "", fontSize: 12, x: 200), 0)
    }

    /// Columns are counted in characters, not UTF-16 units — a line with an
    /// emoji in it would otherwise slice a surrogate pair in half when the
    /// selection is turned back into text.
    func testColumnsCountCharactersNotUTF16() {
        let text = "a 🚀 b 🚀 c"
        let column = CompareTextHitTest.column(in: text, fontSize: 12, x: 10_000)
        XCTAssertEqual(column, text.count)
        XCTAssertLessThan(column, text.utf16.count)
        // Every column the hit test can return has to be a valid slice point.
        for x in stride(from: CGFloat(0), to: 200, by: 4) {
            let c = CompareTextHitTest.column(in: text, fontSize: 12, x: x)
            XCTAssertTrue((0...text.count).contains(c))
        }
    }
}
