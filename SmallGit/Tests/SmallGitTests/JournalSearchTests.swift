import XCTest
@testable import SmallGit

/// Exercises the git-backed search plumbing added around the Journal's
/// filter field: scope → git flag mapping, and how active search results
/// replace the loaded log as the journal's data source.
@MainActor
final class JournalSearchTests: XCTestCase {

    private func makeCommit(_ i: Int, subject: String = "") -> GitCommit {
        GitCommit(
            hash: "hash\(i)", shortHash: "h\(i)",
            subject: subject.isEmpty ? "c\(i)" : subject,
            authorName: "T", authorEmail: "t@x",
            date: Date(timeIntervalSince1970: TimeInterval(i)), refs: ""
        )
    }

    private func makeViewModel() -> JournalViewModel {
        let vm = JournalViewModel(coordinator: CacheCoordinator())
        vm.commits = (0..<5).reversed().map { makeCommit($0) }
        return vm
    }

    // MARK: - Scope mapping

    func testLocalScopeHasNoGitMode() {
        XCTAssertNil(JournalSearchScope.local.gitMode)
    }

    func testGitScopesMapToTheRightMode() {
        XCTAssertEqual(JournalSearchScope.message.gitMode, .message)
        XCTAssertEqual(JournalSearchScope.author.gitMode, .author)
        XCTAssertEqual(JournalSearchScope.content.gitMode, .content)
        XCTAssertEqual(JournalSearchScope.contentRegex.gitMode, .contentRegex)
    }

    // MARK: - Results replace the loaded log

    func testSearchResultsReplaceFilteredCommits() {
        let vm = makeViewModel()
        let hit = makeCommit(99, subject: "needle")
        vm.searchResults = JournalSearchResults(
            query: "needle", scope: .message, commits: [hit], failed: false
        )
        XCTAssertEqual(vm.filteredCommits.map(\.hash), ["hash99"])
    }

    func testLocalFilterDoesNotReFilterSearchResults() {
        let vm = makeViewModel()
        let hit = makeCommit(99, subject: "needle")
        vm.searchResults = JournalSearchResults(
            query: "needle", scope: .message, commits: [hit], failed: false
        )
        // A filter text that matches nothing must not hide search hits.
        vm.filterText = "zzz-no-match"
        XCTAssertEqual(vm.filteredCommits.count, 1)
    }

    func testNonLocalScopeDisablesLiveFilter() {
        let vm = makeViewModel()
        vm.searchScope = .message
        // Text is a pending git query in this scope, not a live filter —
        // the loaded list must stay fully visible until ⏎.
        vm.filterText = "zzz-no-match"
        XCTAssertEqual(vm.filteredCommits.count, 5)
        XCTAssertEqual(vm.hiddenCount, 0)
    }

    func testHiddenCountIsZeroDuringSearch() {
        let vm = makeViewModel()
        vm.filterText = "zzz-no-match"
        XCTAssertEqual(vm.hiddenCount, 5)
        vm.searchResults = JournalSearchResults(
            query: "q", scope: .message, commits: [], failed: false
        )
        XCTAssertEqual(vm.hiddenCount, 0)
    }

    func testClearSearchRestoresLoadedLog() {
        let vm = makeViewModel()
        vm.searchResults = JournalSearchResults(
            query: "q", scope: .message, commits: [makeCommit(99)], failed: false
        )
        vm.clearSearch()
        XCTAssertNil(vm.searchResults)
        XCTAssertEqual(vm.filteredCommits.count, 5)
        XCTAssertTrue(vm.selectedCommitIDs.isEmpty)
    }

    func testBranchFilterSwitchDropsSearchResults() async {
        let vm = makeViewModel()
        vm.searchResults = JournalSearchResults(
            query: "q", scope: .message, commits: [makeCommit(99)], failed: false
        )
        await vm.setBranchFilter("feature/x")
        XCTAssertNil(vm.searchResults)
    }
}
