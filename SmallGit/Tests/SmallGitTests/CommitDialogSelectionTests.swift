import XCTest
@testable import SmallGit

/// Picking files in the commit dialog to review before committing.
final class CommitDialogSelectionTests: XCTestCase {

    private let order = ["a", "b", "c", "d"]

    private func click(
        _ path: String, current: Set<String>, anchor: String?,
        command: Bool = false, shift: Bool = false
    ) -> (selected: Set<String>, anchor: String?) {
        CommitDialog.selection(
            afterClicking: path, in: order, current: current, anchor: anchor,
            command: command, shift: shift
        )
    }

    func testClicksSelectToggleAndExtend() {
        var s = click("b", current: [], anchor: nil)
        XCTAssertEqual(s.selected, ["b"])

        s = click("d", current: s.selected, anchor: s.anchor, shift: true)
        XCTAssertEqual(s.selected, ["b", "c", "d"], "⇧ selects the run from the anchor")
        XCTAssertEqual(s.anchor, "b", "and leaves the anchor where it was")

        s = click("c", current: s.selected, anchor: s.anchor, command: true)
        XCTAssertEqual(s.selected, ["b", "d"], "⌘ takes one row out")

        s = click("a", current: s.selected, anchor: s.anchor, command: true, shift: true)
        XCTAssertEqual(s.selected, ["a", "b", "c", "d"], "⌘⇧ adds the run to what's there")

        s = click("c", current: s.selected, anchor: s.anchor)
        XCTAssertEqual(s.selected, ["c"], "a plain click starts over")
    }
}
