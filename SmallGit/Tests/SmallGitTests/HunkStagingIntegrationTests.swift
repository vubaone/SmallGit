import XCTest
@testable import SmallGit

/// End-to-end: spin up a real git repo in a temp directory, modify a
/// file producing multiple hunks, parse the diff, build a patch for the
/// FIRST hunk only, feed it to `git apply --cached`, and assert that
/// `git status --porcelain=v2` reports a staged change AND that
/// `git diff` (unstaged) still reports remaining changes from the
/// un-staged hunks.
final class HunkStagingIntegrationTests: XCTestCase {

    func testStageSingleHunkLeavesOthersUnstaged() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)

        // Skip if git is not available (sandboxed CI without xcode-select).
        do {
            _ = try await runner.gitExecutablePath()
        } catch {
            throw XCTSkip("git binary not available: \(error)")
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-hunktest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let repo = tmpDir.path

        // init + identity + initial commit with a multi-line file.
        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])

        let original = (1...30).map { "line\($0)" }.joined(separator: "\n") + "\n"
        let fileURL = tmpDir.appendingPathComponent("file.txt")
        try original.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "file.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])

        // Modify two distant regions so they produce two distinct hunks.
        var modified = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        modified[2]  = "LINE3-CHANGED"
        modified[22] = "LINE23-CHANGED"
        let modifiedString = modified.joined(separator: "\n")
        try modifiedString.write(to: fileURL, atomically: true, encoding: .utf8)

        // Parse the diff and confirm we have 2 hunks.
        let hunks = try await git.diff(repoPath: repo, file: "file.txt")
        XCTAssertEqual(hunks.count, 2, "Expected two distinct hunks, got \(hunks.count)")

        // Build a patch for hunk 0 only, apply it cached.
        guard let firstHunk = hunks.first else { return XCTFail("missing hunk") }
        let patch = try XCTUnwrap(DiffPatchBuilder.buildPatch(file: "file.txt", hunk: firstHunk))
        _ = try await git.applyPatch(repoPath: repo, patch: patch, cached: true, reverse: false)

        // git status should show this file as both staged AND unstaged
        // (porcelain v2: XY field has both a staged and worktree letter set).
        let statuses = try await git.status(repoPath: repo)
        let entry = statuses.first { $0.path == "file.txt" }
        let entryUnwrapped = try XCTUnwrap(entry)
        XCTAssertTrue(entryUnwrapped.isStaged,
                      "Expected file to be staged after applying hunk 0")
        XCTAssertTrue(entryUnwrapped.isUnstaged,
                      "Expected file to still have unstaged changes (hunk 1)")
    }
}
