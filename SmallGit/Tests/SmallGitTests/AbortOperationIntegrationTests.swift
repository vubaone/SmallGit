import XCTest
@testable import SmallGit

/// Covers aborting whatever conflicted operation is actually paused.
///
/// The resolver used to hardcode `git merge --abort`. That is right for a
/// merge and wrong for everything else: a rebase, cherry-pick or revert leaves
/// no `MERGE_HEAD`, so the command fails — and the failure was discarded, so
/// the window closed reporting success while the conflict was still there.
final class AbortOperationIntegrationTests: XCTestCase {

    private var repo: URL!
    private let git = GitService.shared

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                          "git not available")
        repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AbortOp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Two branches that both change the same line, so merging or rebasing
    /// one onto the other conflicts.
    private func makeDivergentHistory() throws {
        try run(["init", "-q", "-b", "main", "."])
        try run(["config", "user.email", "t@t"])
        try run(["config", "user.name", "t"])
        try write("base\n", to: "a.txt")
        try run(["add", "-A"])
        try run(["commit", "-qm", "base"])
        try run(["checkout", "-qb", "feature"])
        try write("theirs\n", to: "a.txt")
        try run(["commit", "-qam", "theirs"])
        try run(["checkout", "-q", "main"])
        try write("ours\n", to: "a.txt")
        try run(["commit", "-qam", "ours"])
    }

    private var conflictedFiles: [String] {
        ((try? run(["diff", "--name-only", "--diff-filter=U"])) ?? "")
            .split(separator: "\n").map(String.init)
    }

    // MARK: - Detection

    func testMergeAndRebaseConflictsAreDetectedAsDifferentOperations() async throws {
        try makeDivergentHistory()
        try run(["merge", "feature"])
        let merge = await git.inProgressOperation(repoPath: repo.path)
        XCTAssertEqual(merge, .merge)

        try run(["merge", "--abort"])
        try run(["checkout", "-q", "feature"])
        try run(["rebase", "main"])
        let rebase = await git.inProgressOperation(repoPath: repo.path)
        XCTAssertEqual(rebase, .rebase, "a rebase conflict is not a merge")
    }

    // MARK: - Aborting

    func testAbortingAMergeClearsTheConflict() async throws {
        try makeDivergentHistory()
        try run(["merge", "feature"])
        XCTAssertFalse(conflictedFiles.isEmpty)

        let result = try await git.abortOperation(repoPath: repo.path, operation: .merge)

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(conflictedFiles.isEmpty)
        let after = await git.inProgressOperation(repoPath: repo.path)
        XCTAssertNil(after)
    }

    /// The bug. `merge --abort` during a rebase fails outright, so a resolver
    /// that ignores the result leaves the user stuck mid-rebase believing they
    /// backed out.
    func testMergeAbortFailsDuringARebaseRatherThanSilentlyDoingNothing() async throws {
        try makeDivergentHistory()
        try run(["checkout", "-q", "feature"])
        try run(["rebase", "main"])
        XCTAssertFalse(conflictedFiles.isEmpty)

        let wrong = try await git.abortOperation(repoPath: repo.path, operation: .merge)

        XCTAssertFalse(wrong.succeeded, "there is no merge to abort in a rebase")
        XCTAssertFalse(conflictedFiles.isEmpty, "and the conflict is still there afterwards")
        let still = await git.inProgressOperation(repoPath: repo.path)
        XCTAssertEqual(still, .rebase)
    }

    /// Aborting the operation that is actually paused does work.
    func testAbortingTheDetectedOperationClearsARebaseConflict() async throws {
        try makeDivergentHistory()
        try run(["checkout", "-q", "feature"])
        try run(["rebase", "main"])

        let detected = await git.inProgressOperation(repoPath: repo.path)
        let operation = try XCTUnwrap(detected)
        let result = try await git.abortOperation(repoPath: repo.path, operation: operation)

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(conflictedFiles.isEmpty)
        let after = await git.inProgressOperation(repoPath: repo.path)
        XCTAssertNil(after)
    }

    /// What the user actually reported: a merge abort takes *every* conflicted
    /// file back, not just the one open in the resolver. That is correct git
    /// behaviour, and the reason the confirmation now spells the scope out.
    func testAbortingAMergeAffectsEveryConflictedFileNotJustOne() async throws {
        try run(["init", "-q", "-b", "main", "."])
        try run(["config", "user.email", "t@t"])
        try run(["config", "user.name", "t"])
        try write("base\n", to: "a.txt")
        try write("base\n", to: "b.txt")
        try run(["add", "-A"])
        try run(["commit", "-qm", "base"])
        try run(["checkout", "-qb", "feature"])
        try write("theirs\n", to: "a.txt")
        try write("theirs\n", to: "b.txt")
        try run(["commit", "-qam", "theirs"])
        try run(["checkout", "-q", "main"])
        try write("ours\n", to: "a.txt")
        try write("ours\n", to: "b.txt")
        try run(["commit", "-qam", "ours"])
        try run(["merge", "feature"])
        XCTAssertEqual(conflictedFiles.count, 2)

        _ = try await git.abortOperation(repoPath: repo.path, operation: .merge)

        XCTAssertTrue(conflictedFiles.isEmpty, "both files leave the conflict list, by design")
        let contents = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(contents, "ours\n", "the working tree returns to the pre-merge state")
    }
}
