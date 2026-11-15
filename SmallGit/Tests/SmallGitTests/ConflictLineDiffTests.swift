import XCTest
@testable import SmallGit

final class ConflictLineDiffTests: XCTestCase {

    func testThreeIdenticalVersionsStayOnSharedRows() {
        let lines = ["one", "two", "three"]
        let rows = ConflictLineDiff.compute(
            base: lines,
            ours: lines,
            theirs: lines,
            hasBase: true
        )

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { !$0.isChange })
        XCTAssertEqual(rows.map { $0.ours?.lineNumber }, [1, 2, 3])
        XCTAssertEqual(rows.map { $0.base?.lineNumber }, [1, 2, 3])
        XCTAssertEqual(rows.map { $0.theirs?.lineNumber }, [1, 2, 3])
    }

    func testInsertionCreatesAbsentCellsWithFollowingContextAligned() throws {
        let rows = ConflictLineDiff.compute(
            base: ["one", "three"],
            ours: ["one", "ours two", "three"],
            theirs: ["one", "three"],
            hasBase: true
        )

        let insertion = try XCTUnwrap(rows.first { $0.ours?.text == "ours two" })
        XCTAssertNil(insertion.base)
        XCTAssertNil(insertion.theirs)
        XCTAssertTrue(insertion.isChange)

        let trailing = try XCTUnwrap(rows.first { $0.base?.text == "three" })
        XCTAssertEqual(trailing.ours?.text, "three")
        XCTAssertEqual(trailing.theirs?.text, "three")
    }

    func testIndependentInsertionsAtOneBoundaryAlignAgainstEachOther() throws {
        let rows = ConflictLineDiff.compute(
            base: ["before", "after"],
            ours: ["before", "shared", "ours only", "after"],
            theirs: ["before", "shared", "theirs only", "after"],
            hasBase: true
        )

        let shared = try XCTUnwrap(rows.first { $0.ours?.text == "shared" })
        XCTAssertEqual(shared.theirs?.text, "shared")
        XCTAssertNil(shared.base)
        XCTAssertTrue(shared.isChange)
        let differing = try XCTUnwrap(rows.first { $0.ours?.text == "ours only" })
        XCTAssertEqual(differing.theirs?.text, "theirs only")
        XCTAssertNil(differing.base)
        XCTAssertEqual(rows.last?.base?.text, "after")
        XCTAssertEqual(rows.last?.ours?.text, "after")
        XCTAssertEqual(rows.last?.theirs?.text, "after")
    }

    func testAddAddConflictAlignsOursDirectlyWithTheirs() {
        let rows = ConflictLineDiff.compute(
            base: [],
            ours: ["same", "ours"],
            theirs: ["same", "theirs"],
            hasBase: false
        )

        XCTAssertEqual(rows.first?.ours?.text, "same")
        XCTAssertEqual(rows.first?.theirs?.text, "same")
        XCTAssertFalse(rows.first?.isChange ?? true)
        XCTAssertTrue(rows.dropFirst().allSatisfy(\.isChange))
        XCTAssertTrue(rows.allSatisfy { $0.base == nil })
    }

    func testCollapseUsesChangesAcrossAnyOfTheThreeVersions() {
        let base = (0..<21).map { "line \($0)" }
        var ours = base
        ours[10] = "ours changed"
        let rows = ConflictLineDiff.compute(
            base: base,
            ours: ours,
            theirs: base,
            hasBase: true
        )

        let display = ConflictLineDiff.collapse(rows: rows, contextLines: 3)

        XCTAssertEqual(display.count, 9)
        guard case .fold(let leadingStart, let leadingCount) = display.first,
              case .fold(let trailingStart, let trailingCount) = display.last
        else { return XCTFail("expected leading and trailing folds") }
        XCTAssertEqual(leadingStart, 0)
        XCTAssertEqual(leadingCount, 7)
        XCTAssertEqual(trailingStart, 14)
        XCTAssertEqual(trailingCount, 7)
    }
}
