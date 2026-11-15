import XCTest
@testable import SmallGit

final class BranchRenameTests: XCTestCase {

    func testRenameLocalBranchAgainstRealGit() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        try "hi\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "a.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])

        _ = try await git.createBranch(repoPath: repo, name: "feature/old", from: nil, checkout: false)
        var locals = (try await git.localBranches(repoPath: repo)).map(\.name)
        XCTAssertTrue(locals.contains("feature/old"), "setup failed; got: \(locals)")

        _ = try await git.renameBranch(repoPath: repo, from: "feature/old", to: "feature/new")
        locals = (try await git.localBranches(repoPath: repo)).map(\.name)
        XCTAssertFalse(locals.contains("feature/old"), "old branch should be gone, got: \(locals)")
        XCTAssertTrue(locals.contains("feature/new"), "new branch missing, got: \(locals)")
    }

    func testRenameCheckedOutBranchUpdatesHEAD() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-rename-head-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        try "hi\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "a.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])

        _ = try await git.renameBranch(repoPath: repo, from: "main", to: "trunk")
        let head = try await git.currentBranch(repoPath: repo)
        XCTAssertEqual(head, "trunk")
    }
}
