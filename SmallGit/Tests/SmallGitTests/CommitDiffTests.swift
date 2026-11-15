import XCTest
@testable import SmallGit

final class CommitDiffTests: XCTestCase {

    func testCommitDiffReturnsHunksForChangedFiles() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-commitdiff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])

        // Initial commit so we have a baseline.
        try "alpha\n".write(to: tmp.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "a.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "seed"])

        // Two-file commit we'll diff.
        try "alpha\nBRAVO\n".write(to: tmp.appendingPathComponent("a.txt"),
                                   atomically: true, encoding: .utf8)
        try "new file contents\n".write(to: tmp.appendingPathComponent("b.txt"),
                                        atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "."])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "feature"])
        let targetHash = try await git.currentHeadSHA(repoPath: repo) ?? ""

        let hunks = try await git.commitDiff(repoPath: repo, hash: targetHash)
        XCTAssertEqual(hunks.count, 2, "expected one hunk per modified file")

        let allLines = hunks.flatMap(\.lines).map(\.content)
        XCTAssertTrue(allLines.contains("BRAVO"),
                      "missing change from a.txt; got: \(allLines)")
        XCTAssertTrue(allLines.contains("new file contents"),
                      "missing addition from b.txt; got: \(allLines)")
    }

    /// The Log window's Files pane narrows the diff to the rows it has
    /// selected — several at once, and none of the ones left out.
    func testCommitDiffNarrowsToSelectedPaths() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-commitdiff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])

        for name in ["a.txt", "b.txt", "c.txt"] {
            try "\(name)\n".write(to: tmp.appendingPathComponent(name),
                                  atomically: true, encoding: .utf8)
        }
        _ = try await runner.run(in: repo, args: ["add", "."])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "three files"])
        let hash = try await git.currentHeadSHA(repoPath: repo) ?? ""

        let hunks = try await git.commitDiff(repoPath: repo, hash: hash, paths: ["a.txt", "c.txt"])
        XCTAssertEqual(Set(hunks.compactMap(\.file)), ["a.txt", "c.txt"])
    }
}
