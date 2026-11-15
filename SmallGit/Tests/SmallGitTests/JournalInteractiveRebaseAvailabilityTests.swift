import XCTest
@testable import SmallGit

/// The gate in front of the Journal's interactive rebase.
///
/// The clicked commit is always the *base* — git replays `<commit>..HEAD` onto
/// it — but where the commit sits decides what that range holds, and the menu
/// has to name which of the two it is about to do: replay the commits after
/// this one, or replay HEAD's own work onto another line of history. The one
/// thing that is silently wrong either way is a merge inside the range, which
/// `rebase -i` drops from the todo and replays inline.
@MainActor
final class JournalInteractiveRebaseAvailabilityTests: XCTestCase {

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

    private func blockedReason(
        _ availability: JournalViewModel.InteractiveRebaseAvailability
    ) -> String? {
        if case .blocked(let reason) = availability { return reason }
        return nil
    }

    // MARK: - The happy path

    /// The base itself is excluded: rebasing from c3 replays c4 and c5 onto
    /// it, newest first.
    func testReplaysEverythingAfterTheClickedCommit() {
        let vm = linearViewModel()
        guard case .fromHere(let replayed) =
                vm.interactiveRebaseAvailability(from: vm.commits[2]) else {
            return XCTFail("expected a replayable range")
        }
        XCTAssertEqual(replayed.map(\.hash), ["hash5", "hash4"])
    }

    // MARK: - The blocks

    func testHeadItselfHasNothingToReplay() {
        let vm = linearViewModel()
        XCTAssertEqual(
            blockedReason(vm.interactiveRebaseAvailability(from: vm.commits[0])),
            "Rebase Interactive — nothing comes after this commit"
        )
    }

    /// A row from a second ticked ref that HEAD does not descend from — the
    /// tip of another branch, graphed beside HEAD. Taking it as the base and
    /// replaying HEAD's own commits onto it is the ordinary way to move a
    /// branch onto an updated base, so it is offered rather than refused; the
    /// range starts at the merge-base, which the loaded window cannot be
    /// trusted to reach, so no commit list travels with the answer.
    func testCommitOffHeadHistoryOffersTheOntoRebase() {
        let vm = linearViewModel()
        let stray = commit(9, parents: [2], refs: "origin/feature")
        vm.commits.insert(stray, at: 1)
        XCTAssertEqual(vm.interactiveRebaseAvailability(from: stray), .onto)
    }

    /// The two readings must stay distinguishable: a commit on HEAD's history
    /// is never the "onto another branch" case, however it is reached.
    func testACommitOnHeadIsNeverTheOntoCase() {
        let vm = linearViewModel()
        for row in vm.commits.dropFirst() {
            XCTAssertNotEqual(vm.interactiveRebaseAvailability(from: row), .onto, row.shortHash)
        }
    }

    /// `rebase -i` omits merges from the todo and replays their side branch
    /// inline, so the range is refused rather than silently flattened.
    func testMergeInTheRangeIsBlocked() {
        let vm = JournalViewModel(coordinator: CacheCoordinator())
        vm.commits = [
            commit(5, parents: [4, 9], refs: "HEAD -> main"),
            commit(9, parents: [2]),
            commit(4, parents: [3]),
            commit(3, parents: [2]),
            commit(2, parents: []),
        ]
        XCTAssertEqual(
            blockedReason(vm.interactiveRebaseAvailability(from: vm.commits[3])),
            "Rebase Interactive — merge h5 would be flattened"
        )
    }

    /// A rewrite leaves the displayed hits pointing at SHAs that no longer
    /// exist, so the command is withheld while results are shown.
    func testBlockedWhileSearchResultsAreShown() {
        let vm = linearViewModel()
        vm.searchResults = JournalSearchResults(
            query: "c",
            scope: .message,
            commits: vm.commits,
            failed: false
        )
        XCTAssertEqual(
            blockedReason(vm.interactiveRebaseAvailability(from: vm.commits[2])),
            "Rebase Interactive — not while search results are shown"
        )
    }
}
