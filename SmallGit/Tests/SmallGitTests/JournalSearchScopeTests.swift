import XCTest
@testable import SmallGit

/// The filter field's git-backed scopes: which run as you type, and how
/// the journal reports a query it hasn't run yet.
@MainActor
final class JournalSearchScopeTests: XCTestCase {

    private func makeVM() -> JournalViewModel {
        let vm = JournalViewModel(coordinator: CacheCoordinator())
        vm.commits = (0..<5).map { i in
            GitCommit(
                hash: "hash\(i)", shortHash: "h\(i)",
                subject: "commit \(i)",
                authorName: "Someone", authorEmail: "someone@example.com",
                date: Date(), refs: ""
            )
        }
        return vm
    }

    /// The report: scope was Author, "vubl" typed, and every row still
    /// showed a different author because nothing had run yet.
    func testAGitScopeQueryIsPendingUntilItRuns() {
        let vm = makeVM()
        vm.searchScope = .author
        vm.filterText = "vubl"

        XCTAssertTrue(vm.hasPendingSearch)
        XCTAssertEqual(vm.filteredCommits.count, 5,
            "the journal shows the unfiltered log until the search runs")
    }

    func testResultsClearThePendingState() {
        let vm = makeVM()
        vm.searchScope = .author
        vm.filterText = "vubl"
        vm.searchResults = JournalSearchResults(
            query: "vubl", scope: .author, commits: [vm.commits[0]], failed: false
        )
        XCTAssertFalse(vm.hasPendingSearch)

        // Typing on means the shown results no longer answer the query.
        vm.filterText = "vubl2"
        XCTAssertTrue(vm.hasPendingSearch)
    }

    func testChangingScopeMakesExistingResultsPendingAgain() {
        let vm = makeVM()
        vm.searchScope = .author
        vm.filterText = "vubl"
        vm.searchResults = JournalSearchResults(
            query: "vubl", scope: .author, commits: [vm.commits[0]], failed: false
        )
        vm.searchScope = .message
        XCTAssertTrue(vm.hasPendingSearch,
            "the same text in another scope is a different question")
    }

    func testOnlyHeaderScopesSearchAsYouType() {
        let vm = makeVM()
        vm.searchScope = .message
        XCTAssertTrue(vm.searchRunsAsYouType)
        vm.searchScope = .author
        XCTAssertTrue(vm.searchRunsAsYouType)
        // -S / -G walk every commit's diff: too slow to fire per keystroke.
        vm.searchScope = .content
        XCTAssertFalse(vm.searchRunsAsYouType)
        vm.searchScope = .contentRegex
        XCTAssertFalse(vm.searchRunsAsYouType)
        vm.searchScope = .local
        XCTAssertFalse(vm.searchRunsAsYouType)
    }

    func testLocalScopeNeverReportsAPendingSearch() {
        let vm = makeVM()
        vm.filterText = "commit 1"
        XCTAssertFalse(vm.hasPendingSearch)
        XCTAssertEqual(vm.filteredCommits.count, 1, "the local filter applies as you type")
    }

    func testEmptyingTheFieldDropsStaleResults() async {
        let vm = makeVM()
        vm.searchScope = .author
        vm.searchResults = JournalSearchResults(
            query: "vubl", scope: .author, commits: [vm.commits[0]], failed: false
        )
        vm.filterText = ""

        await vm.applyFilterInput()
        XCTAssertNil(vm.searchResults)
        XCTAssertEqual(vm.filteredCommits.count, 5)
    }

    func testSwitchingBackToTheLocalFilterDropsResults() async {
        let vm = makeVM()
        vm.searchScope = .author
        vm.searchResults = JournalSearchResults(
            query: "vubl", scope: .author, commits: [vm.commits[0]], failed: false
        )
        vm.searchScope = .local
        vm.filterText = "commit 2"

        await vm.applyFilterInput()
        XCTAssertNil(vm.searchResults)
        XCTAssertEqual(vm.filteredCommits.map(\.subject), ["commit 2"])
    }

    func testRequestKeyCoversBothTextAndScope() {
        let vm = makeVM()
        vm.filterText = "vubl"
        vm.searchScope = .author
        let authorKey = vm.searchRequestKey
        vm.searchScope = .message
        XCTAssertNotEqual(authorKey, vm.searchRequestKey,
            "switching scope has to re-trigger the debounced run")
    }
}

/// The Log window's Files and Commit panes follow `selectedCommitID`
/// through `commit(withID:)`. A search result is a commit from anywhere
/// in history, so looking it up in the loaded window alone left both
/// panes on their "Select a commit" empty state.
@MainActor
final class JournalCommitLookupTests: XCTestCase {

    private func commit(_ i: Int) -> GitCommit {
        GitCommit(
            hash: "hash\(i)", shortHash: "h\(i)",
            subject: "commit \(i)",
            authorName: "Someone", authorEmail: "someone@example.com",
            date: Date(), refs: ""
        )
    }

    private func makeVM() -> JournalViewModel {
        let vm = JournalViewModel(coordinator: CacheCoordinator())
        vm.commits = (0..<5).map(commit)
        return vm
    }

    func testFindsACommitInTheLoadedLog() {
        let vm = makeVM()
        XCTAssertEqual(vm.commit(withID: "hash3")?.subject, "commit 3")
        XCTAssertNil(vm.commit(withID: "nope"))
    }

    func testFindsASearchResultThatIsNotInTheLoadedWindow() {
        let vm = makeVM()
        let ancient = GitCommit(
            hash: "hash999", shortHash: "h999",
            subject: "[ZSOCIAL02-298] Sonarqube issues",
            authorName: "VuBL", authorEmail: "vubl@example.com",
            date: Date(), refs: ""
        )
        vm.searchResults = JournalSearchResults(
            query: "vubl", scope: .message, commits: [ancient], failed: false
        )
        XCTAssertEqual(vm.commit(withID: "hash999")?.subject,
                       "[ZSOCIAL02-298] Sonarqube issues")
    }

    /// Parent navigation selects a SHA that may only exist in the loaded
    /// log while results are on screen.
    func testFallsBackToTheLoadedLogWhileResultsAreShown() {
        let vm = makeVM()
        vm.searchResults = JournalSearchResults(
            query: "vubl", scope: .message, commits: [commit(99)], failed: false
        )
        XCTAssertEqual(vm.commit(withID: "hash2")?.subject, "commit 2")
    }

    func testHiddenByAFilterStillResolves() {
        let vm = makeVM()
        vm.filterText = "commit 1"
        XCTAssertEqual(vm.filteredCommits.count, 1)
        XCTAssertEqual(vm.commit(withID: "hash4")?.subject, "commit 4",
            "a filtered-out commit is still loaded, and its diff must load")
    }
}
