import XCTest
@testable import SmallGit

final class DiffLineSelectionTests: XCTestCase {

    private func line(_ text: String, _ type: DiffLineType = .context) -> DiffLine {
        DiffLine(type: type, content: text)
    }

    func testPlainClickSelectsOneRowAndAnchors() {
        let rows = [line("a"), line("b"), line("c")]
        var selection = DiffLineSelection()
        selection.selectOnly(rows[1])
        XCTAssertEqual(selection.count, 1)
        XCTAssertTrue(selection.contains(rows[1]))
        XCTAssertEqual(selection.anchorID, rows[1].id)

        selection.selectOnly(rows[2])
        XCTAssertEqual(selection.count, 1, "a plain click replaces the selection")
        XCTAssertTrue(selection.contains(rows[2]))
    }

    func testCommandClickTogglesAndReanchors() {
        let rows = [line("a"), line("b"), line("c")]
        var selection = DiffLineSelection()
        selection.toggle(rows[0])
        selection.toggle(rows[2])
        XCTAssertEqual(selection.count, 2)
        XCTAssertEqual(selection.anchorID, rows[2].id)

        selection.toggle(rows[0])
        XCTAssertEqual(selection.count, 1)
        XCTAssertFalse(selection.contains(rows[0]))
    }

    func testShiftClickExtendsBothWays() {
        let rows = [line("a"), line("b"), line("c"), line("d")]
        var selection = DiffLineSelection()
        selection.selectOnly(rows[1])
        selection.extend(to: rows[3], within: rows)
        XCTAssertEqual(selection.count, 3)
        XCTAssertFalse(selection.contains(rows[0]))

        // Backwards from the same anchor, which stays where the plain click
        // put it rather than following the end of the range.
        selection.extend(to: rows[0], within: rows)
        XCTAssertEqual(selection.count, 2)
        XCTAssertTrue(selection.contains(rows[0]))
        XCTAssertTrue(selection.contains(rows[1]))
        XCTAssertFalse(selection.contains(rows[3]))
    }

    func testShiftClickWithNoAnchorSelectsJustThatRow() {
        let rows = [line("a"), line("b")]
        var selection = DiffLineSelection()
        selection.extend(to: rows[1], within: rows)
        XCTAssertEqual(selection.count, 1)
        XCTAssertTrue(selection.contains(rows[1]))
    }

    /// Pad rows stand for a line the other side doesn't have. Selecting one
    /// would put a phantom blank line in the middle of a copy.
    func testPadRowsAreNotSelectable() {
        let pad = line("", .empty)
        var selection = DiffLineSelection()
        selection.selectOnly(pad)
        XCTAssertTrue(selection.isEmpty)
        selection.toggle(pad)
        XCTAssertTrue(selection.isEmpty)
        selection.extend(to: pad, within: [pad])
        XCTAssertTrue(selection.isEmpty)
    }

    /// Copy comes out in display order however the rows were clicked, and
    /// carries content only — no `+`/`-` marker, no line number.
    func testCopyTextIsContentInDisplayOrder() {
        let rows = [
            line("context", .context),
            line("removed", .del),
            line("added", .add)
        ]
        var selection = DiffLineSelection()
        selection.toggle(rows[2])
        selection.toggle(rows[0])
        XCTAssertEqual(selection.text(of: rows), "context\nadded")
    }

    func testCopyTextIgnoresRowsNotOnScreen() {
        let rows = [line("a"), line("b")]
        var selection = DiffLineSelection()
        selection.selectOnly(rows[1])
        XCTAssertEqual(selection.text(of: [rows[0]]), "")
    }

    func testClearDropsSelectionAndAnchor() {
        let rows = [line("a"), line("b")]
        var selection = DiffLineSelection()
        selection.selectOnly(rows[0])
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchorID)
    }
}

extension DiffLineSelectionTests {

    /// What a drag hands in: exactly those rows, replacing whatever was
    /// selected, with the anchor at the top of the run.
    func testDragSelectionReplacesAndReanchors() {
        let rows = [line("a"), line("b"), line("c"), line("d")]
        var selection = DiffLineSelection()
        selection.selectOnly(rows[3])
        selection.select(Array(rows[0...1]))
        XCTAssertEqual(selection.count, 2)
        XCTAssertFalse(selection.contains(rows[3]))
        XCTAssertEqual(selection.anchorID, rows[0].id)
    }

    /// A drag down a side-by-side column runs over pad rows wherever the
    /// other side is longer. They carry no text and must not end up in the
    /// selection as blank lines.
    func testDragSkipsPadRows() {
        let rows = [line("a"), line("", .empty), line("b")]
        var selection = DiffLineSelection()
        selection.select(rows)
        XCTAssertEqual(selection.count, 2)
        XCTAssertEqual(selection.text(of: rows), "a\nb")
    }

    func testDragOverOnlyPadRowsSelectsNothing() {
        let rows = [line("", .empty), line("", .empty)]
        var selection = DiffLineSelection()
        selection.select(rows)
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchorID)
    }
}
