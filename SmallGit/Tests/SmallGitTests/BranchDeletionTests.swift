import XCTest
@testable import SmallGit

/// The delete-branch dialog only helps if its pre-flight check agrees with
/// what `git branch -d` actually does, so these run both against a real git
/// and compare the two.
final class BranchDeletionTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        let origin: String
        let repo: String
        let root: URL
    }

    private func makeSandbox(_ label: String) async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let git = GitService(runner: runner)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let origin = root.appendingPathComponent("origin.git").path
        _ = try await runner.run(in: root.path, args: ["init", "--bare", "-q", "-b", "main", "origin.git"])

        let repo = root.appendingPathComponent("work").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main", "work"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        _ = try await runner.run(in: repo, args: ["remote", "add", "origin", "file://\(origin)"])
        try await commit(runner: runner, repo: repo, file: "README.md", text: "seed\n", message: "seed")
        _ = try await runner.run(in: repo, args: ["push", "-q", "-u", "origin", "main"])

        return Sandbox(runner: runner, git: git, origin: origin, repo: repo, root: root)
    }

    private func commit(runner: ProcessRunner, repo: String, file: String, text: String, message: String) async throws {
        try text.write(
            to: URL(fileURLWithPath: repo).appendingPathComponent(file),
            atomically: true, encoding: .utf8
        )
        _ = try await runner.run(in: repo, args: ["add", file])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", message])
    }

    private func branch(named name: String, in git: GitService, repo: String) async throws -> GitBranch {
        let all = try await git.localBranches(repoPath: repo)
        return try XCTUnwrap(all.first { $0.name == name }, "branch \(name) missing from \(all.map(\.name))")
    }

    // MARK: -

    func testMergedBranchIsReportedSafe() async throws {
        let box = try await makeSandbox("delete-merged")
        defer { try? FileManager.default.removeItem(at: box.root) }

        _ = try await box.git.createBranch(repoPath: box.repo, name: "feature", from: nil, checkout: true)
        try await commit(runner: box.runner, repo: box.repo, file: "a.txt", text: "a\n", message: "a")
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "main"])
        _ = try await box.runner.run(in: box.repo, args: ["merge", "-q", "--no-ff", "-m", "merge", "feature"])

        let check = try await box.git.branchDeletionCheck(
            repoPath: box.repo, branch: "feature", upstream: nil, comparedTo: "main"
        )
        XCTAssertTrue(check.isFullyMerged)
        XCTAssertEqual(check.mergedInto, "main")
        XCTAssertFalse(check.isMergedElsewhere)
        XCTAssertEqual(check.unmergedCount, 0)

        let deleted = try await box.git.deleteBranch(repoPath: box.repo, name: "feature", force: false)
        XCTAssertTrue(deleted.succeeded, "git disagreed: \(deleted.combinedOutput)")
    }

    func testUnmergedBranchCountsWhatWouldBeLost() async throws {
        let box = try await makeSandbox("delete-unmerged")
        defer { try? FileManager.default.removeItem(at: box.root) }

        _ = try await box.git.createBranch(repoPath: box.repo, name: "feature", from: nil, checkout: true)
        try await commit(runner: box.runner, repo: box.repo, file: "a.txt", text: "a\n", message: "a")
        try await commit(runner: box.runner, repo: box.repo, file: "b.txt", text: "b\n", message: "b")
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "main"])

        let check = try await box.git.branchDeletionCheck(
            repoPath: box.repo, branch: "feature", upstream: nil, comparedTo: "main"
        )
        XCTAssertFalse(check.isFullyMerged)
        XCTAssertNil(check.mergedInto)
        XCTAssertEqual(check.unmergedCount, 2)

        // The check said -d would be refused; confirm git refuses it, and
        // that -D is what gets through.
        let safe = try await box.git.deleteBranch(repoPath: box.repo, name: "feature", force: false)
        XCTAssertFalse(safe.succeeded)
        XCTAssertTrue(safe.combinedOutput.contains("not fully merged"), safe.combinedOutput)

        let forced = try await box.git.deleteBranch(repoPath: box.repo, name: "feature", force: true)
        XCTAssertTrue(forced.succeeded, forced.combinedOutput)
    }

    func testBranchMergedOnlyIntoUpstreamIsStillSafe() async throws {
        let box = try await makeSandbox("delete-upstream")
        defer { try? FileManager.default.removeItem(at: box.root) }

        _ = try await box.git.createBranch(repoPath: box.repo, name: "feature", from: nil, checkout: true)
        try await commit(runner: box.runner, repo: box.repo, file: "a.txt", text: "a\n", message: "a")
        _ = try await box.runner.run(in: box.repo, args: ["push", "-q", "-u", "origin", "feature"])
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "main"])

        let feature = try await branch(named: "feature", in: box.git, repo: box.repo)
        XCTAssertEqual(feature.upstream, "origin/feature")

        let check = try await box.git.branchDeletionCheck(
            repoPath: box.repo, branch: "feature", upstream: feature.upstream, comparedTo: "main"
        )
        XCTAssertTrue(check.isFullyMerged)
        XCTAssertEqual(check.mergedInto, "origin/feature")
        // Pushed, but main has never seen it — the dialog says so rather than
        // claiming nothing is at stake.
        XCTAssertTrue(check.isMergedElsewhere)
        XCTAssertEqual(check.unmergedCount, 1)

        let deleted = try await box.git.deleteBranch(repoPath: box.repo, name: "feature", force: false)
        XCTAssertTrue(deleted.succeeded, "git disagreed: \(deleted.combinedOutput)")
    }

    func testBranchWithGoneUpstreamIsReportedUnmerged() async throws {
        let box = try await makeSandbox("delete-gone")
        defer { try? FileManager.default.removeItem(at: box.root) }

        _ = try await box.git.createBranch(repoPath: box.repo, name: "feature", from: nil, checkout: true)
        try await commit(runner: box.runner, repo: box.repo, file: "a.txt", text: "a\n", message: "a")
        _ = try await box.runner.run(in: box.repo, args: ["push", "-q", "-u", "origin", "feature"])
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "main"])
        // The branch is deleted on the remote and pruned locally — the state
        // the sidebar shows as "[gone]".
        _ = try await box.runner.run(in: box.repo, args: ["push", "-q", "origin", "--delete", "feature"])
        _ = try await box.runner.run(in: box.repo, args: ["fetch", "-q", "--prune", "origin"])

        let feature = try await branch(named: "feature", in: box.git, repo: box.repo)
        XCTAssertTrue(feature.upstreamGone, "expected [gone], got \(feature.upstreamTrack ?? "nil")")

        let check = try await box.git.branchDeletionCheck(
            repoPath: box.repo, branch: "feature", upstream: feature.upstream, comparedTo: "main"
        )
        XCTAssertFalse(check.isFullyMerged, "a vanished upstream can't vouch for the commits")
        XCTAssertEqual(check.unmergedCount, 1)

        let safe = try await box.git.deleteBranch(repoPath: box.repo, name: "feature", force: false)
        XCTAssertFalse(safe.succeeded, "git should refuse this too")
    }
}
