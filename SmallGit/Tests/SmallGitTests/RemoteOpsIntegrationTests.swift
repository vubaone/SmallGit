import XCTest
@testable import SmallGit

/// End-to-end exercise of the remote and index actions in `GitService`
/// against a real `git` binary, using a local bare repo as the "remote".
/// No real network — origin lives in a temp directory and the two
/// working clones push/pull through it via file:// URLs.
final class RemoteOpsIntegrationTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        let origin: String   // bare repo path
        let repoA: String    // working clone A ("dev")
        let repoB: String    // working clone B ("collaborator")
        let root: URL        // tmp root, removed on teardown
    }

    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let git = GitService(runner: runner)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-remoteops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let origin = root.appendingPathComponent("origin.git").path
        let repoA  = root.appendingPathComponent("repoA").path
        let repoB  = root.appendingPathComponent("repoB").path

        _ = try await runner.run(in: root.path, args: ["init", "--bare", "-q", "-b", "main", "origin.git"])

        // Seed origin with one commit by way of a throwaway clone — pushing
        // an empty-but-named main branch makes subsequent clones non-empty.
        let seed = root.appendingPathComponent("seed").path
        _ = try await runner.run(in: root.path, args: ["clone", "-q", "file://\(origin)", "seed"])
        try await configureIdentity(runner: runner, repo: seed)
        try "seed\n".write(
            to: URL(fileURLWithPath: seed).appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8
        )
        _ = try await runner.run(in: seed, args: ["add", "README.md"])
        _ = try await runner.run(in: seed, args: ["commit", "-q", "-m", "seed"])
        _ = try await runner.run(in: seed, args: ["push", "-q", "origin", "main"])

        _ = try await runner.run(in: root.path, args: ["clone", "-q", "file://\(origin)", "repoA"])
        _ = try await runner.run(in: root.path, args: ["clone", "-q", "file://\(origin)", "repoB"])
        try await configureIdentity(runner: runner, repo: repoA)
        try await configureIdentity(runner: runner, repo: repoB)

        return Sandbox(runner: runner, git: git, origin: origin, repoA: repoA, repoB: repoB, root: root)
    }

    private func configureIdentity(runner: ProcessRunner, repo: String) async throws {
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
    }

    private func headHash(_ runner: ProcessRunner, repo: String, ref: String = "HEAD") async throws -> String {
        let r = try await runner.run(in: repo, args: ["rev-parse", ref])
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanup(_ sandbox: Sandbox) {
        try? FileManager.default.removeItem(at: sandbox.root)
    }

    // MARK: - Tests

    func testStageUnstageCommitFlow() async throws {
        let s = try await makeSandbox(); defer { cleanup(s) }

        let file = URL(fileURLWithPath: s.repoA).appendingPathComponent("hello.txt")
        try "hi\n".write(to: file, atomically: true, encoding: .utf8)

        try await s.git.stage(repoPath: s.repoA, files: ["hello.txt"])
        var status = try await s.runner.run(in: s.repoA, args: ["status", "--porcelain"])
        XCTAssertTrue(status.stdout.contains("A  hello.txt"), "expected staged add, got: \(status.stdout)")

        try await s.git.unstage(repoPath: s.repoA, files: ["hello.txt"])
        status = try await s.runner.run(in: s.repoA, args: ["status", "--porcelain"])
        XCTAssertTrue(status.stdout.contains("?? hello.txt"), "expected untracked after unstage, got: \(status.stdout)")

        try await s.git.stage(repoPath: s.repoA, files: ["hello.txt"])
        try await s.git.commit(repoPath: s.repoA, subject: "add hello")

        let log = try await s.runner.run(in: s.repoA, args: ["log", "-1", "--pretty=%s"])
        XCTAssertEqual(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "add hello")
    }

    func testDiscardRevertsUnstagedChange() async throws {
        let s = try await makeSandbox(); defer { cleanup(s) }

        let readme = URL(fileURLWithPath: s.repoA).appendingPathComponent("README.md")
        try "tampered\n".write(to: readme, atomically: true, encoding: .utf8)

        try await s.git.discard(repoPath: s.repoA, files: ["README.md"])
        let contents = try String(contentsOf: readme, encoding: .utf8)
        XCTAssertEqual(contents, "seed\n", "discard should restore the tracked content")
    }

    func testPushPropagatesCommitToOrigin() async throws {
        let s = try await makeSandbox(); defer { cleanup(s) }

        let file = URL(fileURLWithPath: s.repoA).appendingPathComponent("feature.txt")
        try "feature\n".write(to: file, atomically: true, encoding: .utf8)
        try await s.git.stage(repoPath: s.repoA, files: ["feature.txt"])
        try await s.git.commit(repoPath: s.repoA, subject: "add feature")
        let localHead = try await headHash(s.runner, repo: s.repoA)

        let pushResult = try await s.git.push(repoPath: s.repoA)
        XCTAssertEqual(pushResult.exitCode, 0, "push failed: \(pushResult.stderr)")

        let originHead = try await headHash(s.runner, repo: s.origin, ref: "refs/heads/main")
        XCTAssertEqual(originHead, localHead, "origin should now point at A's commit")
    }

    func testFetchUpdatesRemoteRefWithoutMovingLocalBranch() async throws {
        let s = try await makeSandbox(); defer { cleanup(s) }

        // B advances main and pushes.
        let bFile = URL(fileURLWithPath: s.repoB).appendingPathComponent("from-b.txt")
        try "b\n".write(to: bFile, atomically: true, encoding: .utf8)
        try await s.git.stage(repoPath: s.repoB, files: ["from-b.txt"])
        try await s.git.commit(repoPath: s.repoB, subject: "b commit")
        _ = try await s.git.push(repoPath: s.repoB)
        let bHead = try await headHash(s.runner, repo: s.repoB)

        // A's local main shouldn't have moved yet.
        let aHeadBefore = try await headHash(s.runner, repo: s.repoA)
        XCTAssertNotEqual(aHeadBefore, bHead)

        let fetchResult = try await s.git.fetch(repoPath: s.repoA)
        XCTAssertEqual(fetchResult.exitCode, 0, "fetch failed: \(fetchResult.stderr)")

        // After fetch: local main unchanged, origin/main matches B.
        let aHeadAfter   = try await headHash(s.runner, repo: s.repoA)
        let aOriginMain  = try await headHash(s.runner, repo: s.repoA, ref: "refs/remotes/origin/main")
        XCTAssertEqual(aHeadAfter, aHeadBefore, "fetch must not move local branch")
        XCTAssertEqual(aOriginMain, bHead, "origin/main should track B's commit after fetch")
    }

    func testPullMergeBringsRemoteCommitIntoLocalBranch() async throws {
        let s = try await makeSandbox(); defer { cleanup(s) }

        // B pushes a commit.
        let bFile = URL(fileURLWithPath: s.repoB).appendingPathComponent("from-b.txt")
        try "b\n".write(to: bFile, atomically: true, encoding: .utf8)
        try await s.git.stage(repoPath: s.repoB, files: ["from-b.txt"])
        try await s.git.commit(repoPath: s.repoB, subject: "b commit")
        _ = try await s.git.push(repoPath: s.repoB)
        let bHead = try await headHash(s.runner, repo: s.repoB)

        // A pulls (fast-forward merge) and should land exactly on B's HEAD.
        let pullResult = try await s.git.pull(repoPath: s.repoA, rebase: false)
        XCTAssertEqual(pullResult.exitCode, 0, "pull failed: \(pullResult.stderr)")
        let aHead = try await headHash(s.runner, repo: s.repoA)
        XCTAssertEqual(aHead, bHead, "A should fast-forward to B's commit after pull")

        // The file B added should now exist in A's worktree.
        let mirror = URL(fileURLWithPath: s.repoA).appendingPathComponent("from-b.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirror.path))
    }

    func testPullRebaseReplaysLocalCommitsOnTopOfRemote() async throws {
        let s = try await makeSandbox(); defer { cleanup(s) }

        // B pushes a commit first.
        let bFile = URL(fileURLWithPath: s.repoB).appendingPathComponent("from-b.txt")
        try "b\n".write(to: bFile, atomically: true, encoding: .utf8)
        try await s.git.stage(repoPath: s.repoB, files: ["from-b.txt"])
        try await s.git.commit(repoPath: s.repoB, subject: "b commit")
        _ = try await s.git.push(repoPath: s.repoB)

        // A makes a non-conflicting local commit.
        let aFile = URL(fileURLWithPath: s.repoA).appendingPathComponent("from-a.txt")
        try "a\n".write(to: aFile, atomically: true, encoding: .utf8)
        try await s.git.stage(repoPath: s.repoA, files: ["from-a.txt"])
        try await s.git.commit(repoPath: s.repoA, subject: "a commit")

        let pullResult = try await s.git.pull(repoPath: s.repoA, rebase: true)
        XCTAssertEqual(pullResult.exitCode, 0, "rebase pull failed: \(pullResult.stderr)")

        // After rebase, A's history should contain both subjects with B's
        // commit as the parent of A's commit.
        let log = try await s.runner.run(in: s.repoA, args: ["log", "--pretty=%s", "-3"])
        let subjects: [String] = log.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(subjects.prefix(2)), ["a commit", "b commit"],
            "expected A's commit to sit on top of B's after rebase, got \(subjects)")
    }

    @MainActor
    func testSyncStopsWhenPullRebaseConflictsAndDoesNotPush() async throws {
        let s = try await makeSandbox(); defer { cleanup(s) }

        let remoteReadme = URL(fileURLWithPath: s.repoB).appendingPathComponent("README.md")
        try "remote\n".write(to: remoteReadme, atomically: true, encoding: .utf8)
        _ = try await s.runner.run(in: s.repoB, args: ["add", "README.md"])
        _ = try await s.runner.run(in: s.repoB, args: ["commit", "-q", "-m", "remote change"])
        _ = try await s.git.push(repoPath: s.repoB)
        let remoteHead = try await headHash(s.runner, repo: s.origin, ref: "refs/heads/main")

        let localReadme = URL(fileURLWithPath: s.repoA).appendingPathComponent("README.md")
        try "local\n".write(to: localReadme, atomically: true, encoding: .utf8)
        _ = try await s.runner.run(in: s.repoA, args: ["add", "README.md"])
        _ = try await s.runner.run(in: s.repoA, args: ["commit", "-q", "-m", "local change"])

        let app = makeIsolatedAppState(git: s.git)
        app.activeRepo = RepositoryEntry(path: s.repoA, name: "repoA")
        app.coordinator.switchRepo(to: s.repoA)

        await app.sync()

        let originHeadAfterSync = try await headHash(s.runner, repo: s.origin, ref: "refs/heads/main")
        XCTAssertEqual(originHeadAfterSync, remoteHead, "sync must not push after a conflicted pull/rebase")
        let operation = await s.git.inProgressOperation(repoPath: s.repoA)
        XCTAssertEqual(operation, .rebase)
        XCTAssertTrue(app.statusText.contains("Sync stopped"))
    }

    func testIsRepositoryAcceptsGitWorktree() async throws {
        let s = try await makeSandbox(); defer { cleanup(s) }

        let worktreePath = URL(fileURLWithPath: s.root.path)
            .appendingPathComponent("repoA-worktree")
            .path
        _ = try await s.runner.run(in: s.repoA, args: ["worktree", "add", "-q", "-b", "worktree-test", worktreePath])

        let isRepository = await s.git.isRepository(at: worktreePath)
        XCTAssertTrue(isRepository)
    }

    @MainActor
    func testAddRepositorySkipsDuplicatePathAndShowsToast() async throws {
        let s = try await makeSandbox(); defer { cleanup(s) }
        let existing = RepositoryEntry(path: s.repoA, name: "repoA")
        let app = makeIsolatedAppState(git: s.git)
        app.repositoriesConfig = RepositoriesConfig(ungrouped: [existing])

        await app.addRepository(at: s.repoA)

        XCTAssertEqual(app.allRepositories.map(\.path), [s.repoA])
        XCTAssertEqual(app.toast?.text, "Repository already exists: repoA")
        XCTAssertEqual(app.statusText, "Repository already exists")
    }

    func testForcePushWithLeaseRewritesRemoteHistory() async throws {
        let s = try await makeSandbox(); defer { cleanup(s) }

        // A commits + pushes a v1.
        let file = URL(fileURLWithPath: s.repoA).appendingPathComponent("note.txt")
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        try await s.git.stage(repoPath: s.repoA, files: ["note.txt"])
        try await s.git.commit(repoPath: s.repoA, subject: "v1")
        _ = try await s.git.push(repoPath: s.repoA)
        let v1 = try await headHash(s.runner, repo: s.repoA)

        // A amends locally — diverges from origin.
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        try await s.git.stage(repoPath: s.repoA, files: ["note.txt"])
        try await s.git.commit(repoPath: s.repoA, subject: "v2-amend", amend: true)
        let v2 = try await headHash(s.runner, repo: s.repoA)
        XCTAssertNotEqual(v1, v2)

        // Plain push should be rejected (non-fast-forward).
        let plain = try await s.git.push(repoPath: s.repoA)
        XCTAssertNotEqual(plain.exitCode, 0, "expected plain push to be rejected after amend")

        // Force-with-lease should succeed and origin should hold v2.
        let forced = try await s.git.push(repoPath: s.repoA, force: true)
        XCTAssertEqual(forced.exitCode, 0, "force push failed: \(forced.stderr)")
        let originHead = try await headHash(s.runner, repo: s.origin, ref: "refs/heads/main")
        XCTAssertEqual(originHead, v2)
    }
}
