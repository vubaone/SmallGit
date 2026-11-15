import XCTest
@testable import SmallGit

/// The `origin/<branch>` chip in the Journal comes from `%D`, baked into the
/// cached log rows — so a push the app never saw leaves a disk snapshot that
/// draws the remote chip on the commit the remote used to be at, one row below
/// the local branch.
///
/// `get` hands out that snapshot and refreshes behind the caller's back, which
/// is the part that made it stick: the corrected rows landed in the cache with
/// nothing to read them.
@MainActor
final class StaleDecorationTests: XCTestCase {

    /// A repository with a bare remote, one commit, and that commit pushed —
    /// the state a branch is in before the push that goes unnoticed.
    private func makeRepoWithRemote() async throws -> (GitService, ProcessRunner, URL, String) {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let remote = root.appendingPathComponent("origin.git").path
        let repo = root.appendingPathComponent("work").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)

        _ = try await runner.run(in: root.path, args: ["init", "-q", "--bare", "origin.git"])
        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        _ = try await runner.run(in: repo, args: ["remote", "add", "origin", remote])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "--allow-empty", "-m", "v.10"])
        _ = try await runner.run(in: repo, args: ["push", "-q", "-u", "origin", "main"])

        return (GitService(runner: runner), runner, root, repo)
    }

    /// The L2 write is a detached task, so the snapshot has to actually be on
    /// disk before the push that makes it stale.
    private func awaitDiskEntry(
        _ disk: DiskCache,
        repo: String,
        key: CacheKey
    ) async throws {
        for _ in 0..<150 {
            if await disk.load(key: key, repoPath: repo, as: [GitCommit].self) != nil { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the log never reached the disk cache")
    }

    private func poll(
        _ description: String,
        until condition: () -> Bool
    ) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(description)
    }

    /// The reported bug, end to end: the local chip and the remote chip on
    /// different rows after a push, and still there minutes later.
    func testAPushTheAppNeverSawStopsBeingDrawnOnTheOldCommit() async throws {
        let (git, runner, root, repo) = try await makeRepoWithRemote()
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
        // A selection wider than HEAD, which is what the screenshot showed:
        // its cache key is a hash of the refs, not the `__current__` sentinel.
        await journal.setRefSelection(JournalRefSelection(head: true, refs: ["main"]))
        let key = CacheKey.log(refs: journal.refSelection.cacheToken)
        XCTAssertEqual(journal.commits.first?.subject, "v.10")
        XCTAssertTrue(
            journal.commits.first?.refs.contains("origin/main") ?? false,
            "before the push both refs are on the same commit"
        )
        try await awaitDiskEntry(disk, repo: repo, key: key)

        // The push nobody told the app about: another terminal, or this repo
        // not being the active one at the time.
        _ = try await runner.run(in: repo, args: ["commit", "-q", "--allow-empty", "-m", "v.18"])
        _ = try await runner.run(in: repo, args: ["push", "-q", "origin", "main"])

        // What the app does on the next launch or repo switch: L1 goes, the
        // disk snapshot stays.
        coordinator.switchRepo(to: nil)
        coordinator.switchRepo(to: repo)

        // The panel that re-reads when a background refresh corrects a value
        // — `AppState.adoptBackgroundRefresh` in the app.
        coordinator.onBackgroundRefresh = { cacheKey in
            guard case .log = cacheKey else { return }
            Task { await journal.load() }
        }

        await journal.load()

        try await poll("the journal kept drawing the pre-push snapshot") {
            journal.commits.first?.subject == "v.18"
        }
        XCTAssertTrue(
            journal.commits.first?.refs.contains("origin/main") ?? false,
            "after a push both chips belong on the top commit"
        )
        XCTAssertFalse(
            journal.commits.first(where: { $0.subject == "v.10" })?
                .refs.contains("origin/main") ?? false,
            "and the row below must not still be carrying the remote chip"
        )
    }

    /// A background refresh for another repository must not be adopted: the
    /// panels belong to whatever is active now.
    func testARefreshThatLandsAfterARepoSwitchIsNotDelivered() async throws {
        let (git, runner, root, repo) = try await makeRepoWithRemote()
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
        let key = CacheKey.log(refs: journal.refSelection.cacheToken)
        try await awaitDiskEntry(disk, repo: repo, key: key)

        _ = try await runner.run(in: repo, args: ["commit", "-q", "--allow-empty", "-m", "v.18"])
        coordinator.switchRepo(to: nil)
        coordinator.switchRepo(to: repo)

        var delivered: [CacheKey] = []
        coordinator.onBackgroundRefresh = { delivered.append($0) }
        await journal.load()
        // The switch happens while the refresh is in flight.
        coordinator.switchRepo(to: nil)

        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(
            delivered.isEmpty,
            "a value fetched for a repository nobody is looking at was delivered anyway"
        )
    }

    /// The same correction, through the real `AppState` wiring and for a panel
    /// that `refreshPanels` does *not* force: the Branches list is read with a
    /// 30-second TTL, so a branch made while the app was elsewhere is missing
    /// from it until something asks again.
    func testTheBranchesPanelAdoptsACorrectedListWithoutBeingAskedTwice() async throws {
        let (git, runner, root, repo) = try await makeRepoWithRemote()
        let disk = DiskCache()
        let coordinator = CacheCoordinator(
            memoryCache: MemoryCache(), diskCache: disk, gitService: git
        )
        let support = root.appendingPathComponent("support", isDirectory: true)
        let app = AppState(
            coordinator: coordinator,
            git: git,
            config: ConfigService(supportDirectory: support)
        )
        defer {
            let cleanup = coordinator
            Task { await cleanup.purgeDiskCache(forRepoPath: repo) }
            try? FileManager.default.removeItem(at: root)
        }

        await app.addRepository(at: repo)
        let entry = try XCTUnwrap(app.allRepositories.first { $0.path == repo })
        await app.selectRepo(entry)
        // The watcher would notice the new branch on its own, and then this
        // would prove nothing about the delivery path.
        app.fileWatcher.stop()

        for _ in 0..<150 {
            if await disk.load(key: .branchList, repoPath: repo, as: [GitBranch].self) != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(app.branchesVM.localBranches.map(\.name), ["main"])

        _ = try await runner.run(in: repo, args: ["branch", "spike/one"])
        // A fresh session: memory gone, the disk snapshot from before the
        // branch still there.
        coordinator.switchRepo(to: nil)
        coordinator.switchRepo(to: repo)

        await app.branchesVM.load()

        try await poll("the Branches panel never picked up the corrected list") {
            app.branchesVM.localBranches.map(\.name).contains("spike/one")
        }
    }

    /// `packed-refs` is where `git gc`, `git pack-refs` and a push into an
    /// already-packed repository move refs. Reading it as an internal detail
    /// left every ref-derived cache — including the log's chips — describing
    /// where the refs used to be.
    func testPackedRefsRetiresTheRefDerivedCaches() {
        let keys = InvalidationEngine.keysToInvalidate(
            changedPath: "/repo/.git/packed-refs",
            repoRoot: "/repo"
        )

        XCTAssertTrue(keys.contains(.branchList))
        XCTAssertTrue(keys.contains(.remoteBranches))
        XCTAssertTrue(keys.contains(.tagList))
        XCTAssertTrue(keys.contains(where: \.isLog))
    }

    /// The rest of `.git` stays quiet — a refresh on every internal write is
    /// how the app ends up feeding its own git commands back into its watcher.
    func testOrdinaryGitInternalsStillInvalidateNothing() {
        for name in ["COMMIT_EDITMSG", "config", "ORIG_HEAD", "FETCH_HEAD"] {
            XCTAssertTrue(
                InvalidationEngine.keysToInvalidate(
                    changedPath: "/repo/.git/\(name)",
                    repoRoot: "/repo"
                ).isEmpty,
                "\(name) should map to no cache keys"
            )
        }
    }
}
