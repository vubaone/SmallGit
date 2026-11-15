import XCTest
@testable import SmallGit

final class DiffPatchBuilderTests: XCTestCase {

    func testBuildSingleHunkPatch() {
        let hunk = DiffHunk(
            oldStart: 1, oldCount: 3,
            newStart: 1, newCount: 4,
            lines: [
                DiffLine(type: .context, content: "line one"),
                DiffLine(type: .del,     content: "old line"),
                DiffLine(type: .add,     content: "new line"),
                DiffLine(type: .add,     content: "added"),
                DiffLine(type: .context, content: "line three")
            ]
        )
        let patch = DiffPatchBuilder.buildPatch(file: "src/x.swift", hunk: hunk) ?? ""
        let expected = """
        diff --git a/src/x.swift b/src/x.swift
        --- a/src/x.swift
        +++ b/src/x.swift
        @@ -1,3 +1,4 @@
         line one
        -old line
        +new line
        +added
         line three

        """
        XCTAssertEqual(patch, expected)
    }

    func testEmptyHunksReturnNil() {
        XCTAssertNil(DiffPatchBuilder.buildPatch(file: "x.swift", hunks: []))
    }

    func testCountsRecomputedFromBody() {
        // Header is stale on purpose — body has 1 context + 2 adds = old:1 new:3
        let hunk = DiffHunk(
            oldStart: 5, oldCount: 999,
            newStart: 5, newCount: 999,
            lines: [
                DiffLine(type: .context, content: "ctx"),
                DiffLine(type: .add,     content: "alpha"),
                DiffLine(type: .add,     content: "beta")
            ]
        )
        let patch = DiffPatchBuilder.buildPatch(file: "f", hunk: hunk) ?? ""
        XCTAssertTrue(patch.contains("@@ -5,1 +5,3 @@"))
    }
}
