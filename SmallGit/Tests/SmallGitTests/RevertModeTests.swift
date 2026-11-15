import XCTest
@testable import SmallGit

@MainActor
final class RevertModeTests: XCTestCase {
    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        let root: URL
        let repo: String
        let target: GitCommit
    }

    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-revert-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "user.name", "Test"],
            ["config", "user.email", "test@example.invalid"],
            ["config", "commit.gpgsign", "false"]
        ] {
            let result = try await runner.run(in: root.path, args: args)
            XCTAssertTrue(result.succeeded, result.stderr)
        }
        for message in ["base", "target"] {
            try "\(message)\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            _ = try await runner.run(in: root.path, args: ["add", "a.txt"])
            let result = try await runner.run(in: root.path, args: ["commit", "-qm", message])
            XCTAssertTrue(result.succeeded, result.stderr)
        }
        let git = GitService(runner: runner)
        let log = try await git.log(repoPath: root.path, count: 1)
        return Sandbox(runner: runner, git: git, root: root, repo: root.path, target: try XCTUnwrap(log.first))
    }

    private func makeApp(_ box: Sandbox, answer: RevertChoice) -> (AppState, RecordingPlatformServices) {
        let platform = RecordingPlatformServices()
        platform.revertAnswer = answer
        let app = makeIsolatedAppState(git: box.git, platform: platform)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)
        return (app, platform)
    }

    private func read(_ box: Sandbox, _ path: String = "a.txt") throws -> String {
        try String(contentsOfFile: (box.repo as NSString).appendingPathComponent(path), encoding: .utf8)
    }

    private func write(_ box: Sandbox, _ text: String, path: String = "a.txt") throws {
        try text.write(toFile: (box.repo as NSString).appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func testCancelDoesNotChangeHistoryOrFiles() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (app, platform) = makeApp(box, answer: .cancel)
        await app.revertCommit(box.target)

        let head = try await box.git.currentHeadSHA(repoPath: box.repo)
        XCTAssertEqual(head, box.target.hash)
        XCTAssertEqual(try read(box), "target\n")
        XCTAssertEqual(platform.reverts.count, 1)
        XCTAssertTrue(platform.reverts[0].commit.contains(box.target.shortHash))
        XCTAssertTrue(platform.reverts[0].commit.contains(box.target.subject))
        XCTAssertTrue(platform.reverts[0].canCommit)
    }

    func testRevertAndCommitCreatesOneCommitAndRefreshesTheJournal() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (app, _) = makeApp(box, answer: .commit)
        await app.revertCommit(box.target)

        let head = try XCTUnwrap(app.journalVM.commits.first)
        XCTAssertNotEqual(head.hash, box.target.hash)
        XCTAssertEqual(head.parentHashes, [box.target.hash])
        XCTAssertEqual(head.subject, "Revert \"target\"")
        XCTAssertEqual(try read(box), "base\n")
        XCTAssertTrue(app.filesVM.files.isEmpty)
        XCTAssertNil(app.inProgressOperation)
    }

    func testRevertLeavesTheResultStagedWithoutCreatingACommit() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let (app, _) = makeApp(box, answer: .workingTree)
        await app.revertCommit(box.target)

        let head = try await box.git.currentHeadSHA(repoPath: box.repo)
        XCTAssertEqual(head, box.target.hash)
        XCTAssertEqual(try read(box), "base\n")
        let index = try await box.runner.run(in: box.repo, args: ["show", ":a.txt"])
        XCTAssertEqual(index.stdout, "base\n")
        XCTAssertTrue(app.filesVM.files.contains { $0.path == "a.txt" && $0.isStaged })
        XCTAssertNil(app.inProgressOperation)
        XCTAssertTrue(app.statusText.contains("without committing"))
    }

    func testExistingStagedWorkIsKeptAndImmediateCommitIsNotOffered() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try write(box, "keep my work\n", path: "other.txt")
        _ = try await box.runner.run(in: box.repo, args: ["add", "other.txt"])
        let (app, platform) = makeApp(box, answer: .workingTree)
        await app.revertCommit(box.target)

        XCTAssertEqual(platform.reverts.first?.canCommit, false)
        let head = try await box.git.currentHeadSHA(repoPath: box.repo)
        XCTAssertEqual(head, box.target.hash)
        XCTAssertEqual(Set(app.filesVM.files.filter(\.isStaged).map(\.path)), ["a.txt", "other.txt"])
        XCTAssertEqual(try read(box, "other.txt"), "keep my work\n")
    }

    func testConflictContinuationRemembersWhetherToCommitAfterRestart() async throws {
        for noCommit in [false, true] {
            let box = try await makeSandbox()
            defer { try? FileManager.default.removeItem(at: box.root) }
            try write(box, "later\n")
            _ = try await box.runner.run(in: box.repo, args: ["commit", "-qam", "later"])
            let before = try await box.git.currentHeadSHA(repoPath: box.repo)
            let (app, _) = makeApp(box, answer: noCommit ? .workingTree : .commit)
            await app.revertCommit(box.target)
            XCTAssertEqual(app.inProgressOperation, .revert)
            XCTAssertTrue(app.filesVM.files.contains(where: \.isConflict))

            // A new service has no in-memory choice left. Continuing before
            // staging a resolution must keep the operation paused.
            let restarted = GitService(runner: box.runner)
            let unresolved = try await restarted.continueOperation(repoPath: box.repo, operation: .revert)
            XCTAssertFalse(unresolved.succeeded)
            let stillPaused = await restarted.inProgressOperation(repoPath: box.repo)
            XCTAssertEqual(stillPaused, .revert)
            try write(box, "resolved\n")
            _ = try await box.runner.run(in: box.repo, args: ["add", "a.txt"])
            let continued = try await restarted.continueOperation(repoPath: box.repo, operation: .revert)
            XCTAssertTrue(continued.succeeded, continued.stderr)

            let after = try await restarted.currentHeadSHA(repoPath: box.repo)
            let files = try await restarted.status(repoPath: box.repo)
            if noCommit {
                XCTAssertEqual(after, before, "Continue must preserve the no-commit choice")
                XCTAssertTrue(files.contains { $0.path == "a.txt" && $0.isStaged })
            } else {
                XCTAssertNotEqual(after, before)
                XCTAssertTrue(files.isEmpty)
            }
            let operation = await restarted.inProgressOperation(repoPath: box.repo)
            XCTAssertNil(operation)
        }
    }

    func testAbortingAnUncommittedRevertRestoresTheOriginalState() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try write(box, "later\n")
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-qam", "later"])
        let before = try await box.git.currentHeadSHA(repoPath: box.repo)
        let (app, platform) = makeApp(box, answer: .workingTree)
        await app.revertCommit(box.target)
        XCTAssertEqual(app.inProgressOperation, .revert)
        await app.abortInProgressOperation()
        let after = try await box.git.currentHeadSHA(repoPath: box.repo)
        XCTAssertEqual(after, before)
        XCTAssertEqual(try read(box), "later\n")
        XCTAssertNil(app.inProgressOperation)
        XCTAssertTrue(app.filesVM.files.isEmpty)

        // A later Revert & Commit must not inherit the abandoned choice.
        platform.revertAnswer = .commit
        await app.revertCommit(box.target)
        try write(box, "resolved\n")
        _ = try await box.runner.run(in: box.repo, args: ["add", "a.txt"])
        await app.continueInProgressOperation()
        let committed = try await box.git.currentHeadSHA(repoPath: box.repo)
        XCTAssertNotEqual(committed, before)
        XCTAssertTrue(app.filesVM.files.isEmpty)
    }

    func testNoCommitConflictChoiceIsStoredInTheLinkedWorktree() async throws {
        let main = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: main.root) }
        let linked = main.root.appendingPathComponent("linked").path
        let created = try await main.runner.run(in: main.repo, args: ["worktree", "add", "-q", "-b", "linked", linked])
        XCTAssertTrue(created.succeeded, created.stderr)
        let box = Sandbox(runner: main.runner, git: main.git, root: main.root, repo: linked, target: main.target)
        try write(box, "later\n")
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-qam", "later"])
        let before = try await box.git.currentHeadSHA(repoPath: box.repo)
        let reverted = try await box.git.revertCommit(repoPath: box.repo, hash: box.target.hash, noCommit: true)
        XCTAssertFalse(reverted.succeeded)
        try write(box, "resolved\n")
        _ = try await box.runner.run(in: box.repo, args: ["add", "a.txt"])

        let restarted = GitService(runner: box.runner)
        let continued = try await restarted.continueOperation(repoPath: box.repo, operation: .revert)
        XCTAssertTrue(continued.succeeded, continued.stderr)
        let after = try await restarted.currentHeadSHA(repoPath: box.repo)
        XCTAssertEqual(after, before)
        let mainHead = try await restarted.currentHeadSHA(repoPath: main.repo)
        XCTAssertEqual(mainHead, main.target.hash)
    }

    func testAbortingNoCommitRevertPreservesExistingStagedAndUnstagedWork() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try write(box, "later\n")
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-qam", "later"])
        let before = try await box.git.currentHeadSHA(repoPath: box.repo)
        try write(box, "staged work\n", path: "other.txt")
        _ = try await box.runner.run(in: box.repo, args: ["add", "other.txt"])
        try write(box, "staged and unstaged work\n", path: "other.txt")

        let reverted = try await box.git.revertCommit(repoPath: box.repo, hash: box.target.hash, noCommit: true)
        XCTAssertFalse(reverted.succeeded)
        let aborted = try await box.git.abortOperation(repoPath: box.repo, operation: .revert)
        XCTAssertTrue(aborted.succeeded, aborted.stderr)

        let after = try await box.git.currentHeadSHA(repoPath: box.repo)
        XCTAssertEqual(after, before)
        XCTAssertEqual(try read(box), "later\n")
        XCTAssertEqual(try read(box, "other.txt"), "staged and unstaged work\n")
        let index = try await box.runner.run(in: box.repo, args: ["show", ":other.txt"])
        XCTAssertEqual(index.stdout, "staged work\n")
        let operation = await box.git.inProgressOperation(repoPath: box.repo)
        XCTAssertNil(operation)
    }
}
