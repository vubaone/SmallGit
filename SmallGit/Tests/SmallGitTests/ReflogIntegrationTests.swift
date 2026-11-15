import XCTest
@testable import SmallGit

/// End-to-end exercise of `GitService.reflog` against a real `git`. We
/// drive HEAD through commit, checkout, and reset, then assert the
/// reflog reflects each move in newest-first order with the right
/// `ReflogAction` bucketing.
final class ReflogIntegrationTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        let repo: String
        let root: URL
    }

    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let git = GitService(runner: runner)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-reflog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main", "repo"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        return Sandbox(runner: runner, git: git, repo: repo, root: root)
    }

    private func commit(_ box: Sandbox, file: String, body: String, message: String) async throws {
        try body.write(
            to: URL(fileURLWithPath: box.repo).appendingPathComponent(file),
            atomically: true,
            encoding: .utf8
        )
        _ = try await box.runner.run(in: box.repo, args: ["add", file])
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-q", "-m", message])
    }

    func testReflogTracksCommitCheckoutReset() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        // 1. initial commit
        try await commit(box, file: "a", body: "a", message: "first")
        // 2. branch off
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "-b", "feature"])
        // 3. second commit on feature
        try await commit(box, file: "b", body: "b", message: "second")
        // 4. switch back to main
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "main"])
        // 5. reset to HEAD (no-op move, but produces a reflog entry on
        // some git versions; harmless either way)
        _ = try await box.runner.run(in: box.repo, args: ["reset", "-q", "--soft", "HEAD"])

        let entries = try await box.git.reflog(repoPath: box.repo)
        XCTAssertGreaterThanOrEqual(entries.count, 4, "expected at least 4 reflog rows, got \(entries.count)")

        // Newest-first ordering.
        XCTAssertEqual(entries[0].selector, "HEAD@{0}")
        XCTAssertEqual(entries.last?.selector, "HEAD@{\(entries.count - 1)}")

        // Action bucketing.
        let actions = entries.map(\.action)
        XCTAssertTrue(actions.contains(.commit), "expected at least one commit reflog row, got \(actions)")
        XCTAssertTrue(actions.contains(.checkout), "expected at least one checkout reflog row, got \(actions)")
    }

    func testReflogIsNewestFirst() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        try await commit(box, file: "a", body: "a", message: "older")
        try await commit(box, file: "b", body: "b", message: "newer")

        let entries = try await box.git.reflog(repoPath: box.repo)
        XCTAssertGreaterThanOrEqual(entries.count, 2)
        XCTAssertEqual(entries[0].message, "newer")
        XCTAssertEqual(entries[1].message, "older")
    }

    func testReflogLimitTrims() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        for i in 0..<5 {
            try await commit(box, file: "f\(i)", body: "\(i)", message: "c\(i)")
        }
        let limited = try await box.git.reflog(repoPath: box.repo, limit: 3)
        XCTAssertEqual(limited.count, 3)
        XCTAssertEqual(limited[0].message, "c4")
        XCTAssertEqual(limited[2].message, "c2")
    }
}
