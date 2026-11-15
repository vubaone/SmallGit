import XCTest
@testable import SmallGit

/// End-to-end exercise of `GitService.squashRange` against a real repo:
/// a contiguous middle range is folded into one commit with a custom
/// message and authorship, while the commits above and below are left
/// intact.
@MainActor
final class SquashRangeTests: XCTestCase {

    private let git = GitService.shared
    private let runner = ProcessRunner()

    /// Builds a repo with `count` commits ("c1" … "c`count`"), each
    /// overwriting `a.txt` with "v<i>" so every commit carries a real
    /// change. Returns the repo path + temp root for cleanup.
    private func makeRepo(_ count: Int) async throws -> (path: String, root: URL) {
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-squashtest-\(UUID().uuidString)", isDirectory: true)
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

    /// `git log` field reader — newest-first lines split on TAB.
    private func logLines(_ repo: String, format: String) async throws -> [[String]] {
        let r = try await runner.run(in: repo, args: ["log", "--format=\(format)"])
        return r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.components(separatedBy: "\t") }
    }

    func testSquashesMiddleRangeWithCustomMessageAndAuthor() async throws {
        let repo = try await makeRepo(4)
        defer { try? FileManager.default.removeItem(at: repo.root) }

        // Hashes newest-first: [c4, c3, c2, c1].
        let hashes = try await logLines(repo.path, format: "%H").map { $0[0] }
        XCTAssertEqual(hashes.count, 4)
        let (c4, c3, c2, c1) = (hashes[0], hashes[1], hashes[2], hashes[3])

        // Squash the contiguous middle range c2 + c3 (display order is
        // newest-first, so the selection would be [c3, c2]).
        let result = try await git.squashRange(
            repoPath: repo.path,
            onto: "\(c2)^",                 // parent of c2 == c1
            pickHash: c2,                   // oldest selected
            selectedHashes: [c2, c3],
            lastSelectedHash: c3,           // newest selected
            message: "squashed subject\n\nsquashed body",
            authorName: "Alice Example",
            authorEmail: "alice@example.com",
            authorDateISO: "2020-01-02T03:04:05+00:00"
        )
        XCTAssertTrue(result.succeeded, "squash rebase should succeed: \(result.stderr)")

        // History is now three commits: c1, <squashed>, c4 (newest-first
        // c4, squashed, c1).
        let subjects = try await logLines(repo.path, format: "%s").map { $0[0] }
        XCTAssertEqual(subjects, ["c4", "squashed subject", "c1"])

        // The squashed commit carries the supplied message body, author,
        // and author date.
        let detail = try await logLines(
            repo.path,
            format: "%s%x09%an%x09%ae%x09%aI%x09%b"
        ).first { $0[0] == "squashed subject" }
        let row = try XCTUnwrap(detail)
        XCTAssertEqual(row[1], "Alice Example")
        XCTAssertEqual(row[2], "alice@example.com")
        XCTAssertTrue(row[3].hasPrefix("2020-01-02"), "author date should be the one we passed, got \(row[3])")
        XCTAssertEqual(row[4], "squashed body")

        // The fold combined c2 + c3's changes: the squashed commit's tree
        // has c3's content (the later of the two writes), and the tip still
        // reflects c4.
        let squashedTree = try await runner.run(
            in: repo.path,
            args: ["show", "HEAD~1:a.txt"]
        )
        XCTAssertEqual(squashedTree.stdout, "v3\n")
        let tip = try await runner.run(in: repo.path, args: ["show", "HEAD:a.txt"])
        XCTAssertEqual(tip.stdout, "v4\n")

        // c1 was below the rebase base and must be untouched.
        let newHashes = try await logLines(repo.path, format: "%H").map { $0[0] }
        XCTAssertEqual(newHashes.last, c1, "the commit below the range keeps its hash")
        XCTAssertNotEqual(newHashes.first, c4, "c4 was replayed on top and rewritten")
    }
}
