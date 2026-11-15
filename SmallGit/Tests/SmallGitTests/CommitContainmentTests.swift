import XCTest
@testable import SmallGit

/// `git branch --contains` / `git describe --contains` behind the Log
/// window's "CONTAINED IN" section.
final class CommitContainmentTests: XCTestCase {

    private func makeRepo() async throws -> (path: String, root: URL, runner: ProcessRunner) {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-contains-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: root.path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: root.path, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: root.path, args: ["config", "commit.gpgsign", "false"])
        return (root.path, root, runner)
    }

    private func commit(_ runner: ProcessRunner, _ path: String, _ message: String) async throws -> String {
        _ = try await runner.run(in: path, args: ["commit", "-q", "--allow-empty", "-m", message])
        let r = try await runner.run(in: path, args: ["rev-parse", "HEAD"])
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testListsEveryBranchThatContainsTheCommit() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let base = try await commit(repo.runner, repo.path, "base")
        _ = try await repo.runner.run(in: repo.path, args: ["branch", "feature"])
        _ = try await repo.runner.run(in: repo.path, args: ["checkout", "-q", "-b", "later"])
        let tip = try await commit(repo.runner, repo.path, "only on later")

        let baseContainment = try await GitService.shared.containment(repoPath: repo.path, hash: base)
        XCTAssertEqual(Set(baseContainment.branches), ["main", "feature", "later"],
            "every branch descends from the base commit")

        let tipContainment = try await GitService.shared.containment(repoPath: repo.path, hash: tip)
        XCTAssertEqual(tipContainment.branches, ["later"],
            "a commit only on one branch is contained by only that branch")
    }

    func testReportsTheClosestContainingTagWithoutItsDistanceSuffix() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let old = try await commit(repo.runner, repo.path, "old")
        _ = try await commit(repo.runner, repo.path, "middle")
        _ = try await commit(repo.runner, repo.path, "release")
        _ = try await repo.runner.run(in: repo.path, args: ["tag", "-a", "v1.0", "-m", "v1.0"])
        _ = try await commit(repo.runner, repo.path, "after the tag")

        let found = try await GitService.shared.containment(repoPath: repo.path, hash: old)
        XCTAssertEqual(found.closestTag, "v1.0",
            "describe --contains reports v1.0~2 — the distance isn't part of the name")
    }

    func testNoContainingTagIsAnAnswerNotAFailure() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let only = try await commit(repo.runner, repo.path, "untagged")
        let found = try await GitService.shared.containment(repoPath: repo.path, hash: only)
        XCTAssertNil(found.closestTag)
        XCTAssertEqual(found.branches, ["main"])
        XCTAssertFalse(found.isEmpty)
    }

    /// `origin/HEAD` is a symref onto a branch already in the list.
    func testSymrefsAreNotListedTwice() async throws {
        let origin = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: origin.root) }
        let head = try await commit(origin.runner, origin.path, "shared")

        let cloneRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-contains-clone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cloneRoot) }
        _ = try await origin.runner.run(
            in: FileManager.default.temporaryDirectory.path,
            args: ["clone", "-q", origin.path, cloneRoot.path]
        )

        let found = try await GitService.shared.containment(repoPath: cloneRoot.path, hash: head)
        XCTAssertFalse(found.branches.contains { $0.hasSuffix("/HEAD") },
            "origin/HEAD names a branch that's already listed")
        XCTAssertTrue(found.branches.contains("main"))
        XCTAssertTrue(found.branches.contains("origin/main"))
    }
}
