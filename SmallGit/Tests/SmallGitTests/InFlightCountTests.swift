import XCTest
@testable import SmallGit

/// Validates the AppState in-flight counter that drives the status-bar
/// spinner. We exercise it through a high-level method (stage) against
/// a temp repo so the assertions cover the runGit pipeline end to end.
final class InFlightCountTests: XCTestCase {

    @MainActor
    func testCounterTracksRunGitLifecycle() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-inflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try await runner.run(in: tmp.path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: tmp.path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: tmp.path, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: tmp.path, args: ["config", "commit.gpgsign", "false"])
        try "hello\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let app = makeIsolatedAppState(git: git)
        app.activeRepo = RepositoryEntry(path: tmp.path, name: "tmp")
        app.coordinator.switchRepo(to: tmp.path)

        XCTAssertFalse(app.isWorking, "should start idle")
        XCTAssertEqual(app.inFlightCount, 0)

        // Run two stages concurrently — counter should be 2 mid-flight.
        async let stageA: Bool = app.stage(files: ["a.txt"])
        async let stageB: Bool = app.stage(files: ["a.txt"])

        // Yield until we observe at least one in-flight op.
        var observedNonZero = false
        for _ in 0..<200 {
            if app.inFlightCount > 0 { observedNonZero = true; break }
            try await Task.sleep(nanoseconds: 1_000_000)  // 1ms
        }
        XCTAssertTrue(observedNonZero, "expected counter to go > 0 while ops run")

        let (stagedA, stagedB) = await (stageA, stageB)
        // Two `git add`s at once contend for index.lock, so one can lose.
        // The counter is what's under test here, not the stages.
        XCTAssertTrue(stagedA || stagedB, "at least one stage should get the index lock")

        XCTAssertEqual(app.inFlightCount, 0, "counter should return to 0 after completion")
        XCTAssertFalse(app.isWorking)
    }
}
