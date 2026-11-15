import XCTest
@testable import SmallGit

/// Exercises `continueOperation` / `abortOperation` across the four
/// long-running git operations that pause on conflict: merge, rebase,
/// cherry-pick, revert. Each test builds a tiny scenario, resolves
/// the conflict with `acceptOurs`, then continues — verifying the
/// operation marker file disappears and the working tree returns to
/// a clean state.
final class InProgressOperationTests: XCTestCase {

    private struct Repo {
        let runner: ProcessRunner
        let git: GitService
        let path: String
        let root: URL
    }

    private func setupRepo() async throws -> Repo {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let git = GitService(runner: runner)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-inprog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: root.path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: root.path, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: root.path, args: ["config", "commit.gpgsign", "false"])
        return Repo(runner: runner, git: git, path: root.path, root: root)
    }

    private func write(_ s: String, to repo: String, file: String) throws {
        try s.write(
            to: URL(fileURLWithPath: repo).appendingPathComponent(file),
            atomically: true, encoding: .utf8
        )
    }

    private func commitAll(_ repo: Repo, message: String) async throws {
        _ = try await repo.runner.run(in: repo.path, args: ["add", "-A"])
        _ = try await repo.runner.run(in: repo.path, args: ["commit", "-q", "-m", message])
    }

    /// Build a repo where `feature` and `main` diverge on `a.txt`.
    /// Returns the repo once the divergence is committed (no operation
    /// in flight yet).
    private func makeDiverged() async throws -> Repo {
        let r = try await setupRepo()
        try write("base\n", to: r.path, file: "a.txt")
        try await commitAll(r, message: "base")

        _ = try await r.runner.run(in: r.path, args: ["checkout", "-q", "-b", "feature"])
        try write("theirs\n", to: r.path, file: "a.txt")
        try await commitAll(r, message: "feature change")

        _ = try await r.runner.run(in: r.path, args: ["checkout", "-q", "main"])
        try write("ours\n", to: r.path, file: "a.txt")
        try await commitAll(r, message: "main change")
        return r
    }

    // MARK: - Merge

    func testContinueMergeFinishesTheMergeCommit() async throws {
        let r = try await makeDiverged()
        defer { try? FileManager.default.removeItem(at: r.root) }

        _ = try await r.runner.run(in: r.path, args: ["merge", "--no-edit", "feature"])
        let beforeMerge = await r.git.inProgressOperation(repoPath: r.path)
        XCTAssertEqual(beforeMerge, .merge)

        _ = try await r.git.acceptOurs(repoPath: r.path, path: "a.txt")
        _ = try await r.git.continueOperation(repoPath: r.path, operation: .merge)

        let afterMerge = await r.git.inProgressOperation(repoPath: r.path)
        XCTAssertNil(afterMerge, "after continue, MERGE_HEAD should be gone")

        // The merge commit should exist as HEAD with two parents.
        let parents = try await r.runner.run(in: r.path, args: ["rev-list", "--parents", "-n", "1", "HEAD"])
        let parts = parents.stdout.split(separator: " ")
        XCTAssertGreaterThanOrEqual(parts.count, 3,
            "merge commit should have two parents, got \(parents.stdout)")
    }

    func testAbortMergeRestoresPreMergeState() async throws {
        let r = try await makeDiverged()
        defer { try? FileManager.default.removeItem(at: r.root) }
        _ = try await r.runner.run(in: r.path, args: ["merge", "--no-edit", "feature"])

        _ = try await r.git.abortOperation(repoPath: r.path, operation: .merge)
        let afterAbort = await r.git.inProgressOperation(repoPath: r.path)
        XCTAssertNil(afterAbort)

        let head = try await r.runner.run(in: r.path, args: ["log", "-1", "--pretty=%s"])
        XCTAssertEqual(head.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "main change",
            "HEAD should be back at main's pre-merge tip")
    }

    // MARK: - Rebase

    func testContinueRebaseAfterResolvingConflictAdvancesHead() async throws {
        let r = try await makeDiverged()
        defer { try? FileManager.default.removeItem(at: r.root) }

        // Rebase main onto feature — will conflict on a.txt.
        _ = try await r.runner.run(in: r.path, args: ["rebase", "feature"])
        let beforeRebase = await r.git.inProgressOperation(repoPath: r.path)
        XCTAssertEqual(beforeRebase, .rebase)

        _ = try await r.git.acceptOurs(repoPath: r.path, path: "a.txt")
        _ = try await r.git.continueOperation(repoPath: r.path, operation: .rebase)

        let afterRebase = await r.git.inProgressOperation(repoPath: r.path)
        XCTAssertNil(afterRebase, "after rebase --continue, no operation should remain")
    }

    func testAbortRebaseRestoresOriginalBranch() async throws {
        let r = try await makeDiverged()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let originalHead = try await r.runner.run(in: r.path, args: ["rev-parse", "HEAD"])

        _ = try await r.runner.run(in: r.path, args: ["rebase", "feature"])
        _ = try await r.git.abortOperation(repoPath: r.path, operation: .rebase)

        let opAfter = await r.git.inProgressOperation(repoPath: r.path)
        XCTAssertNil(opAfter)
        let after = try await r.runner.run(in: r.path, args: ["rev-parse", "HEAD"])
        XCTAssertEqual(after.stdout, originalHead.stdout,
            "abort should land HEAD back at the original commit")
    }

    // MARK: - Linked worktrees

    /// The reported bug, end to end: a rebase paused inside a `git worktree
    /// add` checkout was invisible, so nothing warned the user and nothing
    /// stopped the Push that git then refused with "You are not currently on
    /// a branch" — a paused rebase detaches HEAD.
    ///
    /// The cause was reading `<repo>/.git/rebase-merge`, and in a worktree
    /// `.git` is a *file*, so the check answered `no` rather than failing.
    /// That assumption is asserted here too, so this stays a test about why
    /// the git directory has to be resolved rather than assumed.
    func testAPausedRebaseIsVisibleInsideALinkedWorktree() async throws {
        let r = try await makeDiverged()
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-wt-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: worktree)
            try? FileManager.default.removeItem(at: r.root)
        }

        _ = try await r.runner.run(
            in: r.path, args: ["worktree", "add", "-q", worktree.path, "feature"]
        )
        let wt = worktree.path

        let layout = await r.git.layout(repoPath: wt)
        let mainLayout = await r.git.layout(repoPath: r.path)
        XCTAssertTrue(layout.isLinkedWorktree, "`git worktree add` produces a linked layout")
        XCTAssertFalse(mainLayout.isLinkedWorktree, "the checkout it was added from is not")
        // Compared against git's own answer for the main checkout rather than
        // a path built here: the temporary directory reaches this test through
        // `/var/folders` and git answers with the `/private/var` behind it.
        XCTAssertEqual(
            layout.commonDir, mainLayout.gitDir, "refs are shared with the main checkout"
        )
        XCTAssertEqual(
            layout.watchRoots, [wt, layout.commonDir],
            "the checkout alone never sees a ref change"
        )

        // Rebase onto main from inside the worktree — conflicts on a.txt and
        // stops, leaving HEAD detached.
        _ = try await r.runner.run(in: wt, args: ["rebase", "main"])

        let assumedMarker = (wt as NSString)
            .appendingPathComponent(".git/rebase-merge")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: assumedMarker),
            "`.git` is a file here — assuming the old path is how this was missed"
        )

        let op = await r.git.inProgressOperation(repoPath: wt)
        XCTAssertEqual(op, .rebase, "the paused rebase has to be visible")

        let branch = try await r.git.currentBranch(repoPath: wt)
        XCTAssertNil(branch, "a paused rebase detaches HEAD — nothing to push")

        _ = try await r.git.abortOperation(repoPath: wt, operation: .rebase)
        let after = await r.git.inProgressOperation(repoPath: wt)
        XCTAssertNil(after, "abort clears it, seen through the same resolved path")
    }

    // MARK: - Cherry-pick

    func testAbortCherryPickClearsState() async throws {
        let r = try await makeDiverged()
        defer { try? FileManager.default.removeItem(at: r.root) }

        // Cherry-pick the feature commit onto main — conflicts on a.txt.
        let featureHead = try await r.runner.run(in: r.path, args: ["rev-parse", "feature"])
        let hash = featureHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try await r.runner.run(in: r.path, args: ["cherry-pick", hash])
        let beforeCP = await r.git.inProgressOperation(repoPath: r.path)
        XCTAssertEqual(beforeCP, .cherryPick)

        _ = try await r.git.abortOperation(repoPath: r.path, operation: .cherryPick)
        let afterCP = await r.git.inProgressOperation(repoPath: r.path)
        XCTAssertNil(afterCP, "cherry-pick --abort should remove CHERRY_PICK_HEAD")
    }
}
