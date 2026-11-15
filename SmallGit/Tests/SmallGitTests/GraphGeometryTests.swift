import XCTest
@testable import SmallGit

/// The one number that has to agree between the graph and anything drawn
/// beside it: where a lane's centre is.
///
/// The working-tree row draws its own ring rather than a commit dot, and
/// the first version of it put that ring at the column's leading edge —
/// visibly out of line with every dot below. Pinning the geometry here
/// keeps the two drawings reading the same value.
final class GraphGeometryTests: XCTestCase {

    func testLaneCentresMatchTheLaneSpacing() {
        XCTAssertEqual(CommitGraphCell.laneCentre(0), CommitGraphCell.laneSpacing / 2)
        XCTAssertEqual(CommitGraphCell.laneCentre(1), CommitGraphCell.laneSpacing * 1.5)
        XCTAssertEqual(CommitGraphCell.laneCentre(2), CommitGraphCell.laneSpacing * 2.5)
        // A negative lane is a bug upstream, not a reason to draw off-canvas.
        XCTAssertEqual(CommitGraphCell.laneCentre(-3), CommitGraphCell.laneCentre(0))
    }

    func testTheColumnIsWideEnoughForTheLaneItDraws() {
        // The ring is 4pt either side of the centre; the column has to hold
        // it, or the working-tree row would clip where commit rows do not.
        for lanes in 1...8 {
            let width = CommitGraphCell.columnWidth(lanes: lanes)
            XCTAssertGreaterThanOrEqual(width, CommitGraphCell.laneCentre(lanes - 1) + 4)
        }
    }

    func testRowMetricsAreTheOnesTheCommitRowsUse() {
        // These are the two that were wrong on the first attempt, and both
        // are invisible in code review: the working-tree row was inset 6
        // where every commit row is inset 10, and it skipped the marker
        // column that every commit row reserves — so its text started 3
        // points further left than every subject beneath it.
        XCTAssertEqual(JournalRowLayout.horizontalPadding, 10)
        XCTAssertEqual(JournalRowLayout.markerWidth, 3)
        XCTAssertEqual(JournalRowLayout.columnSpacing, 8)
        XCTAssertEqual(JournalRowLayout.contentSpacing, 6)
    }

    func testTheDashPatternIsSharedByBothHalvesOfTheConnector() {
        // Same style object on the working-tree row and on the commit row
        // beneath it, so the dashes meet across the row boundary instead of
        // restarting mid-gap.
        XCTAssertEqual(CommitGraphCell.dashedStroke.dash, [3, 3])
        XCTAssertEqual(CommitGraphCell.dashedStroke.lineWidth, 1.8)
    }
}
