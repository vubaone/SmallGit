import XCTest
@testable import SmallGit

/// Covers the journal's filter-aware paging: a local filter over a huge
/// repo shows only the matches inside the loaded page, so the view model
/// pages deeper on demand — bounded by a per-query depth budget and by a
/// retry budget when git keeps failing.
@MainActor
final class JournalFilterPagingTests: XCTestCase {

    /// Builds a repo of `count` empty commits, newest last. Every
    /// `matchEvery`-th commit's subject carries `needle`, so the filter's
    /// hit rate is low enough to force paging.
    private func makeRepo(
        commits count: Int,
        needle: String = "vubl",
        matchEvery: Int = 20
    ) async throws -> (path: String, root: URL) {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-filterpage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: root.path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: root.path, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: root.path, args: ["config", "commit.gpgsign", "false"])

        // Empty commits keep this fast — one git process per commit
        // instead of the write + add + commit trio.
        for i in 1...count {
            let subject = i % matchEvery == 0 ? "c\(i) \(needle)" : "c\(i)"
            _ = try await runner.run(
                in: root.path,
                args: ["commit", "-q", "--allow-empty", "-m", subject]
            )
        }
        return (root.path, root)
    }

    private func makeVM(_ path: String) -> (JournalViewModel, CacheCoordinator) {
        let coord = CacheCoordinator()
        coord.switchRepo(to: path)
        return (JournalViewModel(coordinator: coord), coord)
    }

    /// The bug: filtering shows three rows because only one page is
    /// loaded. Paging must dig past the loaded window to find the rest.
    func testFilterTopUpPagesPastTheLoadedWindow() async throws {
        let total = JournalViewModel.pageSize + 140   // 240
        let repo = try await makeRepo(commits: total)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let (vm, _) = makeVM(repo.path)
        await vm.load()
        XCTAssertEqual(vm.commits.count, JournalViewModel.pageSize)

        vm.filterText = "vubl"
        let beforeMatches = vm.filteredCommits.count
        XCTAssertLessThan(beforeMatches, total / 20,
            "one page must not already hold every match")

        await vm.loadMoreForFilter()

        XCTAssertEqual(vm.commits.count, total,
            "top-up should page to the root looking for more matches")
        XCTAssertGreaterThan(vm.filteredCommits.count, beforeMatches,
            "paging deeper must surface matches the first page hid")
        XCTAssertFalse(vm.hasMore, "history is exhausted after the top-up")
    }

    /// "Only fetch more when needed": a filter that already has plenty of
    /// matches in the loaded page must not trigger any git work.
    func testTopUpIsANoOpWhenTheFilterAlreadyHasEnoughMatches() async throws {
        let repo = try await makeRepo(commits: JournalViewModel.pageSize + 40, matchEvery: 1)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let (vm, _) = makeVM(repo.path)
        await vm.load()
        XCTAssertEqual(vm.commits.count, JournalViewModel.pageSize)

        vm.filterText = "vubl"   // matches every commit
        XCTAssertGreaterThanOrEqual(vm.filteredCommits.count, JournalViewModel.filterMatchTarget)

        await vm.loadMoreForFilter()
        XCTAssertEqual(vm.commits.count, JournalViewModel.pageSize,
            "a filter with enough matches on screen must not page further")
    }

    /// An empty filter is not a filter — the top-up entry point stays out
    /// of the way of ordinary scroll-driven paging.
    func testTopUpIgnoresAnEmptyFilter() async throws {
        let repo = try await makeRepo(commits: JournalViewModel.pageSize + 40)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let (vm, _) = makeVM(repo.path)
        await vm.load()

        vm.filterText = "   "
        await vm.loadMoreForFilter()
        XCTAssertEqual(vm.commits.count, JournalViewModel.pageSize)
    }

    /// A failing git must cost three attempts and then stop, rather than
    /// letting every re-appearing row fire another doomed fetch.
    func testPagingGivesUpAfterThreeFailuresAndRetryResumes() async throws {
        let total = JournalViewModel.pageSize + 20
        let repo = try await makeRepo(commits: total)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let (vm, coord) = makeVM(repo.path)
        await vm.load()
        XCTAssertTrue(vm.hasMore)

        // Point the coordinator at a path git can't read: every fetch
        // from here on fails.
        let broken = repo.root.appendingPathComponent("gone", isDirectory: true).path
        coord.switchRepo(to: broken)

        for _ in 0..<5 { await vm.loadMore() }
        XCTAssertEqual(vm.loadMoreFailures, JournalViewModel.maxLoadMoreFailures,
            "attempts past the third must not even reach git")
        XCTAssertFalse(vm.canLoadMore)
        XCTAssertTrue(vm.loadMoreFailed)
        XCTAssertTrue(vm.hasMore,
            "a failure is not the end of history — hasMore must stay true")
        XCTAssertEqual(vm.commits.count, JournalViewModel.pageSize)

        // An explicit retry clears the budget and picks up where it left off.
        coord.switchRepo(to: repo.path)
        await vm.loadMoreManually()
        XCTAssertEqual(vm.loadMoreFailures, 0)
        XCTAssertEqual(vm.commits.count, total)
    }

    /// The automatic top-up is capped per query, so a filter matching
    /// nothing can't walk a whole repo in the background.
    func testAutoPagingStopsAtTheDepthBudget() async throws {
        let repo = try await makeRepo(commits: JournalViewModel.pageSize + 40)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let (vm, _) = makeVM(repo.path)
        await vm.load()

        // A query nothing matches: the loop can only stop on the budget
        // or on running out of history.
        vm.filterText = "no-such-commit-anywhere"
        await vm.loadMoreForFilter()
        XCTAssertTrue(vm.filteredCommits.isEmpty)
        XCTAssertLessThanOrEqual(
            vm.commits.count,
            JournalViewModel.pageSize + JournalViewModel.filterAutoLoadLimit,
            "auto paging must respect its per-query depth budget")
    }

    func testResetPaginationClearsTheRetryBudget() async throws {
        let repo = try await makeRepo(commits: 5)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let (vm, coord) = makeVM(repo.path)
        vm.hasMore = true
        coord.switchRepo(to: repo.root.appendingPathComponent("gone").path)
        for _ in 0..<3 { await vm.loadMore() }
        XCTAssertTrue(vm.loadMoreFailed)

        vm.resetPagination()
        XCTAssertEqual(vm.loadMoreFailures, 0)
        XCTAssertTrue(vm.canLoadMore)
    }
}
