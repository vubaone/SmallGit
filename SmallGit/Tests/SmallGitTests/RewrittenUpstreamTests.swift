import XCTest
@testable import SmallGit

/// A shared branch a teammate rebases and force-pushes, with a personal
/// branch made from it — `story` and `story-vubl`.
///
/// After the force-push the local `story` is an old copy of `origin/story`:
/// "ahead N, behind M", though every one of those N commits was the remote's.
/// A fast-forward is refused, and a plain rebase of `story-vubl` onto the new
/// `story` replays the old versions of its commits onto their rewrites.
final class RewrittenUpstreamTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        /// On `story-vubl`, which is `story` plus two commits of its own.
        let repo: String
        let origin: String
        let teammate: String
        let root: URL
    }

    /// `story` is s1, s2 on c0. `repo` branches `story-vubl` off it and adds
    /// v1, v2. The teammate then amends s2 — a different patch, not just a new
    /// hash — adds s3 and force-pushes. `repo` has fetched that, the way a
    /// pull in another worktree would have.
    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let git = GitService(runner: runner)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-rewritten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let origin = root.appendingPathComponent("origin.git").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "--bare", "-b", "main", "origin.git"])

        let teammate = root.appendingPathComponent("teammate").path
        _ = try await runner.run(in: root.path, args: ["clone", "-q", origin, "teammate"])
        try await configure(runner, teammate)
        try await commit(runner, in: teammate, file: "base.txt", "c0", message: "c0")
        _ = try await runner.run(in: teammate, args: ["push", "-q", "origin", "main"])
        _ = try await runner.run(in: teammate, args: ["switch", "-q", "-c", "story"])
        try await commit(runner, in: teammate, file: "s1.txt", "s1", message: "s1")
        try await commit(runner, in: teammate, file: "story.txt", "first draft", message: "s2")
        _ = try await runner.run(in: teammate, args: ["push", "-q", "-u", "origin", "story"])

        let repo = root.appendingPathComponent("repo").path
        _ = try await runner.run(in: root.path, args: ["clone", "-q", origin, "repo"])
        try await configure(runner, repo)
        _ = try await runner.run(in: repo, args: ["switch", "-q", "story"])
        _ = try await runner.run(in: repo, args: ["switch", "-q", "-c", "story-vubl"])
        try await commit(runner, in: repo, file: "v1.txt", "v1", message: "v1")
        try await commit(runner, in: repo, file: "v2.txt", "v2", message: "v2")

        // The rewrite: s2 amended with different content, then s3 on top.
        try "final wording\n".write(
            to: URL(fileURLWithPath: teammate).appendingPathComponent("story.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try await runner.run(in: teammate, args: ["commit", "-q", "-a", "--amend", "-m", "s2"])
        try await commit(runner, in: teammate, file: "s3.txt", "s3", message: "s3")
        _ = try await runner.run(in: teammate, args: ["push", "-q", "-f", "origin", "story"])
        _ = try await runner.run(in: repo, args: ["fetch", "-q", "origin"])

        return Sandbox(runner: runner, git: git, repo: repo, origin: origin, teammate: teammate, root: root)
    }

    private func configure(_ runner: ProcessRunner, _ path: String) async throws {
        _ = try await runner.run(in: path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: path, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: path, args: ["config", "commit.gpgsign", "false"])
    }

    private func commit(
        _ runner: ProcessRunner, in repo: String, file: String, _ body: String, message: String
    ) async throws {
        try "\(body)\n".write(
            to: URL(fileURLWithPath: repo).appendingPathComponent(file),
            atomically: true, encoding: .utf8
        )
        _ = try await runner.run(in: repo, args: ["add", "."])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", message])
    }

    private func revParse(_ box: Sandbox, _ ref: String, in path: String? = nil) async throws -> String {
        let r = try await box.runner.run(in: path ?? box.repo, args: ["rev-parse", ref])
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func subjects(_ box: Sandbox, _ range: String) async throws -> [String] {
        let r = try await box.runner.run(in: box.repo, args: ["log", "--reverse", "--format=%s", range])
        return r.stdout.split(separator: "\n").map(String.init)
    }

    @MainActor
    private func makeApp(_ box: Sandbox, platform: RecordingPlatformServices) -> AppState {
        let app = makeIsolatedAppState(git: box.git, platform: platform)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)
        return app
    }

    // MARK: - Fast-forward

    @MainActor
    func testAnOldCopyOfARewrittenUpstreamIsMovedToIt() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let app = makeApp(box, platform: RecordingPlatformServices())

        let moved = await app.fastForwardToUpstream(branch: "story")
        XCTAssertTrue(moved, app.statusText)
        let local = try await revParse(box, "refs/heads/story")
        let remote = try await revParse(box, "story", in: box.origin)
        XCTAssertEqual(local, remote)
        XCTAssertTrue(app.statusText.contains("rewritten"), app.statusText)
    }

    /// A commit of the user's own on `story` is exactly what the refusal
    /// protects, rewritten upstream or not.
    @MainActor
    func testLocalWorkOnTheBranchIsStillRefused() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let tree = try await revParse(box, "story^{tree}")
        let own = try await box.runner.run(
            in: box.repo, args: ["commit-tree", tree, "-p", "story", "-m", "mine"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await box.runner.run(in: box.repo, args: ["update-ref", "refs/heads/story", own])
        let app = makeApp(box, platform: RecordingPlatformServices())

        let moved = await app.fastForwardToUpstream(branch: "story")
        XCTAssertFalse(moved)
        let local = try await revParse(box, "refs/heads/story")
        XCTAssertEqual(local, own)
    }

    // MARK: - Rebase

    /// The whole flow: bring `story` up without leaving `story-vubl`, then
    /// rebase — and only v1, v2 are replayed.
    @MainActor
    func testRebasingOnlyYourOwnCommitsOntoTheRewrittenBranch() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let platform = RecordingPlatformServices()
        platform.rewrittenRebaseAnswer = .ownOnly
        let app = makeApp(box, platform: platform)

        _ = await app.fastForwardToUpstream(branch: "story")
        await app.rebase(onto: "story")

        let asked = try XCTUnwrap(platform.rewrittenRebases.first, "the user has to be asked")
        XCTAssertEqual(asked.staleSubjects, ["s2"], "the old s2 is named")
        XCTAssertEqual(asked.ownCount, 2)
        XCTAssertNil(app.inProgressOperation, "no conflict left behind")
        let onTop = try await subjects(box, "story..HEAD")
        XCTAssertEqual(onTop, ["v1", "v2"])
        let parent = try await revParse(box, "HEAD~2")
        let story = try await revParse(box, "story")
        XCTAssertEqual(parent, story, "sitting straight on the new story")
    }

    /// Straight onto the remote-tracking branch works the same, with no
    /// fast-forward first — its own reflog knows the old tip.
    @MainActor
    func testRebasingOntoTheRemoteTrackingBranchDirectly() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let platform = RecordingPlatformServices()
        platform.rewrittenRebaseAnswer = .ownOnly
        let app = makeApp(box, platform: platform)

        await app.rebase(onto: "origin/story")
        let onTop = try await subjects(box, "origin/story..HEAD")
        XCTAssertEqual(onTop, ["v1", "v2"])
    }

    @MainActor
    func testCancellingTheRebaseMovesNothing() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let platform = RecordingPlatformServices()
        platform.rewrittenRebaseAnswer = .cancel
        let app = makeApp(box, platform: platform)
        let before = try await revParse(box, "HEAD")

        await app.rebase(onto: "origin/story")
        let after = try await revParse(box, "HEAD")
        XCTAssertEqual(after, before)
    }

    /// A base nobody rewrote asks nothing.
    @MainActor
    func testAnOrdinaryRebaseIsNotAsked() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let platform = RecordingPlatformServices()
        let app = makeApp(box, platform: platform)

        await app.rebase(onto: "origin/main")
        XCTAssertTrue(platform.rewrittenRebases.isEmpty)
    }

    /// The planner lists the old s2 but starts it out dropped.
    @MainActor
    func testThePlannerStartsTheOldCommitsDropped() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let app = makeApp(box, platform: RecordingPlatformServices())

        await app.startInteractiveRebase(onto: "origin/story")
        let target = try XCTUnwrap(app.pendingInteractiveRebase, app.statusText)
        let plan = target.initialTodo.map { "\($0.action.keyword) \($0.subject)" }
        XCTAssertEqual(plan, ["drop s2", "pick v1", "pick v2"])
    }

    // MARK: - Checkout

    @MainActor
    func testCheckingOutTheOldCopyOffersToBringItUp() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let platform = RecordingPlatformServices()
        platform.behindCheckoutAnswer = .checkOutAndFastForward
        let app = makeApp(box, platform: platform)
        _ = await app.fetch()

        await app.checkout(branch: "story", offerFastForward: true)
        XCTAssertEqual(platform.behindCheckouts.count, 1, "ahead only by the remote's old commits")
        let head = try await revParse(box, "HEAD")
        let remote = try await revParse(box, "story", in: box.origin)
        XCTAssertEqual(head, remote)
    }
}
