import XCTest
@testable import SmallGit

@MainActor
final class RecentCommitMessagesTests: XCTestCase {
    private func makeRepo() async throws -> (ProcessRunner, GitService, URL) {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-recent-messages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "user.name", "T"],
            ["config", "user.email", "t@x"],
            ["config", "commit.gpgsign", "false"]
        ] {
            let result = try await runner.run(in: root.path, args: args)
            XCTAssertTrue(result.succeeded, result.stderr)
        }
        return (runner, GitService(runner: runner), root)
    }

    func testRecentCommitsIncludeWholeMessagesInOrderAndRespectLimit() async throws {
        let (runner, git, root) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let older = """
        Update profile

        First paragraph.

        - Keep this detail
          including its indentation

        Ticket: ZSOC-1453
        """
        let newer = """
        Update profile

        Nội dung khác — giữ đầy đủ ✅

        Fixes: #42
        """
        // Equal subjects must still keep their distinct bodies, with a
        // subject-only commit between them to check record boundaries.
        for message in [older, "Subject only", newer] {
            let result = try await runner.run(
                in: root.path,
                args: ["commit", "-q", "--allow-empty", "--cleanup=verbatim", "-F", "-"],
                stdin: message + "\n"
            )
            XCTAssertTrue(result.succeeded, result.stderr)
        }

        let app = makeIsolatedAppState(git: git)
        app.activeRepo = RepositoryEntry(path: root.path, name: "repo")
        let messages = await app.recentCommitMessages()
        XCTAssertEqual(messages, [newer, "Subject only", older])
        let limited = await app.recentCommitMessages(limit: 2)
        XCTAssertEqual(limited, [newer, "Subject only"])
        let none = await app.recentCommitMessages(limit: 0)
        XCTAssertTrue(none.isEmpty)
    }

    func testRecentCommitsAreEmptyWithoutAnActiveRepoOrHistory() async throws {
        let (_, git, root) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeIsolatedAppState(git: git)
        let noRepo = await app.recentCommitMessages()
        XCTAssertTrue(noRepo.isEmpty)

        app.activeRepo = RepositoryEntry(path: root.path, name: "empty repo")
        let noHistory = await app.recentCommitMessages()
        XCTAssertTrue(noHistory.isEmpty)
    }
}
