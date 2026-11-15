import XCTest
@testable import SmallGit

/// The unit the compare window edits and copies in: a run of changes plus the
/// context kept either side, which is what the collapsed view draws between
/// two folds.
///
/// Worth pinning separately from `collapse`, because the failure is quiet: an
/// editor that opens over one row more than the user can see writes a line
/// they never looked at, and saves cleanly.
final class CompareSectionTests: XCTestCase {

    /// `kinds` spells the alignment: "s" unchanged, "m" changed on both
    /// sides, "r" only in HEAD, "a" only in the working file.
    private func rows(_ kinds: String) -> [CompareRow] {
        var left = 0
        var right = 0
        return kinds.enumerated().map { index, kind in
            switch kind {
            case "r":
                left += 1
                return CompareRow(id: index, leftLine: left, leftText: "L\(left)",
                                  rightLine: nil, rightText: nil)
            case "a":
                right += 1
                return CompareRow(id: index, leftLine: nil, leftText: nil,
                                  rightLine: right, rightText: "R\(right)")
            case "m":
                left += 1
                right += 1
                return CompareRow(id: index, leftLine: left, leftText: "L\(left)",
                                  rightLine: right, rightText: "R\(right)-changed")
            default:
                left += 1
                right += 1
                return CompareRow(id: index, leftLine: left, leftText: "same\(left)",
                                  rightLine: right, rightText: "same\(left)")
            }
        }
    }

    private func spans(_ kinds: String, context: Int = 3) -> [ClosedRange<Int>] {
        LineDiff.sections(rows: rows(kinds), contextLines: context)
    }

    // MARK: - Where a section begins and ends

    /// The everyday shape: one change with its context either side, and the
    /// rest of the file folded away.
    func testASectionIsTheChangePlusItsContext() {
        // 10 unchanged, one change, 10 unchanged.
        XCTAssertEqual(spans(String(repeating: "s", count: 10) + "m" + String(repeating: "s", count: 10)),
                       [7...13])
    }

    /// Two changes close enough that their context overlaps are one section,
    /// because that is how they are drawn — no fold between them.
    func testNearbyChangesShareASection() {
        XCTAssertEqual(spans("ssssssssmssmssssssss"), [5...14])
    }

    /// Far enough apart and the fold between them splits the sections.
    func testDistantChangesGetTheirOwnSections() {
        let kinds = String(repeating: "s", count: 6) + "m"
            + String(repeating: "s", count: 20) + "m" + String(repeating: "s", count: 6)
        XCTAssertEqual(spans(kinds), [3...9, 24...30])
    }

    /// Context off and a section is exactly its change, which is what the
    /// window used to edit in.
    func testWithoutContextASectionIsJustTheChange() {
        XCTAssertEqual(spans("ssssssmmssssss", context: 0), [6...7])
    }

    /// A file with nothing to compare has no sections, and asking about a row
    /// in one must not trap.
    func testAnUnchangedFileHasNoSections() {
        XCTAssertTrue(spans(String(repeating: "s", count: 30)).isEmpty)
        XCTAssertTrue(LineDiff.sections(rows: [], contextLines: 3).isEmpty)
    }

    /// Changes at the very edges keep their sections inside the file.
    func testSectionsAtTheEdgesStayInBounds() {
        let kinds = "m" + String(repeating: "s", count: 20) + "m"
        let out = spans(kinds)
        XCTAssertEqual(out.first?.lowerBound, 0)
        XCTAssertEqual(out.last?.upperBound, kinds.count - 1)
    }

    // MARK: - The space a section holds open

    /// Lines only HEAD has sit *between* working lines, so their space has to
    /// be kept where they are — collecting it at the end would slide every
    /// line below the gap out of step with its counterpart.
    func testGapsAreCountedWhereTheyFall() {
        // line, gap, gap, line, line
        XCTAssertEqual(LineDiff.gapRows(hasWorkingLine: [true, false, false, true, true]),
                       [0, 2, 0, 0])
    }

    func testAGapBeforeTheFirstLineIsLeadingSpace() {
        XCTAssertEqual(LineDiff.gapRows(hasWorkingLine: [false, true, true]), [1, 0, 0])
    }

    func testAGapPastTheLastLineIsTrailingSpace() {
        XCTAssertEqual(LineDiff.gapRows(hasWorkingLine: [true, false, false]), [0, 2])
    }

    /// A section with a line for every row needs no space at all, and says so
    /// with an empty array rather than a row of zeroes — the views take that
    /// as "nothing to draw".
    func testNoGapsComesBackEmpty() {
        XCTAssertEqual(LineDiff.gapRows(hasWorkingLine: [true, true, true]), [])
        XCTAssertEqual(LineDiff.gapRows(hasWorkingLine: []), [])
    }

    /// A section HEAD alone has: every row is a gap, and there is no line to
    /// hang them on but the one that isn't there.
    func testASectionWithNoWorkingLinesIsAllGap() {
        XCTAssertEqual(LineDiff.gapRows(hasWorkingLine: [false, false, false]), [3])
    }

    /// The invariant the layout rests on: lines plus gaps is exactly the
    /// number of rows drawn, which is what keeps the two columns level.
    func testLinesPlusGapsIsTheRowCount() {
        for pattern in [[true], [false], [true, false, true], [false, true, false, false],
                        [true, true, false, true, false]] {
            let gaps = LineDiff.gapRows(hasWorkingLine: pattern)
            let lines = pattern.filter { $0 }.count
            XCTAssertEqual(lines + gaps.reduce(0, +), pattern.count, "\(pattern)")
        }
    }
}
