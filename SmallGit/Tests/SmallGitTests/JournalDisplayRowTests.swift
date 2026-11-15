import XCTest
@testable import SmallGit

/// Covers the SmartGit-style filtered journal: matches stay as commit
/// rows, the commits between them collapse into one row each, and the
/// graph keeps being laid out over the whole history underneath.
@MainActor
final class JournalDisplayRowTests: XCTestCase {

    /// Linear history, newest first: c0 → c1 → … Each commit's parent is
    /// the next one in the array, so the layout is a single lane.
    private func hash(_ i: Int) -> String { String(format: "%040x", i) }

    private func linearHistory(_ count: Int, needleEvery: Int = 10) -> [GitCommit] {
        var out: [GitCommit] = []
        for i in 0..<count {
            let subject: String = i % needleEvery == 0 ? "commit \(i) vubl" : "commit \(i)"
            let parents: [String] = i + 1 < count ? [hash(i + 1)] : []
            let when = Date(timeIntervalSince1970: TimeInterval(10_000 - i))
            out.append(GitCommit(
                hash: hash(i),
                shortHash: String(format: "%07x", i),
                subject: subject,
                authorName: "Someone",
                authorEmail: "someone@example.com",
                date: when,
                refs: i == 3 ? "origin/feature-x" : "",
                parentHashes: parents
            ))
        }
        return out
    }

    /// The same commit with a different `%D` — what a push, a tag or a
    /// branch delete does to a row that is otherwise untouched.
    private func withRefs(_ commit: GitCommit, _ refs: String) -> GitCommit {
        GitCommit(
            hash: commit.hash,
            shortHash: commit.shortHash,
            subject: commit.subject,
            authorName: commit.authorName,
            authorEmail: commit.authorEmail,
            date: commit.date,
            refs: refs,
            parentHashes: commit.parentHashes
        )
    }

    private func makeVM(_ commits: [GitCommit]) -> JournalViewModel {
        let vm = JournalViewModel(coordinator: CacheCoordinator())
        vm.commits = commits
        return vm
    }

    func testUnfilteredJournalIsOneRowPerCommit() {
        let vm = makeVM(linearHistory(30))
        XCTAssertEqual(vm.displayRows.count, 30)
        XCTAssertTrue(vm.displayRows.allSatisfy { $0.commit != nil })
    }

    func testFilterCollapsesTheGapsInsteadOfDeletingThem() {
        let vm = makeVM(linearHistory(30))   // matches at 0, 10, 20
        vm.filterText = "vubl"

        let rows = vm.displayRows
        XCTAssertEqual(rows.compactMap(\.commit).count, 3, "three commits match")

        // c0, gap(1...9), c10, gap(11...19), c20, gap(21...29)
        XCTAssertEqual(rows.count, 6)
        guard case .collapsed(let first) = rows[1] else {
            return XCTFail("row after the first match should be a collapsed run")
        }
        XCTAssertEqual(first.count, 9)
        XCTAssertEqual(first.firstIndex, 1)
        XCTAssertEqual(first.lastIndex, 9)
    }

    /// The bug behind the report: laying the graph out over the filtered
    /// subsequence opened a lane per missing parent, so the column grew
    /// until it swallowed the commit subject.
    func testFilteringDoesNotInflateTheGraphsLaneCount() {
        let vm = makeVM(linearHistory(200))
        XCTAssertEqual(vm.graphLayout.maxLanes, 1, "linear history is one lane")

        vm.filterText = "vubl"
        XCTAssertEqual(vm.graphLayout.maxLanes, 1,
            "a filter must not change the topology the graph is drawn from")
        XCTAssertEqual(vm.graphLayout.rows.count, 200,
            "the layout still covers every loaded commit")
    }

    /// A branch tip buried between two matches has to stay findable.
    func testCollapsedRunCarriesTheRefsItHides() {
        let vm = makeVM(linearHistory(30))
        vm.filterText = "vubl"

        guard case .collapsed(let run) = vm.displayRows[1] else {
            return XCTFail("expected a collapsed run")
        }
        XCTAssertEqual(run.refs.map(\.name), ["origin/feature-x"])
    }

    func testCollapsedRunGraphUsesTheFullHistorysLanes() {
        let vm = makeVM(linearHistory(30))
        vm.filterText = "vubl"

        guard case .collapsed(let run) = vm.displayRows[1] else {
            return XCTFail("expected a collapsed run")
        }
        // A single-lane history: the gap has lane 0 running in and out.
        XCTAssertEqual(run.gap.topLanes, [0])
        XCTAssertEqual(run.gap.bottomLanes, [0])
    }

    func testExpandingARunRevealsItsCommits() {
        let vm = makeVM(linearHistory(30))
        vm.filterText = "vubl"
        guard case .collapsed(let run) = vm.displayRows[1] else {
            return XCTFail("expected a collapsed run")
        }

        vm.expandRun(run)
        let rows = vm.displayRows
        XCTAssertEqual(rows.compactMap(\.commit).count, 3 + 9,
            "the nine hidden commits should now be ordinary rows")
        XCTAssertEqual(rows[1].commit?.subject, "commit 1")
    }

    func testChangingTheQueryForgetsExpansions() {
        let vm = makeVM(linearHistory(30))
        vm.filterText = "vubl"
        guard case .collapsed(let run) = vm.displayRows[1] else {
            return XCTFail("expected a collapsed run")
        }
        vm.expandRun(run)
        XCTAssertEqual(vm.displayRows.compactMap(\.commit).count, 12)

        vm.filterText = "commit 1"
        let rows = vm.displayRows
        XCTAssertTrue(rows.contains { if case .collapsed = $0 { return true } else { return false } },
            "a new query starts from a fully collapsed view")
        XCTAssertEqual(rows.compactMap(\.commit).map(\.subject).first, "commit 1")
    }

    /// Clearing the field and pasting the same query back is a new search,
    /// not a return to the old one — the gaps opened last time must not
    /// come back open and bury the one match under unrelated commits.
    func testRetypingTheSameQueryForgetsExpansions() {
        let vm = makeVM(linearHistory(30))
        vm.filterText = "vubl"
        guard case .collapsed(let run) = vm.displayRows[1] else {
            return XCTFail("expected a collapsed run")
        }
        vm.expandRun(run)
        XCTAssertEqual(vm.displayRows.compactMap(\.commit).count, 12)

        vm.filterText = ""
        _ = vm.displayRows
        vm.filterText = "vubl"
        XCTAssertEqual(vm.displayRows.compactMap(\.commit).count, 3,
            "only the matches should be commit rows again")
    }

    /// Refs are part of SmartGit's default match set.
    func testFilterMatchesRefs() {
        let vm = makeVM(linearHistory(30))
        vm.filterText = "feature-x"
        XCTAssertEqual(vm.filteredCommits.map(\.subject), ["commit 3"])
    }

    /// Two matches with hidden commits between them look adjacent on
    /// screen but aren't — squashing that range would rewrite everything
    /// in the gap.
    func testSquashRangeRejectsMatchesThatAreNotReallyAdjacent() {
        let vm = makeVM(linearHistory(30))
        vm.filterText = "vubl"
        let matches = vm.filteredCommits
        vm.selectedCommitIDs = [matches[0].id, matches[1].id]
        XCTAssertNil(vm.contiguousSelection,
            "commits 0 and 10 are not a contiguous range")

        // Neighbours in real history still squash.
        vm.selectedCommitIDs = [vm.commits[0].id, vm.commits[1].id]
        XCTAssertEqual(vm.contiguousSelection?.count, 2)
    }

    /// A push moves `origin/<branch>` onto the commit it just sent and
    /// changes nothing else: same commits, same count, same endpoints.
    /// The row cache is keyed on the graph fingerprint, which is blind to
    /// all of that, so it used to hand back the rows it had built before
    /// the push — `origin/<branch>` still drawn on the commit the remote
    /// used to be at, with the local branch chip a row above it, which is
    /// exactly what a branch that has not been pushed looks like.
    func testRowsFollowARefThatMovedWithoutTheHistory() {
        var history = linearHistory(30)
        let vm = makeVM(history)
        XCTAssertEqual(vm.displayRows[3].commit?.refs, "origin/feature-x")

        // The push: the ref jumps from commit 3 to the tip.
        history[3] = withRefs(history[3], "")
        history[0] = withRefs(history[0], "HEAD -> feature-x, origin/feature-x")
        vm.commits = history

        XCTAssertEqual(vm.displayRows[0].commit?.refs,
            "HEAD -> feature-x, origin/feature-x")
        XCTAssertEqual(vm.displayRows[3].commit?.refs, "",
            "the chip has to leave the commit the remote used to be at")
    }

    /// The same move seen through a filter, where the rows the ref lands
    /// on are collapsed runs rather than commit rows.
    func testCollapsedRunsFollowARefThatMoved() {
        var history = linearHistory(30)
        let vm = makeVM(history)
        vm.filterText = "vubl"          // matches commits 0, 10, 20
        guard case .collapsed(let before) = vm.displayRows[1] else {
            return XCTFail("expected a collapsed run")
        }
        XCTAssertEqual(before.refs.map(\.name), ["origin/feature-x"],
            "the gap surfaces the ref buried in it")

        history[3] = withRefs(history[3], "")
        vm.commits = history

        guard case .collapsed(let after) = vm.displayRows[1] else {
            return XCTFail("expected a collapsed run")
        }
        XCTAssertTrue(after.refs.isEmpty,
            "the gap has nothing left to surface")
    }

    /// A git-backed search shows commits from all over history; a
    /// topology drawn over them is invented, so it stays flat.
    func testSearchResultsGetAFlatGraph() {
        let vm = makeVM(linearHistory(30))
        vm.searchResults = JournalSearchResults(
            query: "vubl", scope: .message,
            commits: [vm.commits[0], vm.commits[17]], failed: false
        )
        XCTAssertEqual(vm.graphLayout.maxLanes, 1)
        XCTAssertEqual(vm.graphLayout.rows.count, 2)
        XCTAssertEqual(vm.displayRows.count, 2)
    }
}
