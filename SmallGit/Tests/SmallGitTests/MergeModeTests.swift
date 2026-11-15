import XCTest
@testable import SmallGit

/// Merge asks how to land the branch, the way SmartGit's Merge dialog does:
/// Fast-Forward (when possible), Create Merge-Commit, or Merge to Working
/// Tree — the last stopping before the commit so the result can be checked.
final class MergeModeTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        let repo: String
        let root: URL
    }

    /// `main` with one commit, `feature` one commit ahead of it, `main`
    /// checked out — a merge that could fast-forward.
    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-merge-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main", "repo"])
        _ = try await runner.run(in: repo, args: ["config", "user.name", "Test"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "test@example.com"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])

        try write(Self.file(line2: "line2", line9: "line9"), to: "f.txt", in: repo)
        _ = try await runner.run(in: repo, args: ["add", "f.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "base"])
        _ = try await runner.run(in: repo, args: ["checkout", "-q", "-b", "feature"])
        try write(Self.file(line2: "FEATURE", line9: "line9"), to: "f.txt", in: repo)
        _ = try await runner.run(in: repo, args: ["commit", "-qam", "feature work"])
        _ = try await runner.run(in: repo, args: ["checkout", "-q", "main"])

        return Sandbox(runner: runner, git: GitService(runner: runner), repo: repo, root: root)
    }

    /// Ten lines so an edit near the top and one near the bottom don't share
    /// diff context and conflict for reasons unrelated to the test.
    private static func file(line2: String, line9: String) -> String {
        var lines = (1...10).map { "line\($0)" }
        lines[1] = line2
        lines[8] = line9
        return lines.joined(separator: "\n") + "\n"
    }

    private func write(_ text: String, to name: String, in repo: String) throws {
        try text.write(
            to: URL(fileURLWithPath: repo).appendingPathComponent(name),
            atomically: true, encoding: .utf8
        )
    }

    private func read(_ name: String, in repo: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: repo).appendingPathComponent(name), encoding: .utf8)
    }

    private func revParse(_ box: Sandbox, _ ref: String) async throws -> String {
        let r = try await box.runner.run(in: box.repo, args: ["rev-parse", ref])
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parentCount(_ box: Sandbox, _ ref: String) async throws -> Int {
        let r = try await box.runner.run(in: box.repo, args: ["rev-list", "--parents", "-n", "1", ref])
        return r.stdout.split(separator: " ").count - 1
    }

    @MainActor
    private func makeApp(_ box: Sandbox, answer: MergeChoice) async -> (AppState, RecordingPlatformServices) {
        let platform = RecordingPlatformServices()
        platform.mergeAnswer = answer
        let app = makeIsolatedAppState(git: box.git, platform: platform)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)
        await app.refreshPanels(forceBranches: true)
        return (app, platform)
    }

    // MARK: - What is offered

    @MainActor
    func testFastForwardIsOfferedOnlyWhenPossible() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (app, platform) = await makeApp(box, answer: .cancel)

        await app.merge(branch: "feature")
        XCTAssertEqual(platform.merges.count, 1)
        XCTAssertEqual(platform.merges.first?.current, "main")
        XCTAssertEqual(platform.merges.first?.canFastForward, true)

        // A commit of main's own: the two have diverged.
        try write(Self.file(line2: "line2", line9: "MAIN"), to: "f.txt", in: box.repo)
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-qam", "main work"])
        await app.merge(branch: "feature")
        XCTAssertEqual(platform.merges.last?.canFastForward, false)
    }

    @MainActor
    func testNothingIsAskedWhenTheBranchIsAlreadyMerged() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        _ = try await box.runner.run(in: box.repo, args: ["merge", "-q", "--ff-only", "feature"])
        let (app, platform) = await makeApp(box, answer: .mergeCommit)

        await app.merge(branch: "feature")
        XCTAssertTrue(platform.merges.isEmpty)
        XCTAssertTrue(app.statusText.contains("nothing to merge"), app.statusText)
    }

    @MainActor
    func testCancelLeavesEverythingAlone() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let before = try await revParse(box, "main")
        let (app, _) = await makeApp(box, answer: .cancel)

        await app.merge(branch: "feature")
        let after = try await revParse(box, "main")
        XCTAssertEqual(after, before)
        XCTAssertNil(app.inProgressOperation)
    }

    // MARK: - The three ways to land it

    @MainActor
    func testFastForwardMovesTheBranchWithoutAMergeCommit() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (app, _) = await makeApp(box, answer: .fastForward)

        await app.merge(branch: "feature")
        let main = try await revParse(box, "main")
        let feature = try await revParse(box, "feature")
        XCTAssertEqual(main, feature, app.statusText)
    }

    /// Picked over Fast-Forward, it is a request for the commit.
    @MainActor
    func testCreateMergeCommitCommitsEvenWhereAFastForwardWouldDo() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (app, _) = await makeApp(box, answer: .mergeCommit)

        await app.merge(branch: "feature")
        let parents = try await parentCount(box, "main")
        XCTAssertEqual(parents, 2, app.statusText)
        XCTAssertNil(app.inProgressOperation)
    }

    /// The case `--no-commit` alone gets wrong: with a fast-forward possible
    /// git takes it, and main moves with nothing left to review.
    @MainActor
    func testMergeToWorkingTreeStopsBeforeCommittingEvenWhenItCouldFastForward() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let before = try await revParse(box, "main")
        let (app, _) = await makeApp(box, answer: .workingTree)

        await app.merge(branch: "feature")
        let after = try await revParse(box, "main")
        XCTAssertEqual(after, before, "main has not moved")
        XCTAssertTrue(try read("f.txt", in: box.repo).contains("FEATURE"), "the merge is in the working tree")
        XCTAssertEqual(app.inProgressOperation, .merge, "and the banner offers Continue / Abort")
        XCTAssertTrue(app.statusText.contains("working tree"), app.statusText)

        await app.continueInProgressOperation()
        let parents = try await parentCount(box, "main")
        XCTAssertEqual(parents, 2, "Continue commits it as a merge")
        XCTAssertNil(app.inProgressOperation)
    }

    @MainActor
    func testAbortingAWorkingTreeMergeUndoesIt() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let before = try await revParse(box, "main")
        let (app, _) = await makeApp(box, answer: .workingTree)

        await app.merge(branch: "feature")
        await app.abortInProgressOperation()
        let after = try await revParse(box, "main")
        XCTAssertEqual(after, before)
        XCTAssertFalse(try read("f.txt", in: box.repo).contains("FEATURE"))
        XCTAssertNil(app.inProgressOperation)
    }

    /// Local edits are set aside while the merge is reviewed — the tree shows
    /// the merge alone — and come back once it is committed.
    @MainActor
    func testLocalChangesSitOutTheReviewAndComeBackOnCommit() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try write(Self.file(line2: "line2", line9: "MINE"), to: "f.txt", in: box.repo)
        let (app, _) = await makeApp(box, answer: .workingTree)

        await app.merge(branch: "feature")
        let reviewing = try read("f.txt", in: box.repo)
        XCTAssertTrue(reviewing.contains("FEATURE"))
        XCTAssertFalse(reviewing.contains("MINE"), "only the merge is under review")
        XCTAssertTrue(app.statusText.contains("set aside"), app.statusText)

        await app.continueInProgressOperation()
        let committed = try read("f.txt", in: box.repo)
        XCTAssertTrue(committed.contains("MINE"), "the edit is back after the commit")
        let committedFile = try await box.runner.run(in: box.repo, args: ["show", "HEAD:f.txt"])
        XCTAssertFalse(committedFile.stdout.contains("MINE"), "and was not swept into the merge commit")
    }
}
