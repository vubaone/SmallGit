import XCTest
@testable import SmallGit

@MainActor
final class AddRepositoriesTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let root: URL
        let repos: [URL]
        let app: AppState
        let platform: RecordingPlatformServices

        func cleanup() {
            app.fileWatcher.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-add-many-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let runner = ProcessRunner(importsUserShellEnvironment: false)
        let git = GitService(runner: runner)
        let repos = ["first", "second", "last"].map { root.appendingPathComponent($0, isDirectory: true) }
        for repo in repos {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            let result = try await runner.run(in: repo.path, args: ["init", "-q", "-b", "main"])
            XCTAssertTrue(result.succeeded, result.combinedOutput)
        }
        let platform = RecordingPlatformServices()
        let app = AppState(
            coordinator: CacheCoordinator(gitService: git), git: git,
            config: ConfigService(supportDirectory: root.appendingPathComponent("config")),
            platform: platform
        )
        return Fixture(root: root, repos: repos, app: app, platform: platform)
    }

    func testAddsEverySelectedRepositoryAndOpensTheLast() async throws {
        let f = try await makeFixture()
        defer { f.cleanup() }
        // Selection order, rather than an alphabetical re-sort, determines
        // which repository is added last and therefore becomes active.
        let selected = [f.repos[2], f.repos[0], f.repos[1]]
        f.platform.repositoryFoldersToPick = selected
        let task = try XCTUnwrap(f.app.presentOpenRepository())
        await task.value

        XCTAssertEqual(f.app.repositoriesConfig.ungrouped.map(\.path), selected.map(\.path))
        XCTAssertEqual(f.app.activeRepo?.path, selected.last?.path)
        XCTAssertEqual(f.app.coordinator.activeRepoPath, selected.last?.path)
        XCTAssertEqual(f.app.appConfig.lastOpenedRepoID, f.app.activeRepo?.id)
        let saved = await f.app.config.loadRepositories()
        XCTAssertEqual(saved.ungrouped.map(\.path), selected.map(\.path))
    }

    func testGroupPickerAddsAllRepositoriesToThatGroup() async throws {
        let f = try await makeFixture()
        defer { f.cleanup() }
        f.platform.repositoryFoldersToPick = f.repos
        let task = try XCTUnwrap(f.app.presentOpenRepository(targetGroup: "Work"))
        await task.value

        XCTAssertEqual(f.app.repositoriesConfig.groups.count, 1)
        XCTAssertEqual(f.app.repositoriesConfig.groups.first?.name, "Work")
        XCTAssertEqual(f.app.repositoriesConfig.groups.first?.repositories.map(\.path), f.repos.map(\.path))
        XCTAssertTrue(f.app.repositoriesConfig.ungrouped.isEmpty)
        XCTAssertEqual(f.app.activeRepo?.path, f.repos.last?.path)
    }

    func testDuplicateAndInvalidTailDoNotReplaceTheLastAddedRepo() async throws {
        let f = try await makeFixture()
        defer { f.cleanup() }
        await f.app.addRepository(at: f.repos[0].path)
        let nested = f.repos[2].appendingPathComponent("Sources", isDirectory: true)
        let plain = f.root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        await f.app.addRepositories(at: [
            f.repos[1].path, f.repos[1].path + "/", f.repos[0].path,
            plain.path, nested.path, f.root.appendingPathComponent("missing").path
        ])

        XCTAssertEqual(f.app.allRepositories.map(\.path), Array(f.repos.prefix(2)).map(\.path))
        XCTAssertEqual(f.app.activeRepo?.path, f.repos[1].path)
        XCTAssertNil(f.app.pendingInitTarget)
        XCTAssertNil(f.app.pendingAmbiguousTarget)
        XCTAssertTrue(f.app.statusText.contains("skipped 5 folders"), f.app.statusText)
    }

    func testBatchWithNoNewRepositoriesKeepsTheActiveRepo() async throws {
        let f = try await makeFixture()
        defer { f.cleanup() }
        await f.app.addRepository(at: f.repos[0].path)
        let before = f.app.activeRepo

        await f.app.addRepositories(at: [f.repos[0].path, f.repos[0].path + "/"])

        XCTAssertEqual(f.app.activeRepo, before)
        XCTAssertEqual(f.app.allRepositories.count, 1)
    }

    func testCancellingPickerDoesNotChangeTheActiveRepo() async throws {
        let f = try await makeFixture()
        defer { f.cleanup() }
        await f.app.addRepository(at: f.repos[0].path)
        let before = f.app.activeRepo

        XCTAssertNil(f.app.presentOpenRepository())
        XCTAssertEqual(f.app.activeRepo, before)
        XCTAssertEqual(f.app.allRepositories.count, 1)
    }

    func testSinglePlainFolderKeepsTheExistingInitFlow() async throws {
        let f = try await makeFixture()
        defer { f.cleanup() }
        let plain = f.root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        f.platform.repositoryFoldersToPick = [plain]
        let task = try XCTUnwrap(f.app.presentOpenRepository(targetGroup: "Work"))
        await task.value

        XCTAssertEqual(f.app.pendingInitTarget?.path, plain.path)
        XCTAssertEqual(f.app.pendingInitTarget?.group, "Work")
        XCTAssertTrue(f.app.allRepositories.isEmpty)
    }
}
