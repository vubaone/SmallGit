import XCTest
@testable import SmallGit

final class CommitGraphLayoutTests: XCTestCase {

    // Helper: build a tiny commit with declared parents.
    private func commit(_ h: String, parents: [String] = []) -> GitCommit {
        GitCommit(
            hash: h, shortHash: String(h.prefix(7)),
            subject: "", authorName: "", authorEmail: "",
            date: Date(), refs: "",
            parentHashes: parents
        )
    }

    func testLinearHistorySingleLane() {
        // C3 → C2 → C1 → (root)
        let commits = [
            commit("c3", parents: ["c2"]),
            commit("c2", parents: ["c1"]),
            commit("c1", parents: []),
        ]
        let layout = CommitGraphLayoutEngine.compute(commits: commits)
        XCTAssertEqual(layout.maxLanes, 1)
        XCTAssertEqual(layout.rows.map(\.lane), [0, 0, 0])
        XCTAssertTrue(layout.rows.allSatisfy { $0.throughLanes.isEmpty })
    }

    func testEmptyInputProducesEmptyLayout() {
        let layout = CommitGraphLayoutEngine.compute(commits: [])
        XCTAssertEqual(layout.maxLanes, 0)
        XCTAssertTrue(layout.rows.isEmpty)
    }

    func testBranchAndMergeProducesTwoLanesThenCollapses() {
        // History:
        //   m  ← merge of c2 and b1 (parents: c2, b1)
        //   c2 ← (parent: c1)
        //   b1 ← (parent: c1)
        //   c1 ← root
        let commits = [
            commit("m",  parents: ["c2", "b1"]),
            commit("c2", parents: ["c1"]),
            commit("b1", parents: ["c1"]),
            commit("c1", parents: []),
        ]
        let layout = CommitGraphLayoutEngine.compute(commits: commits)
        XCTAssertEqual(layout.maxLanes, 2)
        // Merge sits on lane 0 with two parent lanes (0 + a new 1).
        XCTAssertEqual(layout.rows[0].lane, 0)
        XCTAssertEqual(layout.rows[0].parentLanes.count, 2)
        XCTAssertEqual(Set(layout.rows[0].parentLanes), Set([0, 1]))
        // c2 still on lane 0, b1 on lane 1.
        XCTAssertEqual(layout.rows[1].lane, 0)
        XCTAssertEqual(layout.rows[2].lane, 1)
        // Once b1 is consumed and points back to c1 (same as c2's parent),
        // both lanes converge: c1 lives on the surviving lane and the
        // other slot frees up.
        XCTAssertEqual(layout.rows[3].lane, 0)
        // After the merge collapse, the c1 row should be back to 1 lane.
        XCTAssertEqual(layout.rows[3].activeLaneCount, 1)
    }

    func testParallelUnrelatedTipsGetSeparateLanes() {
        // Two disconnected histories shown together (e.g. orphan
        // branches). No shared parents → each branch keeps its own lane.
        //   a2 ← a1
        //   b2 ← b1
        let commits = [
            commit("a2", parents: ["a1"]),
            commit("b2", parents: ["b1"]),
            commit("a1", parents: []),
            commit("b1", parents: []),
        ]
        let layout = CommitGraphLayoutEngine.compute(commits: commits)
        XCTAssertGreaterThanOrEqual(layout.maxLanes, 2)
        XCTAssertEqual(layout.rows[0].lane, 0)
        XCTAssertEqual(layout.rows[1].lane, 1)
        // a1 stays on lane 0 (continuing a's chain); b1 stays on lane 1.
        XCTAssertEqual(layout.rows[2].lane, 0)
        XCTAssertEqual(layout.rows[3].lane, 1)
    }

    func testCommitWithoutKnownParentInWindowStillGetsLane() {
        // We only show the top of a long history; the parent commit lives
        // outside the displayed range. The dot must still appear on a
        // lane; the lane simply terminates at the bottom of our view.
        let commits = [
            commit("tip", parents: ["older-not-in-window"]),
        ]
        let layout = CommitGraphLayoutEngine.compute(commits: commits)
        XCTAssertEqual(layout.maxLanes, 1)
        XCTAssertEqual(layout.rows[0].lane, 0)
        XCTAssertEqual(layout.rows[0].parentLanes, [0])
    }

    func testIncomingExpectedTrueForLaneContinuation() {
        // Linear chain: c2's lane was claimed by c3's first-parent
        // pointer, so c2 has an "incoming" line above it.
        let commits = [
            commit("c3", parents: ["c2"]),
            commit("c2", parents: ["c1"]),
            commit("c1", parents: []),
        ]
        let layout = CommitGraphLayoutEngine.compute(commits: commits)
        XCTAssertFalse(layout.rows[0].incomingExpected, "c3 is a branch tip")
        XCTAssertTrue(layout.rows[1].incomingExpected,  "c2 was waited on by c3")
        XCTAssertTrue(layout.rows[2].incomingExpected,  "c1 was waited on by c2")
    }

    func testIncomingExpectedFalseForBranchTip() {
        // Two parallel chains. Each chain's top commit is a tip and
        // shouldn't render a phantom top-to-dot vertical line.
        let commits = [
            commit("a2", parents: ["a1"]),
            commit("b2", parents: ["b1"]),
            commit("a1", parents: []),
            commit("b1", parents: []),
        ]
        let layout = CommitGraphLayoutEngine.compute(commits: commits)
        XCTAssertFalse(layout.rows[0].incomingExpected, "a2 is a tip")
        XCTAssertFalse(layout.rows[1].incomingExpected, "b2 is a tip on a new lane")
        XCTAssertTrue(layout.rows[2].incomingExpected,  "a1 was waited on by a2")
        XCTAssertTrue(layout.rows[3].incomingExpected,  "b1 was waited on by b2")
    }

    func testMergingLanesExposedWhenSideBranchSharesParent() {
        // History: main and a side branch both point to the same parent
        // `p`. When we reach `p` it has TWO lanes waiting for it (0 from
        // main, 1 from side). The dot sits on lane 0; lane 1 must be
        // exposed as a merging lane so the renderer can draw a closing
        // curve from the top of the row into the dot.
        //   main  ← (parents: p)
        //   side  ← (parents: p)
        //   p     ← root
        let commits = [
            commit("main", parents: ["p"]),
            commit("side", parents: ["p"]),
            commit("p",    parents: []),
        ]
        let layout = CommitGraphLayoutEngine.compute(commits: commits)
        XCTAssertEqual(layout.rows[2].lane, 0)
        XCTAssertEqual(
            layout.rows[2].mergingLanes, [1],
            "side branch on lane 1 should be flagged as merging into p"
        )
        XCTAssertTrue(
            layout.rows[0].mergingLanes.isEmpty,
            "ordinary commits have no merging lanes"
        )
        XCTAssertTrue(layout.rows[1].mergingLanes.isEmpty)
    }

    func testParentAlreadyShownAboveDoesNotDangleALane() {
        // Non-topological order (e.g. a stale date-ordered log): `child`'s
        // parent `base` was already emitted on an earlier row. Opening a
        // lane for it would leave a line running to the bottom of the view
        // forever. The lane must terminate at `child` instead, so the
        // unrelated `tip` below can reuse lane 0 rather than spilling onto
        // a second lane.
        //   base  ← root            (row 0)
        //   child ← (parent: base)  (row 1, parent is ABOVE it)
        //   tip   ← root            (row 2, unrelated)
        let commits = [
            commit("base",  parents: []),
            commit("child", parents: ["base"]),
            commit("tip",   parents: []),
        ]
        let layout = CommitGraphLayoutEngine.compute(commits: commits)
        XCTAssertEqual(
            layout.maxLanes, 1,
            "an already-shown parent must not open a dangling second lane"
        )
        XCTAssertEqual(layout.rows.map(\.lane), [0, 0, 0])
    }

    func testThroughLanesPopulatedForPassingBranch() {
        // history:
        //   m  ← (parents: c2, side1)
        //   c2 ← (parents: c1)            ← `side1` lane passes through this row
        //   c1 ← (parents: cRoot)
        //   side1 ← (parents: cRoot)
        //   cRoot ← root
        let commits = [
            commit("m",     parents: ["c2", "side1"]),
            commit("c2",    parents: ["c1"]),
            commit("c1",    parents: ["cRoot"]),
            commit("side1", parents: ["cRoot"]),
            commit("cRoot", parents: []),
        ]
        let layout = CommitGraphLayoutEngine.compute(commits: commits)
        // c2 sits on lane 0; side1's lane (1) should be in throughLanes
        // because side1 is still active but doesn't touch c2.
        XCTAssertEqual(layout.rows[1].lane, 0)
        XCTAssertTrue(
            layout.rows[1].throughLanes.contains(1),
            "expected side1 lane to pass through c2 row, got \(layout.rows[1].throughLanes)"
        )
    }
}
