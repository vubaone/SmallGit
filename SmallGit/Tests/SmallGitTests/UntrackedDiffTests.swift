import XCTest
@testable import SmallGit

final class UntrackedDiffTests: XCTestCase {

    func testUntrackedFileShowsAllLinesAsAddedAgainstRealGit() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-untracked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        // Need at least one tracked file so the repo has a HEAD.
        try "seed\n".write(to: tmp.appendingPathComponent("seed.txt"),
                           atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "seed.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])

        // Create a brand-new file that's never been staged.
        try "alpha\nbravo\ncharlie\n".write(
            to: tmp.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Plain git diff returns nothing — that was the bug.
        let plain = try await git.diff(repoPath: repo, file: "new.txt")
        XCTAssertTrue(plain.isEmpty, "sanity: plain git diff still ignores untracked files")

        // The new path shows the file as an addition.
        let untracked = try await git.untrackedDiff(repoPath: repo, file: "new.txt")
        XCTAssertEqual(untracked.count, 1, "expected one hunk for a new file")
        let lines = untracked.flatMap(\.lines)
        let additions = lines.filter { $0.type == .add }.map(\.content)
        XCTAssertEqual(additions, ["alpha", "bravo", "charlie"])
    }
}
