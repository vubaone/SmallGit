import XCTest
@testable import SmallGit

/// A `stash apply` that conflicts leaves no MERGE_HEAD and no sequencer —
/// only unmerged index entries — so there is nothing for git to unwind and
/// nothing for `inProgressOperation` to find. `abortStashApply` is SmallGit's
/// own way back out, and its whole point is the blast radius: restore the
/// stash's files, touch nothing else.
final class StashApplyAbortTests: XCTestCase {

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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-stashabort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main", "repo"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        return Sandbox(runner: runner, git: GitService(runner: runner), repo: repo, root: root)
    }

    private func write(_ box: Sandbox, _ name: String, _ body: String) throws {
        try body.write(
            to: URL(fileURLWithPath: box.repo).appendingPathComponent(name),
            atomically: true, encoding: .utf8
        )
    }

    private func read(_ box: Sandbox, _ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: box.repo).appendingPathComponent(name),
                   encoding: .utf8)
    }

    /// Builds a repo whose stash cannot apply cleanly, with unrelated work
    /// staged before the apply — the thing `git reset --hard` would destroy.
    private func conflictedApply(_ box: Sandbox) async throws {
        try write(box, "index.ts", "line1\nline2\n")
        try write(box, "unrelated.ts", "keep\n")
        _ = try await box.runner.run(in: box.repo, args: ["add", "."])
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-qm", "base"])

        try write(box, "index.ts", "line1\nSTASHED\n")
        _ = try await box.runner.run(in: box.repo, args: ["stash", "-q"])

        try write(box, "index.ts", "line1\nOTHER\n")
        _ = try await box.runner.run(in: box.repo, args: ["add", "."])
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-qm", "other"])

        try write(box, "unrelated.ts", "PRECIOUS STAGED WORK\n")
        _ = try await box.runner.run(in: box.repo, args: ["add", "unrelated.ts"])
        _ = try await box.git.stashApply(repoPath: box.repo, index: 0)
    }

    /// Git leaves no marker, which is exactly why the banner never appeared.
    func testConflictedApplyLeavesNoOperationMarker() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await conflictedApply(box)

        let status = try await box.git.status(repoPath: box.repo)
        XCTAssertTrue(status.contains { $0.isConflict }, "expected a conflicted file")
        let op = await box.git.inProgressOperation(repoPath: box.repo)
        XCTAssertNil(op, "a conflicted stash apply records no operation")
    }

    func testAbortRestoresStashedFileAndKeepsUnrelatedStagedWork() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await conflictedApply(box)

        let (_, leftInPlace) = try await box.git.abortStashApply(
            repoPath: box.repo, files: ["index.ts"]
        )

        XCTAssertTrue(leftInPlace.isEmpty)
        XCTAssertEqual(try read(box, "index.ts"), "line1\nOTHER\n", "restored from HEAD")
        XCTAssertEqual(
            try read(box, "unrelated.ts"), "PRECIOUS STAGED WORK\n",
            "work staged before the apply must survive — this is what reset --hard would eat"
        )
        let status = try await box.git.status(repoPath: box.repo)
        XCTAssertFalse(status.contains { $0.isConflict }, "the conflict should be gone")
    }

    /// Neither apply nor pop drops the stash when it conflicts, so aborting
    /// has to leave something to retry with.
    func testAbortKeepsTheStash() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await conflictedApply(box)

        _ = try await box.git.abortStashApply(repoPath: box.repo, files: ["index.ts"])

        let stashes = try await box.git.stashList(repoPath: box.repo)
        XCTAssertEqual(stashes.count, 1)
    }

    /// The predicate the app infers from when it did not run the apply itself:
    /// the applied stash's file list covers every conflicted path. If
    /// `stashFiles` ever stopped reporting them, the Abort button would
    /// silently stop appearing for conflicts that predate launch.
    func testStashFileListCoversTheConflictedPaths() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await conflictedApply(box)

        let status = try await box.git.status(repoPath: box.repo)
        let conflicted = Set(status.filter(\.isConflict).map(\.path))
        let stashed = Set(try await box.git.stashFiles(repoPath: box.repo, index: 0).map(\.path))

        XCTAssertFalse(conflicted.isEmpty)
        XCTAssertTrue(
            conflicted.isSubset(of: stashed),
            "conflicted \(conflicted) must be covered by the stash's files \(stashed)"
        )
    }

    /// A file the stash would have added has no committed version to restore,
    /// so it is unstaged and left on disk rather than deleted — git has no
    /// copy of its contents anywhere.
    func testFileAbsentFromHeadIsLeftInPlaceNotDeleted() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await conflictedApply(box)
        try write(box, "brand-new.ts", "invented\n")
        _ = try await box.runner.run(in: box.repo, args: ["add", "brand-new.ts"])

        let (_, leftInPlace) = try await box.git.abortStashApply(
            repoPath: box.repo, files: ["index.ts", "brand-new.ts"]
        )

        XCTAssertEqual(leftInPlace, ["brand-new.ts"])
        XCTAssertEqual(try read(box, "brand-new.ts"), "invented\n", "must not be deleted")
    }
}
