import XCTest
@testable import SmallGit

/// The guards around an interactive rebase: waiting out another program's
/// `index.lock`, mending a squash git died in the middle of, and checking a
/// finished planned rebase against its plan.
final class RebaseGuardTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        let repo: String
        let root: URL
        var gitDir: String { repo + "/.git" }
    }

    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-rguard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main", "repo"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        return Sandbox(runner: runner, git: GitService(runner: runner), repo: repo, root: root)
    }

    private func commit(_ box: Sandbox, file: String, body: String, message: String) async throws {
        try body.write(
            to: URL(fileURLWithPath: box.repo).appendingPathComponent(file),
            atomically: true,
            encoding: .utf8
        )
        _ = try await box.runner.run(in: box.repo, args: ["add", file])
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-q", "-m", message])
    }

    private func rev(_ box: Sandbox, _ ref: String) async throws -> String {
        try await box.runner.run(in: box.repo, args: ["rev-parse", ref])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func subjects(_ box: Sandbox) async throws -> [String] {
        try await box.runner.run(in: box.repo, args: ["log", "--format=%s"])
            .stdout.split(separator: "\n").map(String.init)
    }

    /// `pick a; squash b; pick c`, stopped on the squash with its changes
    /// staged — by an editor that fails once, the one stop that can be made
    /// to happen on cue. `asIfKilled` then erases what git records for a
    /// squash it stopped on in good order (`amend`, `current-fixups`),
    /// leaving what a `fatal:` leaves.
    private func stopOnSquash(_ box: Sandbox, asIfKilled: Bool) async throws {
        try await commit(box, file: "base", body: "base", message: "base")
        let base = try await rev(box, "HEAD")
        try await commit(box, file: "a", body: "a", message: "a")
        try await commit(box, file: "b", body: "b", message: "b")
        try await commit(box, file: "c", body: "c", message: "c")
        let (a, b, c) = (try await rev(box, "HEAD~2"), try await rev(box, "HEAD~1"), try await rev(box, "HEAD"))

        let todo = box.root.appendingPathComponent("todo")
        try "pick \(a) a\nsquash \(b) b\npick \(c) c\n".write(to: todo, atomically: true, encoding: .utf8)
        let editor = box.root.appendingPathComponent("editor")
        let once = box.root.appendingPathComponent("once").path
        try "#!/bin/sh\nif [ ! -f '\(once)' ]; then touch '\(once)'; exit 1; fi\nexit 0\n"
            .write(to: editor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: editor.path)

        let stopped = try await box.runner.run(
            in: box.repo,
            args: ["rebase", "-i", base],
            env: ["GIT_SEQUENCE_EDITOR": "cp \(todo.path)", "GIT_EDITOR": editor.path]
        )
        XCTAssertFalse(stopped.succeeded, "the squash should have stopped")
        if asIfKilled {
            try "".write(toFile: box.gitDir + "/rebase-merge/current-fixups", atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: box.gitDir + "/rebase-merge/amend")
        }
    }

    // MARK: - Interrupted squash

    func testContinueMendsASquashGitDiedIn() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await stopOnSquash(box, asIfKilled: true)

        let result = try await box.git.continueOperation(repoPath: box.repo, operation: .rebase)
        XCTAssertTrue(result.succeeded, result.combinedOutput)

        let log = try await subjects(box)
        XCTAssertEqual(log, ["c", "a", "base"], "the squash must not come out as a commit of its own")
        let squashed = try await box.runner.run(in: box.repo, args: ["log", "-1", "--format=%B", "HEAD~1"]).stdout
        XCTAssertEqual(squashed.trimmingCharacters(in: .whitespacesAndNewlines), "a\n\nb")
        let files = try await box.runner.run(in: box.repo, args: ["show", "--name-only", "--format=", "HEAD~1"])
        XCTAssertEqual(files.stdout.split(separator: "\n").sorted(), ["a", "b"])
    }

    func testOrdinarySquashStopIsLeftToGit() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await stopOnSquash(box, asIfKilled: false)

        let mended = try await box.git.mendInterruptedSquash(repoPath: box.repo)
        XCTAssertNil(mended, "a squash git recorded is git's to finish")

        let result = try await box.git.continueOperation(repoPath: box.repo, operation: .rebase)
        XCTAssertTrue(result.succeeded, result.combinedOutput)
        let log = try await subjects(box)
        XCTAssertEqual(log, ["c", "a", "base"])
    }

    func testContinueFinishesAPickGitDiedIn() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await commit(box, file: "base", body: "base", message: "base")
        let base = try await rev(box, "HEAD")
        try await commit(box, file: "a", body: "a", message: "a")
        try await commit(box, file: "b", body: "b", message: "b\n\nbody of b")
        let (a, b) = (try await rev(box, "HEAD~1"), try await rev(box, "HEAD"))

        // Stop after "a", then leave what a kill mid-pick of "b" leaves:
        // the pick noted as done, its changes staged, no commit for it.
        let todo = box.root.appendingPathComponent("todo")
        try "pick \(a) a\nbreak\n".write(to: todo, atomically: true, encoding: .utf8)
        _ = try await box.runner.run(
            in: box.repo, args: ["rebase", "-i", base], env: ["GIT_SEQUENCE_EDITOR": "cp \(todo.path)"]
        )
        let done = box.gitDir + "/rebase-merge/done"
        try (try String(contentsOfFile: done, encoding: .utf8) + "pick \(b) b\n")
            .write(toFile: done, atomically: true, encoding: .utf8)
        _ = try await box.runner.run(in: box.repo, args: ["cherry-pick", "--no-commit", b])

        let result = try await box.git.continueOperation(repoPath: box.repo, operation: .rebase)
        XCTAssertTrue(result.succeeded, result.combinedOutput)
        let log = try await subjects(box)
        XCTAssertEqual(log, ["b", "a", "base"])
        let message = try await box.runner.run(in: box.repo, args: ["log", "-1", "--format=%B"]).stdout
        XCTAssertEqual(message.trimmingCharacters(in: .whitespacesAndNewlines), "b\n\nbody of b")
    }

    // MARK: - Foreign index.lock

    func testWaitsOutAnIndexLockThatGoesAway() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await commit(box, file: "a", body: "a", message: "a")
        let lock = box.gitDir + "/index.lock"
        FileManager.default.createFile(atPath: lock, contents: nil)
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? FileManager.default.removeItem(atPath: lock)
        }
        let age = await box.git.waitForIndexLock(repoPath: box.repo, patience: 3)
        XCTAssertNil(age)
    }

    func testGivesUpOnAnIndexLockThatStays() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await commit(box, file: "a", body: "a", message: "a")
        FileManager.default.createFile(atPath: box.gitDir + "/index.lock", contents: nil)
        let age = await box.git.waitForIndexLock(repoPath: box.repo, patience: 0.3)
        XCTAssertNotNil(age)
    }

    func testRecognisesIndexLockFailure() {
        let failed = GitCommandResult(
            command: "git rebase --continue",
            exitCode: 128,
            stdout: "",
            stderr: "fatal: Unable to create '/r/.git/index.lock': File exists.",
            duration: 0
        )
        XCTAssertTrue(GitService.failedOnIndexLock(failed))
        let conflict = GitCommandResult(
            command: "git rebase --continue", exitCode: 1, stdout: "", stderr: "CONFLICT (content)", duration: 0
        )
        XCTAssertFalse(GitService.failedOnIndexLock(conflict))
    }

    // MARK: - Outcome check

    func testPlannedRebaseThatWentToPlanPassesTheCheck() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await commit(box, file: "base", body: "base", message: "base")
        let base = try await rev(box, "HEAD")
        try await commit(box, file: "a", body: "a", message: "a")
        try await commit(box, file: "b", body: "b", message: "b")

        var todo = try await box.git.commitsToRebase(repoPath: box.repo, base: base)
        todo[1].action = .squash
        let result = try await box.git.runInteractiveRebase(repoPath: box.repo, onto: base, todo: todo)
        XCTAssertTrue(result.succeeded, result.combinedOutput)

        let mismatch = await box.git.checkRebaseOutcome(repoPath: box.repo)
        XCTAssertNil(mismatch)
    }

    func testSplitSquashIsCaughtAndUndone() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await commit(box, file: "f", body: "0", message: "base")
        let base = try await rev(box, "HEAD")
        try await commit(box, file: "f", body: "1", message: "one")
        try await commit(box, file: "g", body: "g", message: "gee")
        try await commit(box, file: "f", body: "2", message: "two")
        let original = try await rev(box, "HEAD")

        // Without "one", folding "two" in conflicts and the rebase stops.
        var todo = try await box.git.commitsToRebase(repoPath: box.repo, base: base)
        todo[0].action = .drop
        todo[2].action = .squash
        let stopped = try await box.git.runInteractiveRebase(repoPath: box.repo, onto: base, todo: todo)
        XCTAssertFalse(stopped.succeeded)
        let inProgress = await box.git.inProgressOperation(repoPath: box.repo)
        XCTAssertEqual(inProgress, .rebase)

        // Finished the way a split ends up: the squash committed on its own.
        try "2".write(toFile: box.repo + "/f", atomically: true, encoding: .utf8)
        _ = try await box.runner.run(in: box.repo, args: ["add", "f"])
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-q", "-m", "two"])
        _ = try await box.runner.run(in: box.repo, args: ["-c", "core.editor=true", "rebase", "--continue"])
        let finished = await box.git.inProgressOperation(repoPath: box.repo)
        XCTAssertNil(finished)

        let checked = await box.git.checkRebaseOutcome(repoPath: box.repo)
        let mismatch = try XCTUnwrap(checked)
        XCTAssertEqual(mismatch.expectedCommits, 1)
        XCTAssertGreaterThan(mismatch.actualCommits, 1)
        XCTAssertEqual(mismatch.originalHead, original)
        let again = await box.git.checkRebaseOutcome(repoPath: box.repo)
        XCTAssertNil(again, "the check is asked once")

        let undone = try await box.git.undoRebase(repoPath: box.repo, to: mismatch.originalHead)
        XCTAssertTrue(undone.succeeded, undone.combinedOutput)
        let head = try await rev(box, "HEAD")
        XCTAssertEqual(head, original)
    }

    func testAbortForgetsThePlan() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await commit(box, file: "f", body: "0", message: "base")
        let base = try await rev(box, "HEAD")
        try await commit(box, file: "f", body: "1", message: "one")
        try await commit(box, file: "f", body: "2", message: "two")

        var todo = try await box.git.commitsToRebase(repoPath: box.repo, base: base)
        todo.swapAt(0, 1)
        let stopped = try await box.git.runInteractiveRebase(repoPath: box.repo, onto: base, todo: todo)
        XCTAssertFalse(stopped.succeeded)
        let aborted = try await box.git.abortOperation(repoPath: box.repo, operation: .rebase)
        XCTAssertTrue(aborted.succeeded, aborted.combinedOutput)

        let mismatch = await box.git.checkRebaseOutcome(repoPath: box.repo)
        XCTAssertNil(mismatch)
    }
}
