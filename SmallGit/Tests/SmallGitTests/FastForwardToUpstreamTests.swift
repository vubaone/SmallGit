import XCTest
@testable import SmallGit

/// Bringing `main` up to `origin/main` from a feature branch, so the feature
/// can be rebased onto it without switching away first.
///
/// What used to happen: "Fast-Forward Merge" on `main` ran `git merge
/// --ff-only main` into the *current* branch, which already contained it —
/// "Already up to date", exit 0, `main` untouched — and checking `main` out
/// afterwards showed nothing new until a pull.
final class FastForwardToUpstreamTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        /// On `feature`, with `main` tracking `origin/main` and never fetched.
        let repo: String
        let origin: String
        let root: URL
    }

    /// `repo` branches `feature` off `main` at c1. Someone else then pushes
    /// two commits to `main`, which `repo` has not fetched.
    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let git = GitService(runner: runner)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-ffupstream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let origin = root.appendingPathComponent("origin.git").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "--bare", "-b", "main", "origin.git"])

        let repo = root.appendingPathComponent("repo").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main", "repo"])
        try await configure(runner, repo)
        _ = try await runner.run(in: repo, args: ["remote", "add", "origin", origin])
        try await write(runner, in: repo, "c1")
        _ = try await runner.run(in: repo, args: ["push", "-q", "-u", "origin", "main"])
        _ = try await runner.run(in: repo, args: ["switch", "-q", "-c", "feature"])
        try await write(runner, in: repo, "feature work")

        let other = root.appendingPathComponent("other").path
        _ = try await runner.run(in: root.path, args: ["clone", "-q", origin, "other"])
        try await configure(runner, other)
        try await write(runner, in: other, "c2")
        try await write(runner, in: other, "c3")
        _ = try await runner.run(in: other, args: ["push", "-q", "origin", "main"])

        return Sandbox(runner: runner, git: git, repo: repo, origin: origin, root: root)
    }

    private func configure(_ runner: ProcessRunner, _ path: String) async throws {
        _ = try await runner.run(in: path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: path, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: path, args: ["config", "commit.gpgsign", "false"])
    }

    private func write(_ runner: ProcessRunner, in repo: String, _ message: String) async throws {
        try "\(message)\n".write(
            to: URL(fileURLWithPath: repo).appendingPathComponent("\(message).txt"),
            atomically: true, encoding: .utf8
        )
        _ = try await runner.run(in: repo, args: ["add", "."])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", message])
    }

    private func revParse(_ box: Sandbox, in path: String, _ ref: String) async throws -> String {
        let r = try await box.runner.run(in: path, args: ["rev-parse", ref])
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentBranch(_ box: Sandbox) async throws -> String {
        let r = try await box.runner.run(in: box.repo, args: ["branch", "--show-current"])
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func makeApp(_ box: Sandbox, platform: RecordingPlatformServices? = nil) -> AppState {
        let app = makeIsolatedAppState(git: box.git, platform: platform)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)
        return app
    }

    // MARK: - Fast-Forward to upstream

    /// No fetch beforehand: the move has to fetch for itself, or it lands on
    /// the `origin/main` of three days ago.
    @MainActor
    func testMovesTheBranchToWhatTheRemoteHasNowWithoutCheckingItOut() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let platform = RecordingPlatformServices()
        let app = makeApp(box, platform: platform)

        let moved = await app.fastForwardToUpstream(branch: "main")
        XCTAssertTrue(moved, app.statusText)

        let remoteMain = try await revParse(box, in: box.origin, "main")
        let localMain = try await revParse(box, in: box.repo, "refs/heads/main")
        let tracking = try await revParse(box, in: box.repo, "refs/remotes/origin/main")
        XCTAssertEqual(localMain, remoteMain, "main is where the remote's main is now")
        XCTAssertEqual(tracking, remoteMain, "and origin/main came along with it")
        let branch = try await currentBranch(box)
        XCTAssertEqual(branch, "feature", "the feature branch stays checked out")
        XCTAssertTrue(platform.divergedBranches.isEmpty)
    }

    @MainActor
    func testSayingSoWhenThereIsNothingToMove() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let app = makeApp(box)

        _ = await app.fastForwardToUpstream(branch: "main")
        let again = await app.fastForwardToUpstream(branch: "main")
        XCTAssertTrue(again)
        XCTAssertTrue(app.statusText.contains("already up to date"), app.statusText)
    }

    /// `main` with a commit of its own can't be fast-forwarded. Git refuses;
    /// Cancel in the integration dialog leaves it exactly where it was.
    @MainActor
    func testADivergedBranchIsLeftAloneAndExplained() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let tree = try await revParse(box, in: box.repo, "main^{tree}")
        let own = try await box.runner.run(
            in: box.repo, args: ["commit-tree", tree, "-p", "main", "-m", "local only"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await box.runner.run(in: box.repo, args: ["update-ref", "refs/heads/main", own])
        let platform = RecordingPlatformServices()
        let app = makeApp(box, platform: platform)

        let moved = await app.fastForwardToUpstream(branch: "main")
        XCTAssertFalse(moved)
        let localMain = try await revParse(box, in: box.repo, "refs/heads/main")
        XCTAssertEqual(localMain, own, "a refused fast-forward moves nothing")
        XCTAssertTrue(app.statusText.contains("main has commits"), app.statusText)
        let question = try XCTUnwrap(platform.divergedBranches.first)
        XCTAssertEqual(question.branch, "main")
        XCTAssertEqual(question.upstream, "origin/main")
        XCTAssertEqual(question.ahead, 1)
        XCTAssertEqual(question.behind, 2, "counts must include the fetch that was just rejected")
        let current = try await currentBranch(box)
        XCTAssertEqual(current, "feature")
        XCTAssertEqual(app.branchesVM.branch(named: "main")?.behindCount, 2)
    }

    /// Like a commit made on main before switching to a feature branch:
    /// both refs initially point at the local commit.
    private func divergeMain(_ box: Sandbox) async throws -> String {
        let tip = try await revParse(box, in: box.repo, "feature")
        _ = try await box.runner.run(in: box.repo, args: ["update-ref", "refs/heads/main", tip])
        return tip
    }

    @MainActor
    func testRebasePlacesLocalWorkAfterIncomingCommitsAndPreservesOtherBranches() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let oldMain = try await divergeMain(box)
        _ = try await box.runner.run(in: box.repo, args: ["config", "rebase.updateRefs", "true"])
        let untracked = URL(fileURLWithPath: box.repo).appendingPathComponent("untracked.txt")
        try "keep me".write(to: untracked, atomically: true, encoding: .utf8)
        let platform = RecordingPlatformServices()
        platform.divergedBranchAnswer = .rebase
        let app = makeApp(box, platform: platform)

        let integrated = await app.fastForwardToUpstream(branch: "main")
        XCTAssertTrue(integrated, app.output.entries.map(\.detail).joined(separator: "\n"))
        let current = try await currentBranch(box)
        XCTAssertEqual(current, "main", "the dialog explicitly says it checks out main")
        let remote = try await revParse(box, in: box.origin, "main")
        let parent = try await revParse(box, in: box.repo, "main^")
        XCTAssertEqual(parent, remote)
        let subjects = try await box.runner.run(in: box.repo, args: ["log", "--format=%s", "origin/main..main"])
        XCTAssertEqual(subjects.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "feature work")
        let feature = try await revParse(box, in: box.repo, "feature")
        XCTAssertEqual(feature, oldMain, "rebase.updateRefs must not move the user's other branch")
        let main = try await revParse(box, in: box.repo, "main")
        XCTAssertNotEqual(main, oldMain)
        for file in ["c1.txt", "c2.txt", "c3.txt", "feature work.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: (box.repo as NSString).appendingPathComponent(file)))
        }
        XCTAssertEqual(try String(contentsOf: untracked, encoding: .utf8), "keep me")
        XCTAssertEqual(app.branchesVM.currentBranch, "main")
        XCTAssertEqual(app.branchesVM.branch(named: "main")?.aheadCount, 1)
        XCTAssertEqual(app.branchesVM.branch(named: "main")?.behindCount, 0)
        XCTAssertNil(app.inProgressOperation)
    }

    @MainActor
    func testMergeKeepsBothHistoriesAsParents() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let oldMain = try await divergeMain(box)
        let platform = RecordingPlatformServices()
        platform.divergedBranchAnswer = .merge
        let app = makeApp(box, platform: platform)

        let integrated = await app.fastForwardToUpstream(branch: "main")
        XCTAssertTrue(integrated, app.output.entries.map(\.detail).joined(separator: "\n"))
        let parents = try await box.runner.run(in: box.repo, args: ["show", "-s", "--format=%P", "main"])
        let remote = try await revParse(box, in: box.origin, "main")
        XCTAssertEqual(parents.stdout.split(whereSeparator: \.isWhitespace).map(String.init), [oldMain, remote])
        let feature = try await revParse(box, in: box.repo, "feature")
        XCTAssertEqual(feature, oldMain)
        let current = try await currentBranch(box)
        XCTAssertEqual(current, "main")
        XCTAssertNil(app.inProgressOperation)
    }

    private func makeConflictingMain(_ box: Sandbox) async throws -> String {
        _ = try await divergeMain(box)
        _ = try await box.runner.run(in: box.repo, args: ["switch", "main"])
        try "local edit\n".write(toFile: (box.repo as NSString).appendingPathComponent("c1.txt"), atomically: true, encoding: .utf8)
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-qam", "local edit"])
        let tip = try await revParse(box, in: box.repo, "main")
        _ = try await box.runner.run(in: box.repo, args: ["switch", "feature"])
        let other = box.root.appendingPathComponent("other").path
        try "remote edit\n".write(toFile: (other as NSString).appendingPathComponent("c1.txt"), atomically: true, encoding: .utf8)
        _ = try await box.runner.run(in: other, args: ["commit", "-qam", "remote edit"])
        _ = try await box.runner.run(in: other, args: ["push", "-q", "origin", "main"])
        return tip
    }

    @MainActor
    func testConflictsAreVisibleAndCanBeContinuedForEitherChoice() async throws {
        for rebase in [true, false] {
            let box = try await makeSandbox()
            defer { try? FileManager.default.removeItem(at: box.root) }
            _ = try await makeConflictingMain(box)
            let platform = RecordingPlatformServices()
            platform.divergedBranchAnswer = rebase ? .rebase : .merge
            let app = makeApp(box, platform: platform)
            let integrated = await app.fastForwardToUpstream(branch: "main")
            XCTAssertFalse(integrated)
            XCTAssertEqual(app.inProgressOperation, rebase ? .rebase : .merge)
            XCTAssertTrue(app.filesVM.files.contains { $0.path == "c1.txt" && $0.isConflict })

            try "resolved\n".write(toFile: (box.repo as NSString).appendingPathComponent("c1.txt"), atomically: true, encoding: .utf8)
            _ = try await box.runner.run(in: box.repo, args: ["add", "c1.txt"])
            await app.continueInProgressOperation()
            XCTAssertNil(app.inProgressOperation, app.statusText)
            let current = try await currentBranch(box)
            XCTAssertEqual(current, "main")
            let contents = try String(contentsOfFile: (box.repo as NSString).appendingPathComponent("c1.txt"), encoding: .utf8)
            XCTAssertEqual(contents, "resolved\n")
        }
    }

    @MainActor
    func testAbortingEitherChoiceRestoresTheLocalBranch() async throws {
        for rebase in [true, false] {
            let box = try await makeSandbox()
            defer { try? FileManager.default.removeItem(at: box.root) }
            let oldMain = try await makeConflictingMain(box)
            let platform = RecordingPlatformServices()
            platform.divergedBranchAnswer = rebase ? .rebase : .merge
            platform.confirmWarningAnswer = true
            let app = makeApp(box, platform: platform)
            _ = await app.fastForwardToUpstream(branch: "main")
            await app.abortInProgressOperation()
            XCTAssertNil(app.inProgressOperation, app.statusText)
            let tip = try await revParse(box, in: box.repo, "main")
            XCTAssertEqual(tip, oldMain)
            let current = try await currentBranch(box)
            XCTAssertEqual(current, "main")
        }
    }

    @MainActor
    func testAFailedCheckoutDoesNotIntegrateIntoTheFeatureBranch() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        _ = try await box.runner.run(in: box.repo, args: ["switch", "main"])
        try await write(box.runner, in: box.repo, "local only")
        let oldMain = try await revParse(box, in: box.repo, "main")
        _ = try await box.runner.run(in: box.repo, args: ["switch", "feature"])
        let oldFeature = try await revParse(box, in: box.repo, "feature")
        let dirty = URL(fileURLWithPath: box.repo).appendingPathComponent("feature work.txt")
        try "unsaved feature work".write(to: dirty, atomically: true, encoding: .utf8)
        let platform = RecordingPlatformServices()
        platform.divergedBranchAnswer = .rebase
        let app = makeApp(box, platform: platform)

        let integrated = await app.fastForwardToUpstream(branch: "main")
        XCTAssertFalse(integrated)
        let main = try await revParse(box, in: box.repo, "main")
        let feature = try await revParse(box, in: box.repo, "feature")
        XCTAssertEqual(main, oldMain)
        XCTAssertEqual(feature, oldFeature)
        let current = try await currentBranch(box)
        XCTAssertEqual(current, "feature")
        XCTAssertEqual(try String(contentsOf: dirty, encoding: .utf8), "unsaved feature work")
        XCTAssertNil(app.inProgressOperation)
    }

    @MainActor
    func testNetworkErrorsDoNotOfferRebaseOrMerge() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        _ = try await divergeMain(box)
        _ = try await box.runner.run(in: box.repo, args: ["remote", "set-url", "origin", box.root.appendingPathComponent("missing.git").path])
        let platform = RecordingPlatformServices()
        let app = makeApp(box, platform: platform)
        let integrated = await app.fastForwardToUpstream(branch: "main")
        XCTAssertFalse(integrated)
        XCTAssertTrue(platform.divergedBranches.isEmpty)
        let current = try await currentBranch(box)
        XCTAssertEqual(current, "feature")
    }

    func testIntegrationRefusesTheWrongCheckedOutBranch() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let result = try await box.git.integrateUpstream(repoPath: box.repo, branch: "main", rebase: true)
        XCTAssertFalse(result.succeeded)
        let current = try await currentBranch(box)
        XCTAssertEqual(current, "feature")
    }

    // MARK: - Checking out a branch that is behind

    /// After a fetch the branch list knows `main` is 2 behind, which is what
    /// the question is asked on.
    @MainActor
    private func fetchedApp(
        _ box: Sandbox, answer: BehindCheckoutChoice
    ) async throws -> (AppState, RecordingPlatformServices) {
        let platform = RecordingPlatformServices()
        platform.behindCheckoutAnswer = answer
        let app = makeApp(box, platform: platform)
        let fetched = await app.fetch()
        XCTAssertTrue(fetched, app.statusText)
        let main = try XCTUnwrap(app.branchesVM.localBranches.first { $0.name == "main" })
        XCTAssertEqual(main.behindCount, 2, main.upstreamTrack ?? "no track")
        return (app, platform)
    }

    @MainActor
    func testCheckOutAndFastForwardLandsOnTheRemoteTip() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (app, platform) = try await fetchedApp(box, answer: .checkOutAndFastForward)

        await app.checkout(branch: "main", offerFastForward: true)
        XCTAssertEqual(platform.behindCheckouts.count, 1)
        XCTAssertEqual(platform.behindCheckouts.first?.upstream, "origin/main")
        XCTAssertEqual(platform.behindCheckouts.first?.behind, 2)
        let branch = try await currentBranch(box)
        XCTAssertEqual(branch, "main")
        let head = try await revParse(box, in: box.repo, "HEAD")
        let remoteMain = try await revParse(box, in: box.origin, "main")
        XCTAssertEqual(head, remoteMain)
    }

    @MainActor
    func testCheckOutOnlyLeavesTheBranchWhereItWas() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let before = try await revParse(box, in: box.repo, "refs/heads/main")
        let (app, _) = try await fetchedApp(box, answer: .checkOutOnly)

        await app.checkout(branch: "main", offerFastForward: true)
        let branch = try await currentBranch(box)
        XCTAssertEqual(branch, "main")
        let head = try await revParse(box, in: box.repo, "HEAD")
        XCTAssertEqual(head, before)
    }

    @MainActor
    func testCancelStaysPut() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (app, _) = try await fetchedApp(box, answer: .cancel)

        await app.checkout(branch: "main", offerFastForward: true)
        let branch = try await currentBranch(box)
        XCTAssertEqual(branch, "feature")
    }

    /// Undo and the other exact-state callers don't ask.
    @MainActor
    func testNotAskedUnlessOffered() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (app, platform) = try await fetchedApp(box, answer: .cancel)

        await app.checkout(branch: "main")
        XCTAssertTrue(platform.behindCheckouts.isEmpty)
        let branch = try await currentBranch(box)
        XCTAssertEqual(branch, "main")
    }

    // MARK: - Parsing the track

    func testTrackCounts() {
        let both = GitBranch(name: "x", upstreamTrack: "ahead 1, behind 12")
        XCTAssertEqual(both.aheadCount, 1)
        XCTAssertEqual(both.behindCount, 12)
        XCTAssertEqual(GitBranch(name: "x", upstreamTrack: "behind 3").aheadCount, 0)
        XCTAssertEqual(GitBranch(name: "x", upstreamTrack: "gone").behindCount, 0)
        XCTAssertEqual(GitBranch(name: "x").behindCount, 0)
    }
}
