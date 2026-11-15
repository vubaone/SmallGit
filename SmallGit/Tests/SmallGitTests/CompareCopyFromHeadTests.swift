import XCTest
@testable import SmallGit

/// Copying a block back from HEAD in the compare window — Beyond Compare's
/// "Copy to Right", in the one direction this window has: HEAD is a committed
/// revision and cannot be written to.
///
/// The arithmetic is what these pin. A block is a line span in the working
/// file, and the three shapes it can have do visibly different things —
/// overwrite, put back, take away — off the same assignment. Getting one
/// wrong writes somebody's file with the wrong lines and saves cleanly.
final class CompareCopyFromHeadTests: XCTestCase {

    /// The working file every case below copies into.
    private let working = "one\ntwo\nthree\nfour"

    private func block(
        rowStart: Int = 0,
        rowEnd: Int = 0,
        workingStart: Int,
        workingCount: Int,
        original: String
    ) -> BlockEdit {
        BlockEdit(
            rowStart: rowStart,
            rowEnd: rowEnd,
            headRows: max(rowEnd - rowStart + 1, 1),
            headLastRow: rowEnd,
            workingStart: workingStart,
            workingCount: workingCount,
            original: original,
            text: original
        )
    }

    private func applying(_ edit: BlockEdit, to text: String) -> String {
        TextBufferEdits.applying(blocks: [edit.asBlock], to: text)
    }

    // MARK: - The three shapes

    /// Both sides hold lines: the working ones become HEAD's, however the
    /// two counts compare.
    func testOverwritesAWorkingBlockWithHeadsLines() {
        let edit = block(workingStart: 2, workingCount: 2, original: "two\nthree")
            .copyingFromHead(["TWO", "TWO-AND-A-HALF", "THREE"])
        XCTAssertEqual(applying(edit, to: working), "one\nTWO\nTWO-AND-A-HALF\nTHREE\nfour")
    }

    /// Lines the user deleted: HEAD still has them, and copying puts them
    /// back where they were. `workingCount` is zero — there is nothing to
    /// replace, only a place to insert.
    func testPutsBackLinesDeletedFromWorking() {
        let edit = block(workingStart: 3, workingCount: 0, original: "")
            .copyingFromHead(["restored", "also restored"])
        XCTAssertEqual(applying(edit, to: working), "one\ntwo\nrestored\nalso restored\nthree\nfour")
    }

    /// Lines the user added: HEAD has nothing to say there, so copying takes
    /// them away rather than blanking them.
    func testRemovesLinesHeadDoesNotHave() {
        let edit = block(workingStart: 2, workingCount: 2, original: "two\nthree")
            .copyingFromHead([])
        XCTAssertEqual(applying(edit, to: working), "one\nfour")
        XCTAssertTrue(edit.removed, "an empty copy is a removal, and has to say so")
    }

    /// The one line that joins to the same empty string a removal does. A
    /// block whose HEAD side is a single blank line must come back as a
    /// single blank line — not vanish.
    func testASingleBlankLineSurvivesTheCopy() {
        let edit = block(workingStart: 2, workingCount: 1, original: "two")
            .copyingFromHead([""])
        XCTAssertTrue(edit.emptyIsOneBlankLine)
        XCTAssertFalse(edit.removed)
        XCTAssertEqual(applying(edit, to: working), "one\n\nthree\nfour")
    }

    /// And the removal it would otherwise be confused with still removes.
    func testAnEmptyCopyAndABlankLineDoNotAgree() {
        let removal = block(workingStart: 2, workingCount: 1, original: "two")
            .copyingFromHead([])
        let blank = block(workingStart: 2, workingCount: 1, original: "two")
            .copyingFromHead([""])
        XCTAssertNotEqual(applying(removal, to: working), applying(blank, to: working))
        XCTAssertEqual(applying(removal, to: working), "one\nthree\nfour")
    }

    // MARK: - How it reads to the rest of the view

    /// A copy that changes nothing is not an edit, and must not leave the
    /// window claiming there is work to save.
    func testCopyingAnIdenticalBlockIsNotAnEdit() {
        let edit = block(workingStart: 2, workingCount: 1, original: "two")
            .copyingFromHead(["two"])
        XCTAssertEqual(edit.text, edit.original)
        XCTAssertFalse(edit.removed)
    }

    /// Several blocks copied at once are applied bottom-up against the same
    /// buffer, so an earlier one growing or shrinking cannot move a later
    /// one's line numbers.
    func testCopyingSeveralBlocksAtOnceKeepsEachOnesLineNumbers() {
        let first = block(workingStart: 1, workingCount: 1, original: "one")
            .copyingFromHead(["ONE", "ONE-B"])
        let second = block(workingStart: 4, workingCount: 1, original: "four")
            .copyingFromHead(["FOUR"])
        XCTAssertEqual(
            TextBufferEdits.applying(blocks: [first.asBlock, second.asBlock], to: working),
            "ONE\nONE-B\ntwo\nthree\nFOUR"
        )
    }

    /// Typing after a copy hands the block back to the editor's own reading
    /// of an empty draft: the lines go.
    func testTypingClearsTheBlankLineReading() {
        var edit = block(workingStart: 2, workingCount: 1, original: "two")
            .copyingFromHead([""])
        XCTAssertTrue(edit.emptyIsOneBlankLine)
        // What `blockBinding`'s setter does on the first keystroke.
        edit.text = "typed"
        edit.emptyIsOneBlankLine = false
        edit.text = ""
        XCTAssertEqual(applying(edit, to: working), "one\nthree\nfour")
    }

    // MARK: - One line of a block

    private func section(
        workingStart: Int,
        _ rows: [(head: String?, working: String?)]
    ) -> BlockEdit {
        let lineRows = rows.enumerated().map {
            BlockEdit.LineRow(row: $0.offset, head: $0.element.head, working: $0.element.working)
        }
        let working = rows.compactMap(\.working)
        let text = working.joined(separator: "\n")
        return BlockEdit(
            rowStart: 0,
            rowEnd: rows.count - 1,
            headRows: rows.count,
            headLastRow: rows.count - 1,
            workingStart: workingStart,
            workingCount: working.count,
            original: text,
            text: text,
            gaps: LineDiff.gapRows(hasWorkingLine: rows.map { $0.working != nil }),
            lineRows: lineRows
        )
    }

    /// The case the line arrow is for: one added line — a comment, say — out
    /// of a block of them, and the rest stay.
    func testTakesOneAddedLineOutOfABlock() {
        let edit = section(workingStart: 2, [(nil, "two"), (nil, "three")])
            .takingFromHead(rows: [0])
        XCTAssertEqual(applying(edit, to: working), "one\nthree\nfour")
        // Its row stays open opposite HEAD's, so the line below does not
        // ride up a row.
        XCTAssertEqual(edit.gaps, [1, 0])
    }

    /// Line copies stack: each one is worked out against the block as the
    /// earlier ones left it, not against the file.
    func testLineCopiesBuildOnEachOther() {
        let first = section(workingStart: 2, [(nil, "two"), (nil, "three")])
            .takingFromHead(rows: [0])
        XCTAssertTrue(first.canTakeLineFromHead(row: 1))
        XCTAssertFalse(first.canTakeLineFromHead(row: 0), "already HEAD's")
        let both = first.takingFromHead(rows: [1])
        XCTAssertTrue(both.removed)
        XCTAssertEqual(both.gaps, [], "an emptied block draws nothing to hold space in")
        XCTAssertEqual(applying(both, to: working), "one\nfour")
    }

    /// A line only HEAD has goes back between the working lines around it,
    /// and a changed line takes HEAD's text — each without touching the rest.
    func testPutsBackOrOverwritesJustThatLine() {
        let rows: [(head: String?, working: String?)] = [("TWO", "two"), ("gone", nil), (nil, "three")]
        let putBack = section(workingStart: 2, rows).takingFromHead(rows: [1])
        XCTAssertEqual(applying(putBack, to: working), "one\ntwo\ngone\nthree\nfour")
        let overwritten = section(workingStart: 2, rows).takingFromHead(rows: [0])
        XCTAssertEqual(applying(overwritten, to: working), "one\nTWO\nthree\nfour")
    }

    /// Unchanged rows have nothing to copy, and a block the user has typed in
    /// no longer says which line a row stands for.
    func testNoLineCopyOnAnUnchangedRowOrATypedBlock() {
        var edit = section(workingStart: 1, [("one", "one"), (nil, "two")])
        XCTAssertFalse(edit.canTakeLineFromHead(row: 0))
        XCTAssertTrue(edit.canTakeLineFromHead(row: 1))
        edit.text = "one\ntyped"
        XCTAssertFalse(edit.canTakeLineFromHead(row: 1))
    }

    /// The whole-block copy goes through the same rows: lines HEAD alone had
    /// come back as lines, not as lines plus the space they used to leave.
    func testWholeBlockCopyDropsTheSpaceItFills() {
        let block = section(workingStart: 3, [("gone", nil), ("also gone", nil)])
        XCTAssertEqual(block.gaps, [2])
        let edit = block.takingFromHead(rows: [0, 1])
        XCTAssertEqual(edit.gaps, [])
        XCTAssertEqual(applying(edit, to: working), "one\ntwo\ngone\nalso gone\nthree\nfour")
    }
}
