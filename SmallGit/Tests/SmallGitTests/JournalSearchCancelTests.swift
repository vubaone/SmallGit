import XCTest
@testable import SmallGit

/// A `-S` search over a large repo runs for minutes. It has to be
/// stoppable, and a search the user walked away from must not be
/// reported as a failure.
@MainActor
final class JournalSearchCancelTests: XCTestCase {

    /// A repo big enough that a pickaxe search takes long enough to
    /// cancel mid-flight.
    private func makeRepo(commits count: Int) async throws -> (path: String, root: URL) {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: root.path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: root.path, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: root.path, args: ["config", "commit.gpgsign", "false"])
        let file = root.appendingPathComponent("a.txt")
        for i in 1...count {
            try String(repeating: "line \(i)\n", count: 200).write(to: file, atomically: true, encoding: .utf8)
            _ = try await runner.run(in: root.path, args: ["add", "a.txt"])
            _ = try await runner.run(in: root.path, args: ["commit", "-q", "-m", "c\(i)"])
        }
        return (root.path, root)
    }

    func testCancelStopsTheSpinnerAndPublishesNothing() async throws {
        let repo = try await makeRepo(commits: 60)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let coord = CacheCoordinator()
        coord.switchRepo(to: repo.path)
        let vm = JournalViewModel(coordinator: coord)
        vm.searchScope = .content
        vm.filterText = "line 7"

        vm.startSearch()
        vm.cancelSearch()

        XCTAssertFalse(vm.isSearching, "the spinner belongs to a search that no longer exists")
        // Give the cancelled task a moment to unwind; it must not publish.
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(vm.searchResults,
            "a search the user stopped is not a failed search")
        XCTAssertFalse(vm.isSearching)
    }

    func testClearingTheFieldStopsARunningSearch() async throws {
        let repo = try await makeRepo(commits: 40)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let coord = CacheCoordinator()
        coord.switchRepo(to: repo.path)
        let vm = JournalViewModel(coordinator: coord)
        vm.searchScope = .content
        vm.filterText = "line 7"
        vm.startSearch()

        vm.filterText = ""
        await vm.applyFilterInput()

        XCTAssertFalse(vm.isSearching)
        XCTAssertNil(vm.searchResults)
    }

    /// Typing past a running search must leave the *second* query's
    /// answer on screen and the spinner off — the first search's task
    /// unwinding later can do neither.
    func testTheSecondSearchWinsAndLeavesTheSpinnerOff() async throws {
        let repo = try await makeRepo(commits: 30)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let coord = CacheCoordinator()
        coord.switchRepo(to: repo.path)
        let vm = JournalViewModel(coordinator: coord)
        vm.searchScope = .message
        vm.filterText = "c1"
        vm.startSearch()
        vm.filterText = "c2"
        vm.startSearch()

        // Let both tasks settle: the first was cancelled, the second wins.
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertFalse(vm.isSearching)
        XCTAssertEqual(vm.searchResults?.query, "c2")
        // --grep is a substring match, so c2 and c20…c29 all qualify.
        XCTAssertEqual(vm.searchResults?.commits.count, 11)
        XCTAssertTrue(vm.searchResults?.commits.contains { $0.subject == "c2" } ?? false)
    }

    func testASuccessfulSearchStillPublishes() async throws {
        let repo = try await makeRepo(commits: 12)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let coord = CacheCoordinator()
        coord.switchRepo(to: repo.path)
        let vm = JournalViewModel(coordinator: coord)
        vm.searchScope = .message
        vm.filterText = "c7"

        await vm.runSearch()
        XCTAssertEqual(vm.searchResults?.commits.map(\.subject), ["c7"])
        XCTAssertFalse(vm.searchResults?.failed ?? true)
        XCTAssertFalse(vm.searchResults?.timedOut ?? true)
        XCTAssertFalse(vm.isSearching)
    }

    /// A bad regex is a query problem; the banner should say so rather
    /// than blaming the clock.
    func testAFailedSearchIsNotReportedAsATimeout() async throws {
        let repo = try await makeRepo(commits: 5)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let coord = CacheCoordinator()
        coord.switchRepo(to: repo.path)
        let vm = JournalViewModel(coordinator: coord)
        vm.searchScope = .contentRegex
        vm.filterText = "[unclosed"

        await vm.runSearch()
        XCTAssertTrue(vm.searchResults?.failed ?? false)
        XCTAssertFalse(vm.searchResults?.timedOut ?? true)
    }
}
