import XCTest
@testable import SmallGit

/// The gate in front of the Journal's range squash.
///
/// `git rebase -i` will happily do something plausible and wrong with a
/// range that isn't a straight run of HEAD's own history — silently folding
/// only part of it, or moving the branch onto a commit from somewhere else —
/// so every condition is checked before the command is offered, and the
/// reason is shown when it isn't.
@MainActor
final class JournalSquashAvailabilityTests: XCTestCase {

    private func commit(
        _ n: Int,
        parents: [Int],
        refs: String = ""
    ) -> GitCommit {
        GitCommit(
            hash: "hash\(n)",
            shortHash: "h\(n)",
            subject: "c\(n)",
            authorName: "T",
            authorEmail: "t@x",
            date: Date(timeIntervalSince1970: TimeInterval(n)),
            refs: refs,
            parentHashes: parents.map { "hash\($0)" }
        )
    }

    /// A linear five-commit history, newest first, checked out at the tip.
    private func linearViewModel() -> JournalViewModel {
        let vm = JournalViewModel(coordinator: CacheCoordinator())
        vm.commits = [
            commit(5, parents: [4], refs: "HEAD -> main"),
            commit(4, parents: [3]),
            commit(3, parents: [2]),
            commit(2, parents: [1]),
            commit(1, parents: []),
        ]
        return vm
    }

    private func select(_ vm: JournalViewModel, _ indices: [Int]) {
        vm.selectedCommitIDs = Set(indices.map { vm.commits[$0].id })
    }

    private func blockedReason(_ availability: JournalViewModel.SquashAvailability) -> String? {
        if case .blocked(let reason) = availability { return reason }
        return nil
    }

    // MARK: - The happy path

    func testAdjacentCommitsOnHeadAreSquashable() {
        let vm = linearViewModel()
        select(vm, [1, 2])
        guard case .ready(let range) = vm.squashAvailability(rightClicked: vm.commits[1]) else {
            return XCTFail("expected a squashable range")
        }
        XCTAssertEqual(range.map(\.hash), ["hash4", "hash3"])
    }

    /// The reported bug: ticking a second branch in the Branches panel made
    /// Squash disappear from the menu, even for a run sitting on HEAD.
    func testSquashSurvivesASecondRefBeingGraphed() async {
        let vm = linearViewModel()
        await vm.setRefSelection(JournalRefSelection(head: true, refs: ["origin/main"]))
        // `setRefSelection` reloads, which clears the synthetic log.
        vm.commits = linearViewModel().commits
        select(vm, [0, 1])

        XCTAssertFalse(vm.refSelection.isHeadOnly)
        guard case .ready(let range) = vm.squashAvailability(rightClicked: vm.commits[0]) else {
            return XCTFail("expected a squashable range: \(vm.squashAvailability(rightClicked: vm.commits[0]))")
        }
        XCTAssertEqual(range.map(\.hash), ["hash5", "hash4"])
    }

    /// Pushed commits are squashable — `prepareSquash` detects them and the
    /// sheet warns, rather than the menu hiding the command.
    func testPublishedCommitsAreStillOffered() {
        let vm = linearViewModel()
        vm.unpushedHashes = []
        select(vm, [1, 2])
        guard case .ready = vm.squashAvailability(rightClicked: vm.commits[1]) else {
            return XCTFail("a published range should still be offered")
        }
    }

    // MARK: - Nothing to say

    func testSingleSelectionOffersNoSquashRow() {
        let vm = linearViewModel()
        select(vm, [2])
        XCTAssertEqual(vm.squashAvailability(rightClicked: vm.commits[2]), .unavailable)
    }

    /// Right-clicking a row outside the selection is a menu about that row,
    /// not about the selection somewhere else in the list.
    func testRowOutsideTheSelectionOffersNoSquashRow() {
        let vm = linearViewModel()
        select(vm, [0, 1])
        XCTAssertEqual(vm.squashAvailability(rightClicked: vm.commits[4]), .unavailable)
    }

    // MARK: - Blocked, with a reason

    func testBrokenSelectionSaysSo() {
        let vm = linearViewModel()
        select(vm, [0, 3])
        XCTAssertEqual(
            blockedReason(vm.squashAvailability(rightClicked: vm.commits[0])),
            "Squash — select an unbroken run of commits"
        )
    }

    func testMergeCommitInTheRangeSaysSo() {
        let vm = linearViewModel()
        vm.commits[1] = commit(4, parents: [3, 9])
        select(vm, [0, 1])
        XCTAssertEqual(
            blockedReason(vm.squashAvailability(rightClicked: vm.commits[0])),
            "Squash — a merge commit can't be folded in"
        )
    }

    /// Two rows that look adjacent but aren't parent and child — which is
    /// what a second ticked branch's commits look like interleaved in the
    /// log, and what `rebase -i` cannot fold.
    func testRangeThatIsNotAParentChainSaysSo() {
        let vm = linearViewModel()
        vm.commits.insert(commit(99, parents: [50]), at: 1)
        select(vm, [0, 1])
        XCTAssertEqual(
            blockedReason(vm.squashAvailability(rightClicked: vm.commits[0])),
            "Squash — the selection isn't one run of history"
        )
    }

    /// A straight run that belongs to some other ref in the graph. The
    /// rebase would rewrite HEAD, which these commits are not on.
    func testRangeOffHeadsHistorySaysSo() {
        let vm = JournalViewModel(coordinator: CacheCoordinator())
        vm.commits = [
            commit(5, parents: [4], refs: "HEAD -> main"),
            commit(4, parents: [3]),
            // A side branch: linked to each other, reachable from nothing
            // HEAD can see.
            commit(21, parents: [20], refs: "origin/other"),
            commit(20, parents: []),
        ]
        select(vm, [2, 3])
        XCTAssertEqual(
            blockedReason(vm.squashAvailability(rightClicked: vm.commits[2])),
            "Squash — these commits aren't on HEAD"
        )
    }

    /// With nothing checked out in the loaded window there is no history to
    /// rewrite against.
    func testGraphWithoutHeadSaysSo() {
        let vm = JournalViewModel(coordinator: CacheCoordinator())
        vm.commits = [
            commit(5, parents: [4], refs: "origin/main"),
            commit(4, parents: [3]),
            commit(3, parents: []),
        ]
        select(vm, [0, 1])
        XCTAssertEqual(
            blockedReason(vm.squashAvailability(rightClicked: vm.commits[0])),
            "Squash — these commits aren't on HEAD"
        )
    }

    func testSearchResultsSayNotAvailable() {
        let vm = linearViewModel()
        let hits = [vm.commits[0], vm.commits[1]]
        vm.searchResults = JournalSearchResults(
            query: "c", scope: .message, commits: hits, failed: false
        )
        vm.selectedCommitIDs = Set(hits.map(\.id))
        XCTAssertEqual(
            blockedReason(vm.squashAvailability(rightClicked: hits[0])),
            "Squash — not while search results are shown"
        )
    }

    // MARK: - Ancestry

    /// `origin/HEAD` sits on whatever the remote's default branch points at
    /// and is not the checkout. Reading it as one picked the wrong row to
    /// walk ancestry from.
    func testOriginHeadIsNotTheCheckout() {
        XCTAssertFalse(commit(1, parents: [], refs: "origin/HEAD, origin/main").isHead)
        XCTAssertTrue(commit(1, parents: [], refs: "HEAD -> main, origin/main").isHead)
        XCTAssertTrue(commit(1, parents: [], refs: "HEAD").isHead)
    }

    func testAncestryWalksThroughMergeParents() {
        let vm = JournalViewModel(coordinator: CacheCoordinator())
        vm.commits = [
            commit(5, parents: [4, 7], refs: "HEAD -> main"),
            commit(7, parents: [6]),
            commit(6, parents: []),
            commit(4, parents: []),
        ]
        XCTAssertTrue(vm.isOnHeadHistory("hash6"))
        XCTAssertTrue(vm.isOnHeadHistory("hash5"))
        XCTAssertFalse(vm.isOnHeadHistory("hash99"))
    }
}
