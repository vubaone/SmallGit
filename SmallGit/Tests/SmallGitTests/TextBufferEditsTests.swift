import XCTest
@testable import SmallGit

/// Line-number arithmetic for the compare view's in-place editing.
///
/// Worth its own tests because the failure mode is not a crash: an
/// off-by-one writes a real line of somebody's file with the contents of
/// another one, saves cleanly, and looks like it worked.
final class TextBufferEditsTests: XCTestCase {

    private let file = "one\ntwo\nthree"

    // MARK: - Reading

    func testLinesAreOneBased() {
        XCTAssertEqual(TextBufferEdits.line(1, in: file), "one")
        XCTAssertEqual(TextBufferEdits.line(3, in: file), "three")
    }

    func testOutOfRangeReadsAreEmptyRatherThanATrap() {
        XCTAssertEqual(TextBufferEdits.line(0, in: file), "")
        XCTAssertEqual(TextBufferEdits.line(4, in: file), "")
        XCTAssertEqual(TextBufferEdits.line(-1, in: file), "")
    }

    // MARK: - Replacing

    func testSettingALineLeavesItsNeighboursAlone() {
        XCTAssertEqual(TextBufferEdits.setting(line: 2, to: "TWO", in: file), "one\nTWO\nthree")
        XCTAssertEqual(TextBufferEdits.setting(line: 1, to: "", in: file), "\ntwo\nthree")
        XCTAssertEqual(TextBufferEdits.setting(line: 3, to: "3", in: file), "one\ntwo\n3")
    }

    func testAMultiLineReplacementBecomesMultipleLines() {
        // Pasting three lines into a row is a reasonable way to add three
        // lines. Flattening them into one would corrupt the paste.
        XCTAssertEqual(
            TextBufferEdits.setting(line: 2, to: "a\nb\nc", in: file),
            "one\na\nb\nc\nthree"
        )
    }

    func testAnOutOfRangeWriteChangesNothing() {
        // The line number comes from a diff that is rebuilt asynchronously,
        // so a stale row is reachable without anyone doing anything wrong.
        // Writing the wrong line would be far worse than doing nothing.
        XCTAssertEqual(TextBufferEdits.setting(line: 9, to: "x", in: file), file)
        XCTAssertEqual(TextBufferEdits.setting(line: 0, to: "x", in: file), file)
    }

    // MARK: - Inserting

    func testInsertingPutsTheBlankLineAtTheGivenNumber() {
        XCTAssertEqual(TextBufferEdits.insertingEmptyLine(at: 2, in: file), "one\n\ntwo\nthree")
        XCTAssertEqual(TextBufferEdits.line(2, in: TextBufferEdits.insertingEmptyLine(at: 2, in: file)), "")
    }

    func testInsertingAtTheEndsWorks() {
        XCTAssertEqual(TextBufferEdits.insertingEmptyLine(at: 1, in: file), "\none\ntwo\nthree")
        XCTAssertEqual(TextBufferEdits.insertingEmptyLine(at: 4, in: file), "one\ntwo\nthree\n")
        // Past the end clamps rather than trapping.
        XCTAssertEqual(TextBufferEdits.insertingEmptyLine(at: 99, in: file), "one\ntwo\nthree\n")
    }

    func testInsertingIntoAnEmptyBufferGivesTwoLines() {
        // An empty file is one empty line, the same way the diff counts it.
        XCTAssertEqual(TextBufferEdits.insertingEmptyLine(at: 1, in: ""), "\n")
    }

    // MARK: - Removing

    func testRemovingALine() {
        XCTAssertEqual(TextBufferEdits.removing(line: 2, in: file), "one\nthree")
        XCTAssertEqual(TextBufferEdits.removing(line: 1, in: file), "two\nthree")
        XCTAssertEqual(TextBufferEdits.removing(line: 3, in: file), "one\ntwo")
    }

    func testRemovingOutOfRangeChangesNothing() {
        XCTAssertEqual(TextBufferEdits.removing(line: 4, in: file), file)
        XCTAssertEqual(TextBufferEdits.removing(line: 0, in: file), file)
    }

    func testRemovingTheOnlyLineLeavesAnEmptyBuffer() {
        XCTAssertEqual(TextBufferEdits.removing(line: 1, in: "solo"), "")
    }

    // MARK: - Agreement with the aligner

    func testLineNumbersMeanTheSameThingAsInTheDiff() {
        // The compare view reads a line number off a diff row and hands it
        // straight to these. If the two disagreed about what splits a line,
        // every edit would land one line out at the first mismatch.
        let text = "a\nb\n\nc\n"
        XCTAssertEqual(TextBufferEdits.lines(of: text), LineDiff.split(text))
        for (index, line) in LineDiff.split(text).enumerated() {
            XCTAssertEqual(TextBufferEdits.line(index + 1, in: text), line)
        }
    }
    // MARK: - Applying block edits

    private func block(_ start: Int, _ count: Int, _ text: String) -> TextBufferEdits.Block {
        TextBufferEdits.Block(start: start, count: count, text: text)
    }

    /// A block retyped in place: same number of lines in, same number out.
    func testABlockIsReplacedByItsDraft() {
        let text = "one\ntwo\nthree\nfour"
        XCTAssertEqual(
            TextBufferEdits.applying(blocks: [block(2, 2, "TWO\nTHREE")], to: text),
            "one\nTWO\nTHREE\nfour"
        )
    }

    /// The point of editing a block rather than a line: lines can be added.
    func testADraftMayHoldMoreLinesThanTheBlockItReplaces() {
        let text = "one\ntwo\nthree"
        XCTAssertEqual(
            TextBufferEdits.applying(blocks: [block(2, 1, "two\ntwo and a half")], to: text),
            "one\ntwo\ntwo and a half\nthree"
        )
    }

    /// …and removed, which one line at a time could not express at all.
    func testADraftMayHoldFewerLinesThanTheBlockItReplaces() {
        let text = "one\ntwo\nthree\nfour"
        // Lines 2 and 3 become one line; line 4 is outside the block and stays.
        XCTAssertEqual(
            TextBufferEdits.applying(blocks: [block(2, 2, "TWO")], to: text),
            "one\nTWO\nfour"
        )
        // The whole tail as one block leaves only what it was retyped as.
        XCTAssertEqual(
            TextBufferEdits.applying(blocks: [block(2, 3, "TWO")], to: text),
            "one\nTWO"
        )
    }

    /// Clearing a block takes its lines out, rather than leaving the one
    /// blank line that splitting `""` would otherwise produce. Deleting a
    /// block entirely has to be expressible, and this is the only way a block
    /// editor can say it.
    func testAnEmptyDraftRemovesTheBlockRatherThanBlankingIt() {
        let text = "one\ntwo\nthree\nfour"
        XCTAssertEqual(
            TextBufferEdits.applying(blocks: [block(2, 2, "")], to: text),
            "one\nfour"
        )
    }

    func testClearingEveryBlockCanEmptyTheFile() {
        XCTAssertEqual(
            TextBufferEdits.applying(blocks: [block(1, 3, "")], to: "one\ntwo\nthree"),
            ""
        )
    }

    /// An emptied block next to one that was retyped: the removal must not
    /// take the line numbers of the other with it.
    func testAnEmptiedBlockDoesNotDisturbTheBlockAboveIt() {
        let text = "one\ntwo\nthree\nfour\nfive"
        let edits = [block(2, 1, "TWO"), block(4, 2, "")]
        XCTAssertEqual(
            TextBufferEdits.applying(blocks: edits, to: text),
            "one\nTWO\nthree"
        )
    }

    /// A block with no working side at all — a deletion in the diff — is a
    /// place to type rather than lines to replace.
    func testAZeroCountBlockInsertsWithoutReplacing() {
        let text = "one\nfour"
        XCTAssertEqual(
            TextBufferEdits.applying(blocks: [block(2, 0, "two\nthree")], to: text),
            "one\ntwo\nthree\nfour"
        )
    }

    /// Every block's line numbers were read off the same buffer, so a block
    /// that grows must not move the block above it onto the wrong lines.
    func testBlocksAreAppliedBottomUpSoEarlierOnesKeepTheirNumbers() {
        let text = "one\ntwo\nthree\nfour\nfive"
        let edits = [
            block(2, 1, "TWO\nTWO AND A HALF"),   // grows by one
            block(4, 2, "FOUR")                   // shrinks by one
        ]
        XCTAssertEqual(
            TextBufferEdits.applying(blocks: edits, to: text),
            "one\nTWO\nTWO AND A HALF\nthree\nFOUR"
        )
    }

    func testNothingPendingLeavesTheBufferIdentical() {
        let text = "one\ntwo\nthree\n"
        XCTAssertEqual(TextBufferEdits.applying(blocks: [], to: text), text)
    }

    /// Line numbers come off a diff of a file that could have changed on disk
    /// since. One that no longer exists must not corrupt the lines that do.
    func testABlockPastTheEndOfTheFileAppendsRatherThanTrapping() {
        let text = "one\ntwo"
        XCTAssertEqual(
            TextBufferEdits.applying(blocks: [block(9, 2, "NINE")], to: text),
            "one\ntwo\nNINE"
        )
    }

    /// A file ending in a newline splits to a final empty line. Losing it
    /// would show up as a change to the last line of the file.
    func testTheTrailingNewlineSurvivesABlockEdit() {
        let text = "one\ntwo\n"
        XCTAssertEqual(
            TextBufferEdits.applying(blocks: [block(1, 1, "ONE")], to: text),
            "ONE\ntwo\n"
        )
    }

    // MARK: - Backspace at the edges of a block

    private func caret(_ location: Int) -> NSRange {
        NSRange(location: location, length: 0)
    }

    /// Anywhere with text behind it, Backspace is Backspace.
    func testBackspaceInTheMiddleOfABlockPassesThrough() {
        XCTAssertEqual(TextBufferEdits.backspace(in: "one\ntwo", selection: caret(2)), .passThrough)
        XCTAssertEqual(TextBufferEdits.backspace(in: "one\ntwo", selection: caret(4)), .passThrough)
        XCTAssertEqual(TextBufferEdits.backspace(in: "one\ntwo", selection: caret(7)), .passThrough)
    }

    func testBackspaceWithNothingLeftLeavesTheBlock() {
        XCTAssertEqual(TextBufferEdits.backspace(in: "", selection: caret(0)), .leaveBlock)
    }

    /// The case this exists for: the first line of the block has been
    /// backspaced empty but lines below it survive, so there is nothing
    /// behind the caret and no line above to join to. The emptied line goes
    /// and the rest of the block moves up.
    func testBackspaceAtTheTopOfAnEmptiedFirstLineDropsIt() {
        XCTAssertEqual(TextBufferEdits.backspace(in: "\ntwo", selection: caret(0)), .dropFirstLine)
        XCTAssertEqual(TextBufferEdits.backspace(in: "\n", selection: caret(0)), .dropFirstLine)
    }

    /// At the top of a line that still holds text, dropping it would throw
    /// away characters the user never deleted.
    func testBackspaceAtTheTopOfALineWithTextPassesThrough() {
        XCTAssertEqual(TextBufferEdits.backspace(in: "one\ntwo", selection: caret(0)), .passThrough)
    }

    /// A selection reaching back to the start has something to delete of its
    /// own, and the text view should do it.
    func testBackspaceOverASelectionPassesThrough() {
        XCTAssertEqual(
            TextBufferEdits.backspace(in: "\ntwo", selection: NSRange(location: 0, length: 2)),
            .passThrough
        )
    }
}
