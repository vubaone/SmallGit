import XCTest
@testable import SmallGit

final class RemoteDetailsTests: XCTestCase {
    private struct Sandbox {
        let root: URL
        let git: GitService
        let runner: ProcessRunner
    }

    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner(importsUserShellEnvironment: false)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-remote-details-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = try await runner.run(in: root.path, args: ["init", "-q"])
        XCTAssertTrue(result.succeeded, result.stderr)
        return Sandbox(root: root, git: GitService(runner: runner), runner: runner)
    }

    private func configure(_ box: Sandbox, _ args: [String]) async throws {
        let result = try await box.runner.run(in: box.root.path, args: args)
        XCTAssertTrue(result.succeeded, result.stderr)
    }

    func testRepositoryWithoutRemotesReturnsAnEmptyList() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let remotes = try await box.git.remoteDetails(repoPath: box.root.path)
        XCTAssertTrue(remotes.isEmpty)
    }

    func testOriginUsesTheFetchURLForPushWhenNoPushURLIsSet() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        // An unreachable host proves this only reads local configuration.
        let url = "https://example.invalid/team/repo.git"
        try await configure(box, ["remote", "add", "origin", url])
        let remotes = try await box.git.remoteDetails(repoPath: box.root.path)
        XCTAssertEqual(remotes, [GitRemote(name: "origin", fetchURLs: [url], pushURLs: [url])])
    }

    func testMultipleRemotesAndPushURLsKeepTheirFullValues() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let fetch = "git@example.invalid:team/repo.git"
        let local = "/tmp/Remote repos/Dự án.git"
        let push = "ssh://git@write.example.invalid/team/repo.git"
        try await configure(box, ["remote", "add", "archive", local])
        try await configure(box, ["remote", "add", "origin", fetch])
        try await configure(box, ["config", "--add", "remote.origin.pushurl", push])
        try await configure(box, ["config", "--add", "remote.origin.pushurl", local])
        let remotes = try await box.git.remoteDetails(repoPath: box.root.path)
        XCTAssertEqual(remotes.map(\.name), ["origin", "archive"])
        XCTAssertEqual(remotes[0].fetchURLs, [fetch])
        XCTAssertEqual(remotes[0].pushURLs, [push, local])
        XCTAssertEqual(remotes[1].fetchURLs, [local])
        XCTAssertEqual(remotes[1].pushURLs, [local])
    }

    func testURLRewritesShowTheDestinationsGitActuallyUses() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await configure(box, ["config", "url.https://read.example.invalid/.insteadOf", "team:"])
        try await configure(box, ["config", "url.ssh://git@write.example.invalid/.pushInsteadOf", "team:"])
        try await configure(box, ["remote", "add", "origin", "team:repo.git"])
        let remotes = try await box.git.remoteDetails(repoPath: box.root.path)
        let remote = try XCTUnwrap(remotes.first)
        XCTAssertEqual(remote.fetchURLs, ["https://read.example.invalid/repo.git"])
        XCTAssertEqual(remote.pushURLs, ["ssh://git@write.example.invalid/repo.git"])
    }

    func testMultipleFetchURLsAndExplicitPushURLAreAllReported() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let urls = ["https://example.invalid/first.git", "https://example.invalid/second.git"]
        try await configure(box, ["remote", "add", "origin", urls[0]])
        try await configure(box, ["config", "--add", "remote.origin.url", urls[1]])
        try await configure(box, ["config", "remote.origin.pushurl", "git@example.invalid:push.git"])
        let remotes = try await box.git.remoteDetails(repoPath: box.root.path)
        let remote = try XCTUnwrap(remotes.first)
        XCTAssertEqual(remote.fetchURLs, urls)
        XCTAssertEqual(remote.pushURLs, ["git@example.invalid:push.git"])
    }
}
