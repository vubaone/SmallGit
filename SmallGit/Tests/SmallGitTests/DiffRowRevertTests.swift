import XCTest
@testable import SmallGit

/// The hover arrow the Changes panel puts on the divider between the two
/// side-by-side panes: copy this line from the left pane over the right —
/// Beyond Compare's "Copy to Right", which is to say revert the line.
///
/// What these pin is the mapping from compare mode to git command, and which
/// lines one row hands that command. Both panes are read-only renderings of a
/// `git diff`, so the copy is a patch reverse-applied to the right pane's
/// tree — and naming the wrong lines writes somebody's file with a line that
/// is neither version.
final class DiffRowRevertTests: XCTestCase {

    // MARK: - Which revert each mode offers

    /// HEAD ↔ Index: the index is the right pane, HEAD the left, and copying
    /// left over right takes the line back out of the index. The working file
    /// still holds the change.
    func testStagedDiffUnstages() {
        let source: DiffSource = .fileChanges(file: "a.swift", mode: .headVsIndex)
        XCTAssertEqual(DiffRowRevert(source: source), .unstage)
    }

    /// Index ↔ Working: the working tree is the right pane, and copying the
    /// index over it throws the edit away. The more expensive of the two, so
    /// it is the one a wrong mapping must not reach by accident.
    func testUnstagedDiffDiscards() {
        let source: DiffSource = .fileChanges(file: "a.swift", mode: .indexVsWorkingTree)
        XCTAssertEqual(DiffRowRevert(source: source), .discard)
    }

    /// Everything a line cannot be reverted out of. An untracked file is in
    /// the list for its own reason: `git apply --cached` has nothing in the
    /// index to apply against, which is why `DiffSource.isStageable` excludes
    /// it too.
    func testSourcesThatOfferNoArrow() {
        let sources: [DiffSource] = [
            .none,
            .untrackedFile(file: "new.swift"),
            .conflict(file: "a.swift"),
            .stash(index: 0, path: nil),
            .stash(index: 0, path: "a.swift"),
            .commit(hash: "abc", shortHash: "abc", subject: "s"),
            .submodule(path: "vendor/lib")
        ]
        for source in sources {
            XCTAssertNil(DiffRowRevert(source: source), "\(source) should offer no arrow")
        }
    }

    /// The arrow offers exactly what the rest of the panel already allows:
    /// anything a line can be staged out of, it can be reverted out of.
    func testArrowAgreesWithIsStageable() {
        let sources: [DiffSource] = [
            .none,
            .fileChanges(file: "a.swift", mode: .indexVsWorkingTree),
            .fileChanges(file: "a.swift", mode: .headVsIndex),
            .untrackedFile(file: "new.swift"),
            .conflict(file: "a.swift"),
            .stash(index: 0, path: "a.swift"),
            .commit(hash: "abc", shortHash: "abc", subject: "s"),
            .submodule(path: "vendor/lib")
        ]
        for source in sources {
            XCTAssertEqual(
                DiffRowRevert(source: source) != nil,
                source.isStageable,
                "\(source)"
            )
        }
    }

    // MARK: - Which way it points

    /// One direction, both modes: the left pane wins. The right pane is
    /// downstream of the left either way, so there is no case in which the
    /// arrow turns around.
    func testArrowAlwaysPointsRight() {
        XCTAssertEqual(DiffRowRevert.symbol, "arrow.right.circle.fill")
    }

    // MARK: - What the tooltip promises

    /// Both panes named, and the consequence. Without the second half a
    /// discard reads as cheap as an unstage, and only one of them can be
    /// undone by clicking the other way.
    func testHelpNamesBothPanesAndTheConsequence() {
        XCTAssertEqual(
            DiffRowRevert.unstage.help,
            "Copy this line from HEAD over Index — unstages it"
        )
        XCTAssertEqual(
            DiffRowRevert.discard.help,
            "Copy this line from Index over Working — discards the change"
        )
    }

    // MARK: - Which lines a row hands the command

    private func line(_ type: DiffLineType, _ content: String) -> DiffLine {
        DiffLine(type: type, content: content)
    }

    /// A modification is both halves of one row: reverting it has to take the
    /// `+` away *and* put the `-` back, or the line ends up neither version.
    func testModificationRowTargetsBothHalves() {
        let left = line(.del, "old")
        let right = line(.add, "new")
        let targets = DiffRowRevert.targetLines(left: left, right: right)
        XCTAssertEqual(targets.map(\.id), [left.id, right.id])
    }

    /// A pure addition pads the left side. Only the `+` is real, and
    /// reverse-applying it takes the added line away.
    func testAddedRowTargetsTheAddition() {
        let right = line(.add, "new")
        let targets = DiffRowRevert.targetLines(left: line(.empty, ""), right: right)
        XCTAssertEqual(targets.map(\.id), [right.id])
    }

    /// A pure deletion pads the right side. Reverse-applying the `-` puts the
    /// deleted line back.
    func testDeletedRowTargetsTheDeletion() {
        let left = line(.del, "gone")
        let targets = DiffRowRevert.targetLines(left: left, right: line(.empty, ""))
        XCTAssertEqual(targets.map(\.id), [left.id])
    }

    /// An unchanged row holds the same text on both sides — `DiffPairing`
    /// even hands it the same `DiffLine` twice. Copying one over the other
    /// would write back what is already there, and an empty target list is
    /// what keeps the arrow off the row entirely.
    func testContextRowTargetsNothing() {
        let same = line(.context, "unchanged")
        XCTAssertTrue(DiffRowRevert.targetLines(left: same, right: same).isEmpty)
    }

    /// The pairing a real hunk produces, walked end to end: the arrow appears
    /// on exactly the rows that hold a change, and each names its own lines.
    func testTargetsAcrossAPairedHunk() {
        let hunk = DiffHunk(
            oldStart: 1, oldCount: 3, newStart: 1, newCount: 3,
            lines: [
                line(.context, "keep"),
                line(.del, "old"),
                line(.add, "new"),
                line(.add, "extra"),
                line(.context, "keep")
            ]
        )
        let counts = DiffPairing.pairs(from: [hunk]).map {
            DiffRowRevert.targetLines(left: $0.left, right: $0.right).count
        }
        // context, del|add, empty|add, context
        XCTAssertEqual(counts, [0, 2, 1, 0])
    }
}
