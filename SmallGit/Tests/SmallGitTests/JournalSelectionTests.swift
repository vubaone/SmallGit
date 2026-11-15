import XCTest
@testable import SmallGit

/// Exercises `JournalViewModel`'s multi-selection model: the single /
/// toggle / range click behaviours and the `contiguousSelection` gate
/// that decides when a range squash is offered.
@MainActor
final class JournalSelectionTests: XCTestCase {

    /// Newest-first synthetic commits (`c5` … `c1`), matching the journal's
    /// display order.
    private func makeViewModel(count: Int = 5) -> JournalViewModel {
        let vm = JournalViewModel(coordinator: CacheCoordinator())
        vm.commits = (0..<count).reversed().map { i in
            GitCommit(
                hash: "hash\(i)",
                shortHash: "h\(i)",
                subject: "c\(i)",
                authorName: "T",
                authorEmail: "t@x",
                date: Date(timeIntervalSince1970: TimeInterval(i)),
                refs: ""
            )
        }
        return vm
    }

    func testSelectOnlyCollapsesToSingle() {
        let vm = makeViewModel()
        vm.toggleSelection(vm.commits[0])
        vm.toggleSelection(vm.commits[1])
        XCTAssertEqual(vm.selectedCommitIDs.count, 2)

        vm.selectOnly(vm.commits[3])
        XCTAssertEqual(vm.selectedCommitIDs, [vm.commits[3].id])
        XCTAssertEqual(vm.selectedCommitID, vm.commits[3].id)
        XCTAssertEqual(vm.selectionAnchorID, vm.commits[3].id)
    }

    func testToggleAddsAndRemoves() {
        let vm = makeViewModel()
        vm.toggleSelection(vm.commits[1])
        XCTAssertTrue(vm.isSelected(vm.commits[1]))
        vm.toggleSelection(vm.commits[1])
        XCTAssertFalse(vm.isSelected(vm.commits[1]))
        XCTAssertTrue(vm.selectedCommitIDs.isEmpty)
    }

    func testExtendSelectionCoversInclusiveRange() {
        let vm = makeViewModel()
        vm.selectOnly(vm.commits[1])   // anchor
        vm.extendSelection(to: vm.commits[3])
        XCTAssertEqual(
            vm.selectedCommitIDs,
            Set([vm.commits[1].id, vm.commits[2].id, vm.commits[3].id])
        )
        // Focused commit follows the shift-click target.
        XCTAssertEqual(vm.selectedCommitID, vm.commits[3].id)
    }

    func testExtendWithoutAnchorFallsBackToSingle() {
        let vm = makeViewModel()
        vm.clearSelection()
        vm.extendSelection(to: vm.commits[2])
        XCTAssertEqual(vm.selectedCommitIDs, [vm.commits[2].id])
    }

    func testContiguousSelectionNilForFewerThanTwo() {
        let vm = makeViewModel()
        XCTAssertNil(vm.contiguousSelection)
        vm.selectOnly(vm.commits[0])
        XCTAssertNil(vm.contiguousSelection, "single selection is not a squash range")
    }

    func testContiguousSelectionReturnsRangeOldestLast() {
        let vm = makeViewModel()
        vm.selectOnly(vm.commits[1])
        vm.extendSelection(to: vm.commits[3])
        let range = vm.contiguousSelection
        XCTAssertEqual(range?.map(\.id), [
            vm.commits[1].id, vm.commits[2].id, vm.commits[3].id
        ])
        // Display order is newest-first, so the oldest selected commit is
        // last — the base of a squash rebase.
        XCTAssertEqual(range?.last?.id, vm.commits[3].id)
    }

    func testContiguousSelectionNilWhenGapped() {
        let vm = makeViewModel()
        vm.toggleSelection(vm.commits[0])
        vm.toggleSelection(vm.commits[2]) // skips index 1 → not contiguous
        XCTAssertNil(vm.contiguousSelection)
    }

    func testContiguousSelectionRespectsFilteredOrder() {
        // Contiguity is judged against the *filtered* view. Selecting c4
        // and c2 is gapped in the full list (c3 sits between them), but
        // once a filter hides c3 they become adjacent in the displayed
        // list and should qualify as a squash range.
        let vm = makeViewModel()
        vm.toggleSelection(vm.commits[0]) // c4 (newest)
        vm.toggleSelection(vm.commits[2]) // c2 — gapped by c3
        XCTAssertNil(vm.contiguousSelection, "gapped in the full list")

        vm.filterText = "c"               // matches all — still gapped
        XCTAssertNil(vm.contiguousSelection)

        // Hide c3 so c4 and c2 are neighbours in the filtered view. The
        // filter matches c4, c2, c1, c0 but not c3.
        vm.filterText = "4"
        XCTAssertNil(vm.contiguousSelection, "filter now hides one of the selected commits")
    }
}
import XCTest
@testable import SmallGit

/// The working-tree node's selection, which is deliberately not part of the
/// commit selection.
///
/// Uncommitted work has no hash, so letting it into `selectedCommitIDs`
/// would offer it to every range operation the Journal has — squash,
/// cherry-pick, reset — each of which would then need to special-case it.
/// These pin the boundary in both directions.
@MainActor
final class JournalWorkingTreeSelectionTests: XCTestCase {

    private func makeViewModel() -> JournalViewModel {
        JournalViewModel(coordinator: CacheCoordinator(memoryCache: MemoryCache(), diskCache: DiskCache()))
    }

    private func commit(_ hash: String, _ subject: String) -> GitCommit {
        GitCommit(
            hash: hash, shortHash: String(hash.prefix(7)), subject: subject,
            authorName: "T", authorEmail: "t@x", date: Date(), refs: ""
        )
    }

    func testSelectingTheWorkingTreeClearsTheCommitSelection() {
        let vm = makeViewModel()
        let a = commit("aaaaaaa1", "one")
        vm.selectOnly(a)
        XCTAssertEqual(vm.selectedCommitIDs, [a.id])

        vm.selectWorkingTree()
        XCTAssertTrue(vm.workingTreeSelected)
        XCTAssertTrue(vm.selectedCommitIDs.isEmpty)
        XCTAssertNil(vm.selectedCommitID, "no commit is selected, so nothing downstream loads one")
    }

    func testSelectingACommitClearsTheWorkingTree() {
        let vm = makeViewModel()
        vm.selectWorkingTree()
        vm.selectOnly(commit("bbbbbbb2", "two"))
        XCTAssertFalse(vm.workingTreeSelected)

        vm.selectWorkingTree()
        vm.toggleSelection(commit("ccccccc3", "three"))
        XCTAssertFalse(vm.workingTreeSelected, "cmd-click is a commit selection too")
    }

    func testClearingSelectionClearsBoth() {
        let vm = makeViewModel()
        vm.selectWorkingTree()
        vm.clearSelection()
        XCTAssertFalse(vm.workingTreeSelected)
    }
}
