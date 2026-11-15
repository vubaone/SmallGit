import XCTest
@testable import SmallGit

/// Drives a real `git` binary into a content-conflict state, then
/// exercises the resolver paths in `GitService` end-to-end:
/// reading the three index stages, accepting either side, and
/// marking a manually-edited merge resolved.
final class ConflictResolutionIntegrationTests: XCTestCase {

    /// Builds a repo where main and `feature` both modify the same
    /// line of `a.txt`, then attempts a merge so the working tree
    /// ends up with `<<<<<<<` markers. Returns the repo path and a
    /// cleanup-safe root URL.
    private func makeConflictedRepo() async throws -> (runner: ProcessRunner, git: GitService, path: String, root: URL) {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let git = GitService(runner: runner)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-conflicttest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])

        let file = root.appendingPathComponent("a.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "a.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "base"])

        // Feature branch changes the file.
        _ = try await runner.run(in: repo, args: ["checkout", "-q", "-b", "feature"])
        try "theirs-version\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "a.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "feature change"])

        // Back to main, conflicting change.
        _ = try await runner.run(in: repo, args: ["checkout", "-q", "main"])
        try "ours-version\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "a.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "main change"])

        // Merge will conflict — we expect a non-zero exit, that's fine.
        _ = try await runner.run(in: repo, args: ["merge", "--no-edit", "feature"])

        return (runner, git, repo, root)
    }

    func testStatusReportsConflictedFile() async throws {
        let s = try await makeConflictedRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        let files = try await s.git.status(repoPath: s.path)
        let conflict = files.first(where: { $0.path == "a.txt" })
        XCTAssertNotNil(conflict)
        XCTAssertTrue(conflict?.isConflict == true,
            "expected a.txt to be flagged as conflicted, got \(String(describing: conflict))")
    }

    func testConflictVersionReadsAllThreeStages() async throws {
        let s = try await makeConflictedRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        let base   = try await s.git.conflictVersion(repoPath: s.path, path: "a.txt", side: .base)
        let ours   = try await s.git.conflictVersion(repoPath: s.path, path: "a.txt", side: .ours)
        let theirs = try await s.git.conflictVersion(repoPath: s.path, path: "a.txt", side: .theirs)
        XCTAssertEqual(base?.trimmingCharacters(in: .whitespacesAndNewlines),   "base")
        XCTAssertEqual(ours?.trimmingCharacters(in: .whitespacesAndNewlines),   "ours-version")
        XCTAssertEqual(theirs?.trimmingCharacters(in: .whitespacesAndNewlines), "theirs-version")
    }

    func testAcceptOursReplacesFileAndStagesIt() async throws {
        let s = try await makeConflictedRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        _ = try await s.git.acceptOurs(repoPath: s.path, path: "a.txt")

        // After acceptOurs, the working tree should hold "ours-version"
        // and status should no longer flag a conflict.
        let contents = try String(
            contentsOf: URL(fileURLWithPath: s.path).appendingPathComponent("a.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(contents.trimmingCharacters(in: .whitespacesAndNewlines), "ours-version")

        let files = try await s.git.status(repoPath: s.path)
        let entry = files.first(where: { $0.path == "a.txt" })
        XCTAssertFalse(entry?.isConflict ?? false,
            "expected a.txt to be unstuck from conflict state after acceptOurs")
    }

    func testAcceptTheirsReplacesFileAndStagesIt() async throws {
        let s = try await makeConflictedRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        _ = try await s.git.acceptTheirs(repoPath: s.path, path: "a.txt")
        let contents = try String(
            contentsOf: URL(fileURLWithPath: s.path).appendingPathComponent("a.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(contents.trimmingCharacters(in: .whitespacesAndNewlines), "theirs-version")
    }

    func testMarkResolvedAfterManualEditStagesTheCurrentWorkingTree() async throws {
        let s = try await makeConflictedRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        // Pretend the user manually merged: pick a custom value, then
        // mark it resolved.
        let url = URL(fileURLWithPath: s.path).appendingPathComponent("a.txt")
        try "custom-merge\n".write(to: url, atomically: true, encoding: .utf8)
        _ = try await s.git.markResolved(repoPath: s.path, path: "a.txt")

        let files = try await s.git.status(repoPath: s.path)
        let entry = files.first(where: { $0.path == "a.txt" })
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry?.isConflict ?? false,
            "manual merge + markResolved should clear the conflict flag")
        // Should be staged ("M" on the index side), not still untracked.
        XCTAssertTrue(entry?.isStaged ?? false)
    }

    func testInProgressOperationDetectsActiveMerge() async throws {
        let s = try await makeConflictedRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        let op = await s.git.inProgressOperation(repoPath: s.path)
        XCTAssertEqual(op, .merge, "MERGE_HEAD should be present mid-conflict")
    }

    func testAbortMergeClearsConflictState() async throws {
        let s = try await makeConflictedRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        _ = try await s.git.abortMerge(repoPath: s.path)

        let after = await s.git.inProgressOperation(repoPath: s.path)
        XCTAssertNil(after, "after merge --abort, no operation should be in progress")

        let files = try await s.git.status(repoPath: s.path)
        XCTAssertFalse(files.contains(where: { $0.isConflict }),
            "abort should leave no conflicted files")
    }
}
