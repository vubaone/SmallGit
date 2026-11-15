import XCTest
import AppKit
@testable import SmallGit

/// How far a hunk diff lets its text scroll sideways is set by its widest
/// line, so getting that line wrong either hides the end of it or scrolls
/// past into blank space.
final class DiffTextWidthTests: XCTestCase {

    private let fontSize: CGFloat = 12
    /// Padding on both sides of the text cell.
    private let padding: CGFloat = 12

    private var cell: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    private func widest(_ lines: [String], whitespace: Bool = false) -> CGFloat {
        DiffTextWidth.widest(of: lines, fontSize: fontSize, showWhitespace: whitespace)
    }

    func testNothingToScrollWithoutText() {
        XCTAssertEqual(widest([]), 0)
        XCTAssertEqual(widest(["", ""]), 0)
    }

    func testLongestLineSetsTheWidth() {
        let width = widest(["short", String(repeating: "x", count: 120), "mid line"])
        XCTAssertEqual(width, ceil(120 * cell) + padding, accuracy: 1)
    }

    func testTabsCountAsTheColumnsTheyReach() {
        // Two tabs then four characters reach column 12.
        XCTAssertEqual(widest(["\t\tabcd"]), ceil(12 * cell) + padding, accuracy: 1)
    }

    /// Decomposed Vietnamese spends several UTF-16 units on one cell, so its
    /// raw length overstates its width; a shorter-looking ASCII line that is
    /// really wider still has to win.
    func testCombiningMarksDoNotHideAWiderLine() {
        let decomposed = String(repeating: "e\u{0302}\u{0301}", count: 50)  // 150 units, 50 cells
        let ascii = String(repeating: "a", count: 70)                      // 70 units, 70 cells
        XCTAssertEqual(widest([decomposed, ascii]), ceil(70 * cell) + padding, accuracy: 1)
    }

    func testWhitespaceMarkersLeaveRoomForThePilcrow() {
        let line = String(repeating: "x", count: 10)
        XCTAssertEqual(widest([line], whitespace: true) - widest([line]), fontSize, accuracy: 0.5)
    }
}
