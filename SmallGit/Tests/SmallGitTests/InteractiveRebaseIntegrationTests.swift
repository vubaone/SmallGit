import XCTest
@testable import SmallGit

/// End-to-end coverage for the interactive rebase backend. Spawns real
/// `git` against a temp repo, builds a todo, runs the rebase via
/// `GitService.runInteractiveRebase`, and asserts on the resulting log.
final class InteractiveRebaseIntegrationTests: XCTestCase {

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
        let git = GitService(runner: runner)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-irebase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main", "repo"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        return Sandbox(runner: runner, git: git, repo: repo, root: root)
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

    private func logSubjects(_ box: Sandbox) async throws -> [String] {
        let result = try await box.runner.run(
            in: box.repo,
            args: ["log", "--pretty=format:%s"]
        )
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func commitMessage(_ box: Sandbox, ref: String) async throws -> String {
        let result = try await box.runner.run(
            in: box.repo,
            args: ["log", "-1", "--pretty=format:%B", ref]
        )
        return result.stdout
    }

    // MARK: - commitsToRebase

    func testCommitsToRebaseReturnsOldestFirst() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await commit(box, file: "a", body: "a", message: "base")
        let baseSha = try await box.runner.run(
            in: box.repo, args: ["rev-parse", "HEAD"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try await commit(box, file: "b", body: "b", message: "second")
        try await commit(box, file: "c", body: "c", message: "third")
        try await commit(box, file: "d", body: "d", message: "fourth")

        let todo = try await box.git.commitsToRebase(repoPath: box.repo, base: baseSha)

        XCTAssertEqual(todo.map(\.subject), ["second", "third", "fourth"])
        XCTAssertTrue(todo.allSatisfy { $0.action == .pick })
    }

    func testCommitsToRebaseEmptyWhenAtBase() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await commit(box, file: "a", body: "a", message: "only")
        let todo = try await box.git.commitsToRebase(repoPath: box.repo, base: "HEAD")
        XCTAssertEqual(todo, [])
    }

    // MARK: - Validation

    func testPlanValidationRejectsLeadingSquash() {
        let plan: [RebaseTodo] = [
            RebaseTodo(hash: "aaaa", shortHash: "aaaa", subject: "x", action: .squash),
            RebaseTodo(hash: "bbbb", shortHash: "bbbb", subject: "y", action: .pick)
        ]
        XCTAssertNotNil(plan.validationError)
        XCTAssertTrue(plan.validationError!.contains("first commit cannot be squash"))
    }

    func testPlanValidationAcceptsLeadingPick() {
        let plan: [RebaseTodo] = [
            RebaseTodo(hash: "aaaa", shortHash: "aaaa", subject: "x", action: .pick),
            RebaseTodo(hash: "bbbb", shortHash: "bbbb", subject: "y", action: .squash)
        ]
        XCTAssertNil(plan.validationError)
    }

    func testTodoFileContentsTrailingNewline() {
        let plan: [RebaseTodo] = [
            RebaseTodo(hash: "aaa", shortHash: "aaa", subject: "x", action: .pick)
        ]
        XCTAssertEqual(plan.todoFileContents, "pick aaa x\n")
    }

    func testPlanValidationRejectsSquashBehindOnlyDrops() {
        let plan: [RebaseTodo] = [
            RebaseTodo(hash: "aaaa", shortHash: "aaaa", subject: "x", action: .drop),
            RebaseTodo(hash: "bbbb", shortHash: "bbbb", subject: "y", action: .squash)
        ]
        XCTAssertTrue(plan.validationError?.contains("first commit cannot be squash") == true)
    }

    // MARK: - Squash groups

    func testSquashTargetSkipsDropsAndOtherSquashes() {
        let plan: [RebaseTodo] = [
            RebaseTodo(hash: "a", shortHash: "a", subject: "A", action: .pick),
            RebaseTodo(hash: "b", shortHash: "b", subject: "B", action: .drop),
            RebaseTodo(hash: "c", shortHash: "c", subject: "C", action: .squash),
            RebaseTodo(hash: "d", shortHash: "d", subject: "D", action: .fixup),
            RebaseTodo(hash: "e", shortHash: "e", subject: "E", action: .pick)
        ]
        XCTAssertEqual(plan.squashTarget(of: 2), 0)
        XCTAssertEqual(plan.squashTarget(of: 3), 0)
        XCTAssertNil(plan.squashTarget(of: 4))
        XCTAssertEqual(plan.squashMembers(of: 0), [2, 3])
        XCTAssertEqual(plan.squashMembers(of: 4), [])
        XCTAssertTrue(plan.needsMessageReview(0))
        XCTAssertFalse(plan.needsMessageReview(4))

        var reviewed = plan
        reviewed[0].message = "A+C"
        XCTAssertFalse(reviewed.needsMessageReview(0))
    }

    func testFixupOnlyGroupNeedsNoReview() {
        let plan: [RebaseTodo] = [
            RebaseTodo(hash: "a", shortHash: "a", subject: "A", action: .pick),
            RebaseTodo(hash: "b", shortHash: "b", subject: "B", action: .fixup)
        ]
        XCTAssertFalse(plan.needsMessageReview(0))
    }

    func testEditedMessageAmendsAfterTheWholeGroup() {
        let plan: [RebaseTodo] = [
            RebaseTodo(hash: "a", shortHash: "a", subject: "A", action: .pick, message: "new"),
            RebaseTodo(hash: "b", shortHash: "b", subject: "B", action: .squash),
            RebaseTodo(hash: "c", shortHash: "c", subject: "C", action: .pick)
        ]
        let lines = plan.todoFileContents.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "pick a A")
        XCTAssertEqual(lines[1], "squash b B")
        XCTAssertTrue(lines[2].hasPrefix("exec printf"))
        XCTAssertEqual(lines[3], "pick c C")
    }

    func testSquashWithEditedMessageReplacesStackedMessages() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        try await commit(box, file: "a", body: "a", message: "base")
        let baseSha = try await box.runner.run(
            in: box.repo, args: ["rev-parse", "HEAD"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try await commit(box, file: "b", body: "b", message: "feature: add b")
        try await commit(box, file: "c", body: "c", message: "feature: add c")
        try await commit(box, file: "d", body: "d", message: "feature: add d")

        var todo = try await box.git.commitsToRebase(repoPath: box.repo, base: baseSha)
        todo[0].message = "feature: add b and c\n\nOne change, really."
        todo[1].action = .squash

        let result = try await box.git.runInteractiveRebase(repoPath: box.repo, onto: baseSha, todo: todo)
        XCTAssertTrue(result.succeeded, "rebase failed: \(result.combinedOutput)")

        let subjects = try await logSubjects(box)
        XCTAssertEqual(subjects, ["feature: add d", "feature: add b and c", "base"])
        let squashed = try await commitMessage(box, ref: "HEAD~1")
        XCTAssertEqual(
            squashed.trimmingCharacters(in: .whitespacesAndNewlines),
            "feature: add b and c\n\nOne change, really."
        )
        let files = try await box.runner.run(in: box.repo, args: ["show", "--name-only", "--format=", "HEAD~1"])
        XCTAssertEqual(files.stdout.split(separator: "\n").sorted(), ["b", "c"])
    }

    func testRewordKeepsShellAndFormatCharactersVerbatim() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        try await commit(box, file: "a", body: "a", message: "base")
        let baseSha = try await box.runner.run(
            in: box.repo, args: ["rev-parse", "HEAD"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try await commit(box, file: "b", body: "b", message: "old b")
        try await commit(box, file: "c", body: "c", message: "old c")

        let message = "-n it's 100% \\n \"$HOME\" `id` \\c\n# kept"
        var todo = try await box.git.commitsToRebase(repoPath: box.repo, base: baseSha)
        todo[0].message = message

        let result = try await box.git.runInteractiveRebase(repoPath: box.repo, onto: baseSha, todo: todo)
        XCTAssertTrue(result.succeeded, "rebase failed: \(result.combinedOutput)")

        let reworded = try await commitMessage(box, ref: "HEAD~1")
        XCTAssertEqual(reworded.trimmingCharacters(in: .newlines), message)
        let top = try await commitMessage(box, ref: "HEAD")
        XCTAssertEqual(top.trimmingCharacters(in: .newlines), "old c")
    }

    // MARK: - Squash + fixup end-to-end

    func testInteractiveRebaseSquashAndFixupCollapsesThreeCommits() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        try await commit(box, file: "a", body: "a", message: "base")
        let baseSha = try await box.runner.run(
            in: box.repo, args: ["rev-parse", "HEAD"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try await commit(box, file: "b", body: "b", message: "feature: add b")
        try await commit(box, file: "c", body: "c", message: "feature: add c")
        try await commit(box, file: "d", body: "d", message: "feature: add d")

        var todo = try await box.git.commitsToRebase(repoPath: box.repo, base: baseSha)
        XCTAssertEqual(todo.count, 3)
        todo[1].action = .squash
        todo[2].action = .fixup

        let result = try await box.git.runInteractiveRebase(
            repoPath: box.repo,
            onto: baseSha,
            todo: todo
        )
        XCTAssertTrue(result.succeeded, "rebase failed: \(result.combinedOutput)")

        let subjects = try await logSubjects(box)
        XCTAssertEqual(subjects.count, 2, "expected base + 1 collapsed commit, got \(subjects)")
        XCTAssertEqual(subjects.last, "base")

        let collapsed = try await commitMessage(box, ref: "HEAD")
        XCTAssertTrue(collapsed.contains("feature: add b"))
        XCTAssertTrue(collapsed.contains("feature: add c"))
        XCTAssertFalse(
            collapsed.contains("feature: add d"),
            "fixup should discard the fixup'd commit's message — got:\n\(collapsed)"
        )
    }

    // MARK: - Drop

    func testInteractiveRebaseDropRemovesCommit() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        try await commit(box, file: "a", body: "a", message: "base")
        let baseSha = try await box.runner.run(
            in: box.repo, args: ["rev-parse", "HEAD"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try await commit(box, file: "b", body: "b", message: "keep me")
        try await commit(box, file: "c", body: "c", message: "drop me")

        var todo = try await box.git.commitsToRebase(repoPath: box.repo, base: baseSha)
        todo[1].action = .drop

        let result = try await box.git.runInteractiveRebase(
            repoPath: box.repo,
            onto: baseSha,
            todo: todo
        )
        XCTAssertTrue(result.succeeded, "rebase failed: \(result.combinedOutput)")

        let subjects = try await logSubjects(box)
        XCTAssertEqual(subjects, ["keep me", "base"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(box.repo)/c"))
    }

    // MARK: - Reorder

    func testInteractiveRebaseReorderSwapsAdjacentCommits() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        try await commit(box, file: "a", body: "a", message: "base")
        let baseSha = try await box.runner.run(
            in: box.repo, args: ["rev-parse", "HEAD"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try await commit(box, file: "b", body: "b", message: "B")
        try await commit(box, file: "c", body: "c", message: "C")

        var todo = try await box.git.commitsToRebase(repoPath: box.repo, base: baseSha)
        XCTAssertEqual(todo.map(\.subject), ["B", "C"])
        // Swap: replay C first, then B.
        todo.swapAt(0, 1)

        let result = try await box.git.runInteractiveRebase(
            repoPath: box.repo,
            onto: baseSha,
            todo: todo
        )
        XCTAssertTrue(result.succeeded, "rebase failed: \(result.combinedOutput)")

        let subjects = try await logSubjects(box)
        XCTAssertEqual(subjects, ["B", "C", "base"])
    }
}
