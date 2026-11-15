import XCTest
@testable import SmallGit

@MainActor
final class FileRefreshDuringActionTests: XCTestCase {
    @MainActor
    private struct Sandbox {
        let root: URL
        let repo: URL
        let app: AppState

        func signal(_ name: String) throws {
            try Data().write(to: root.appendingPathComponent(name))
        }

        func cleanup() {
            app.fileWatcher.stop()
            try? signal("continue")
            try? signal("release-status")
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A real repository and real status queries, with a controllable pull
    /// that writes intermediate files. Barriers make the flicker regression
    /// reproducible without depending on network or FSEvents timing.
    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner(importsUserShellEnvironment: false)
        let executable = try await runner.gitExecutablePath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-refresh-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await runner.run(in: repo.path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo.path, args: ["-c", "user.name=T", "-c", "user.email=t@x",
            "-c", "commit.gpgsign=false", "commit", "-qm", "initial", "--allow-empty"])
        try "before\n".write(to: repo.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)

        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let wrapper = root.appendingPathComponent("git-wrapper")
        try """
        #!/bin/sh
        gate=\(quote(root.path))
        real_git=\(quote(executable))
        if [ "$1" = -C ]; then
            cd "$2" || exit 98
            shift 2
        fi
        wait_for() {
            count=0
            while [ ! -e "$gate/$1" ]; do
                count=$((count + 1))
                [ "$count" -lt 1000 ] || exit 99
                sleep 0.01
            done
        }
        if [ "$1" = pull ]; then
            printf 'intermediate\\n' > transient.txt
            touch "$gate/started"
            wait_for continue
            if [ -e "$gate/conflict" ]; then
                exec "$real_git" -c user.name=T -c user.email=t@x -c commit.gpgsign=false merge --no-edit conflict
            fi
            if [ -e "$gate/fail" ]; then exit 1; fi
            rm -f before.txt transient.txt
            printf 'final\\n' > after.txt
            exit 0
        fi
        if [ "$1" = status ] && [ -e "$gate/hold-status" ]; then
            "$real_git" "$@" > "$gate/old-status"
            rm "$gate/hold-status"
            touch "$gate/status-started"
            wait_for release-status
            cat "$gate/old-status"
            exit 0
        fi
        exec "$real_git" "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let git = GitService(runner: ProcessRunner(gitPath: wrapper.path, importsUserShellEnvironment: false))
        let coordinator = CacheCoordinator(gitService: git)
        let app = AppState(
            coordinator: coordinator, git: git,
            config: ConfigService(supportDirectory: root.appendingPathComponent("config")),
            platform: RecordingPlatformServices()
        )
        app.activeRepo = RepositoryEntry(path: repo.path, name: "work")
        coordinator.switchRepo(to: repo.path)
        await app.filesVM.forceRefresh()
        app.changedFileCount = app.filesVM.files.count
        return Sandbox(root: root, repo: repo, app: app)
    }

    private func waitFor(_ marker: String, in sandbox: Sandbox) async throws {
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent(marker).path) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(marker)")
        throw ProcessError.timedOut(marker)
    }

    /// The same path used by FSEvents; explicitly injecting the event makes
    /// this independent of the host's event coalescing delay.
    private func deliverFileEvent(to sandbox: Sandbox) async {
        let layout = await sandbox.app.git.layout(repoPath: sandbox.repo.path)
        let invalidated = sandbox.app.coordinator.onFileSystemChange(
            paths: [sandbox.repo.appendingPathComponent("transient.txt").path], layout: layout
        )
        XCTAssertTrue(invalidated)
        await sandbox.app.refreshPanels()
    }

    func testPullKeepsRowsAndSelectionUntilItFinishes() async throws {
        let s = try await makeSandbox()
        defer { s.cleanup() }
        let before = s.app.filesVM.files
        s.app.filesVM.selectedFileIDs = Set(before.map(\.id))
        s.app.filesVM.filterText = ".txt"
        let pull = Task { await s.app.pull() }
        defer { pull.cancel() }
        try await waitFor("started", in: s)

        await deliverFileEvent(to: s)
        // Also cover refreshes requested by the panel and cache callbacks.
        await s.app.filesVM.forceRefresh()
        await s.app.filesVM.load()
        await s.app.filesVM.loadTrackedPathsIfNeeded()
        await s.app.filesVM.loadAssumeUnchanged()
        s.app.coordinator.onBackgroundRefresh?(.fileStatus)
        await Task.yield()
        XCTAssertEqual(s.app.filesVM.files, before)
        XCTAssertEqual(s.app.filesVM.selectedFileIDs, Set(before.map(\.id)))
        XCTAssertEqual(s.app.changedFileCount, before.count)
        XCTAssertTrue(s.app.isWorking)

        try s.signal("continue")
        let succeeded = await pull.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(s.app.filesVM.files.map(\.path), ["after.txt"])
        XCTAssertEqual(s.app.changedFileCount, 1)
        XCTAssertEqual(s.app.filesVM.filterText, ".txt")
        XCTAssertFalse(s.app.isWorking)
        XCTAssertFalse(s.app.coordinator.isActionRunning)
    }

    func testFailurePublishesTheFilesLeftBehind() async throws {
        let s = try await makeSandbox()
        defer { s.cleanup() }
        try s.signal("fail")
        let pull = Task { await s.app.pull() }
        defer { pull.cancel() }
        try await waitFor("started", in: s)
        await deliverFileEvent(to: s)
        XCTAssertEqual(s.app.filesVM.files.map(\.path), ["before.txt"])

        try s.signal("continue")
        let succeeded = await pull.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(Set(s.app.filesVM.files.map(\.path)), ["before.txt", "transient.txt"])
        XCTAssertEqual(s.app.changedFileCount, 2)
        XCTAssertFalse(s.app.coordinator.isActionRunning)
    }

    func testCancellationStillRefreshesTheFinalState() async throws {
        let s = try await makeSandbox()
        defer { s.cleanup() }
        let pull = Task { await s.app.pull() }
        try await waitFor("started", in: s)
        await deliverFileEvent(to: s)
        pull.cancel()
        _ = await pull.value

        XCTAssertEqual(Set(s.app.filesVM.files.map(\.path)), ["before.txt", "transient.txt"])
        XCTAssertEqual(s.app.changedFileCount, 2)
        XCTAssertFalse(s.app.isWorking)
        XCTAssertFalse(s.app.coordinator.isActionRunning)
    }

    func testPullStoppedByConflictPublishesTheConflictRows() async throws {
        let s = try await makeSandbox()
        defer { s.cleanup() }
        let runner = ProcessRunner(importsUserShellEnvironment: false)
        let shared = s.repo.appendingPathComponent("shared.txt")
        func commit(_ contents: String) async throws {
            try contents.write(to: shared, atomically: true, encoding: .utf8)
            _ = try await runner.run(in: s.repo.path, args: ["add", "shared.txt"])
            let result = try await runner.run(in: s.repo.path, args: ["-c", "user.name=T", "-c", "user.email=t@x",
                "-c", "commit.gpgsign=false", "commit", "-qm", contents])
            XCTAssertTrue(result.succeeded, result.combinedOutput)
        }
        try await commit("base\n")
        _ = try await runner.run(in: s.repo.path, args: ["checkout", "-qb", "conflict"])
        try await commit("theirs\n")
        _ = try await runner.run(in: s.repo.path, args: ["checkout", "-q", "main"])
        try await commit("ours\n")
        try s.signal("conflict")
        let pull = Task { await s.app.pull() }
        defer { pull.cancel() }
        try await waitFor("started", in: s)
        await deliverFileEvent(to: s)
        XCTAssertEqual(s.app.filesVM.files.map(\.path), ["before.txt"])

        try s.signal("continue")
        let succeeded = await pull.value
        XCTAssertFalse(succeeded)
        XCTAssertTrue(s.app.filesVM.files.contains { $0.path == "shared.txt" && $0.isConflict })
        XCTAssertNotNil(s.app.inProgressOperation)
        XCTAssertFalse(s.app.coordinator.isActionRunning)
    }

    func testReadStartedBeforePullCannotOverwriteItsFinalSnapshot() async throws {
        let s = try await makeSandbox()
        defer { s.cleanup() }
        try s.signal("hold-status")
        let oldRead = Task { await s.app.filesVM.forceRefresh() }
        defer { oldRead.cancel() }
        try await waitFor("status-started", in: s)
        let pull = Task { await s.app.pull() }
        defer { pull.cancel() }
        try await waitFor("started", in: s)
        try s.signal("continue")
        _ = await pull.value
        XCTAssertEqual(s.app.filesVM.files.map(\.path), ["after.txt"])

        try s.signal("release-status")
        await oldRead.value
        await s.app.filesVM.load()
        XCTAssertEqual(s.app.filesVM.files.map(\.path), ["after.txt"],
            "Neither the panel nor its cache may regress to the pre-pull read")
    }

    func testOnlyTheLastOverlappingActionReleasesTheFileList() async throws {
        let s = try await makeSandbox()
        defer { s.cleanup() }
        s.app.coordinator.beginAction(repoPath: s.repo.path)
        let pull = Task { await s.app.pull() }
        defer { pull.cancel() }
        try await waitFor("started", in: s)
        try s.signal("continue")
        _ = await pull.value
        XCTAssertTrue(s.app.coordinator.isActionRunning)
        XCTAssertEqual(s.app.filesVM.files.map(\.path), ["before.txt"])

        s.app.coordinator.endAction(repoPath: s.repo.path)
        await s.app.refreshPanels()
        XCTAssertEqual(s.app.filesVM.files.map(\.path), ["after.txt"])
    }

    func testSwitchingReposDuringPullDoesNotFreezeOrOverwriteTheOtherRepo() async throws {
        let s = try await makeSandbox()
        defer { s.cleanup() }
        let other = try await makeSandbox()
        defer { other.cleanup() }
        try "other\n".write(to: other.repo.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        let pull = Task { await s.app.pull() }
        defer { pull.cancel() }
        try await waitFor("started", in: s)
        s.app.activeRepo = other.app.activeRepo
        s.app.coordinator.switchRepo(to: other.repo.path)
        await s.app.refreshPanels()
        XCTAssertFalse(s.app.coordinator.isActionRunning)
        let rows = s.app.filesVM.files
        XCTAssertTrue(rows.contains { $0.path == "other.txt" })

        try s.signal("continue")
        _ = await pull.value
        XCTAssertEqual(s.app.filesVM.files, rows)
        XCTAssertEqual(s.app.coordinator.activeRepoPath, other.repo.path)
    }
}
