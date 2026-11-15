import XCTest
@testable import SmallGit

/// Exercises `JournalViewModel`'s incremental commit-paging against a
/// real git repo with more commits than fit in a single page.
@MainActor
final class JournalPaginationTests: XCTestCase {

    private func makeRepoWithCommits(_ count: Int) async throws -> (path: String, root: URL) {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-pagetest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: root.path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: root.path, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: root.path, args: ["config", "commit.gpgsign", "false"])

        let file = root.appendingPathComponent("a.txt")
        for i in 1...count {
            try "v\(i)\n".write(to: file, atomically: true, encoding: .utf8)
            _ = try await runner.run(in: root.path, args: ["add", "a.txt"])
            _ = try await runner.run(in: root.path, args: ["commit", "-q", "-m", "c\(i)"])
        }
        return (root.path, root)
    }

    func testInitialLoadCapsAtPageSizeAndExposesMore() async throws {
        let pageSize = JournalViewModel.pageSize
        let total = pageSize + 30
        let repo = try await makeRepoWithCommits(total)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let coord = CacheCoordinator()
        coord.switchRepo(to: repo.path)
        let vm = JournalViewModel(coordinator: coord)

        await vm.load()
        XCTAssertEqual(vm.commits.count, pageSize,
            "initial load should cap at one page")
        XCTAssertTrue(vm.hasMore,
            "a repo with more than pageSize commits should leave hasMore=true")
    }

    func testLoadMoreAppendsAnotherPageThenStops() async throws {
        let pageSize = JournalViewModel.pageSize
        let total = pageSize + 30
        let repo = try await makeRepoWithCommits(total)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let coord = CacheCoordinator()
        coord.switchRepo(to: repo.path)
        let vm = JournalViewModel(coordinator: coord)
        await vm.load()

        await vm.loadMore()
        XCTAssertEqual(vm.commits.count, total,
            "second page should fetch the remaining 30 commits")
        XCTAssertFalse(vm.hasMore,
            "a short page means git ran out — should stop asking")

        // Calling loadMore again is a no-op once hasMore is false.
        let snapshot = vm.commits.count
        await vm.loadMore()
        XCTAssertEqual(vm.commits.count, snapshot,
            "loadMore must be a no-op after hasMore flipped to false")
    }

    func testHasMoreFalseWhenInitialLoadFitsEntireHistory() async throws {
        let repo = try await makeRepoWithCommits(5)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let coord = CacheCoordinator()
        coord.switchRepo(to: repo.path)
        let vm = JournalViewModel(coordinator: coord)

        await vm.load()
        XCTAssertEqual(vm.commits.count, 5)
        XCTAssertFalse(vm.hasMore,
            "history that fits in one page must report no further pages")
    }

    func testRefreshAfterLoadMorePreservesPageDepth() async throws {
        let pageSize = JournalViewModel.pageSize
        let total = pageSize + 30
        let repo = try await makeRepoWithCommits(total)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let coord = CacheCoordinator()
        coord.switchRepo(to: repo.path)
        let vm = JournalViewModel(coordinator: coord)
        await vm.load()
        await vm.loadMore()
        XCTAssertEqual(vm.commits.count, total)

        // A second `load()` (e.g. file-watcher refresh) must not shrink
        // the list back to a single page — the user would lose their
        // scroll position otherwise.
        await vm.load()
        XCTAssertEqual(vm.commits.count, total,
            "load() must preserve the user's paged-into depth")
    }
}
