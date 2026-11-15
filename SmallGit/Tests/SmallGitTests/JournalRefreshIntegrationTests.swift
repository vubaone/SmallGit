import XCTest
@testable import SmallGit

/// What the Journal shows right after a commit, against a real repository
/// and the real three-layer cache.
///
/// The panel refresh that follows an action is the only thing standing
/// between a commit and the row for it, so the test is the whole sequence
/// the app performs — commit, invalidate, reload — rather than any one
/// piece of it.
@MainActor
final class JournalRefreshIntegrationTests: XCTestCase {

    private func makeRepo() async throws -> (GitService, ProcessRunner, URL) {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "--allow-empty", "-m", "seed"])

        return (GitService(runner: runner), runner, root)
    }

    /// The L2 write is a detached task, so a test that raced it would prove
    /// nothing — the disk snapshot has to actually be on disk before the
    /// commit that makes it stale.
    private func awaitDiskEntry(_ disk: DiskCache, repo: String) async throws {
        let key = CacheKey.log(refs: JournalRefSelection.headOnly.cacheToken)
        for _ in 0..<100 {
            if await disk.load(key: key, repoPath: repo, as: [GitCommit].self) != nil { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the log never reached the disk cache")
    }

    func testACommitIsInTheJournalAfterTheRefreshThatFollowsIt() async throws {
        let (git, runner, root) = try await makeRepo()
        let repo = root.path
        let disk = DiskCache()
        let coordinator = CacheCoordinator(
            memoryCache: MemoryCache(), diskCache: disk, gitService: git
        )
        defer {
            let cleanup = coordinator
            Task { await cleanup.purgeDiskCache(forRepoPath: repo) }
            try? FileManager.default.removeItem(at: root)
        }
        coordinator.switchRepo(to: repo)

        let journal = JournalViewModel(coordinator: coordinator, git: git)
        await journal.load()
        XCTAssertEqual(journal.commits.map(\.subject), ["seed"])
        try await awaitDiskEntry(disk, repo: repo)

        _ = try await runner.run(in: repo, args: ["commit", "-q", "--allow-empty", "-m", "add spec"])
        // Exactly what a successful commit does in AppState: invalidate what
        // the commit changed, then refresh the panels.
        coordinator.after(.commit)
        await journal.forceRefresh()

        XCTAssertEqual(
            journal.commits.first?.subject, "add spec",
            "the commit just made has to be the first row, not one refresh later"
        )
        XCTAssertEqual(journal.commits.count, 2)
    }
}
