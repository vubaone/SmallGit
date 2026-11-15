import XCTest
@testable import SmallGit

/// The compare a submodule's file opens into.
///
/// Every part of a compare is repository-scoped — which file is read, which
/// commit the other side comes from, where a save is written — and the
/// submodule window's files belong to a repository the main window does not
/// have open. These pin the plumbing that carries that distinction.
@MainActor
final class SubmoduleCompareTests: XCTestCase {

    private struct Fixture {
        let app: AppState
        let git: GitService
        let runner: ProcessRunner
        let root: URL
        var superPath: String { root.appendingPathComponent("super").path }
        var submodulePath: String { root.appendingPathComponent("super/vendor/lib").path }
    }

    private func makeFixture() async throws -> Fixture {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-subcompare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func configure(_ path: String) async throws {
            _ = try await runner.run(in: path, args: ["config", "user.email", "t@x"])
            _ = try await runner.run(in: path, args: ["config", "user.name", "T"])
            _ = try await runner.run(in: path, args: ["config", "commit.gpgsign", "false"])
        }

        let lib = root.appendingPathComponent("lib").path
        try FileManager.default.createDirectory(atPath: lib, withIntermediateDirectories: true)
        _ = try await runner.run(in: lib, args: ["init", "-q", "-b", "main"])
        try await configure(lib)
        try "one\n".write(to: URL(fileURLWithPath: lib).appendingPathComponent("only-in-lib.txt"),
                          atomically: true, encoding: .utf8)
        _ = try await runner.run(in: lib, args: ["add", "-A"])
        _ = try await runner.run(in: lib, args: ["commit", "-q", "-m", "lib: first"])
        try "two\n".write(to: URL(fileURLWithPath: lib).appendingPathComponent("only-in-lib.txt"),
                          atomically: true, encoding: .utf8)
        _ = try await runner.run(in: lib, args: ["commit", "-qam", "lib: second"])

        let superPath = root.appendingPathComponent("super").path
        try FileManager.default.createDirectory(atPath: superPath, withIntermediateDirectories: true)
        _ = try await runner.run(in: superPath, args: ["init", "-q", "-b", "main"])
        try await configure(superPath)
        _ = try await runner.run(in: superPath, args: ["commit", "-q", "--allow-empty", "-m", "super: first"])
        let added = try await runner.run(in: superPath, args: [
            "-c", "protocol.file.allow=always",
            "submodule", "add", "-q", "--", lib, "vendor/lib"
        ])
        guard added.succeeded else { throw XCTSkip("submodule add unavailable: \(added.stderr)") }
        _ = try await runner.run(in: superPath, args: ["commit", "-q", "-m", "vendor lib"])

        let git = GitService(runner: runner)
        let app = makeIsolatedAppState(git: git)
        await app.addRepository(at: superPath)
        return Fixture(app: app, git: git, runner: runner, root: root)
    }

    func testACommitDiffCanBeAskedForAgainstTheSubmodule() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertEqual(f.app.activeRepo?.path, f.superPath, "the main window is on the parent")

        let log = try await f.git.log(repoPath: f.submodulePath, count: 5)
        let second = try XCTUnwrap(log.first { $0.subject == "lib: second" })

        // What the commit compare asks for. Without the repository
        // override this runs against the parent, where neither the commit
        // nor the file exists — an empty window with nothing to say.
        let scoped = await f.app.fileDiff(
            path: "only-in-lib.txt", atCommit: second.hash, repoPath: f.submodulePath
        )
        XCTAssertFalse(scoped.isEmpty)

        let unscoped = await f.app.fileDiff(path: "only-in-lib.txt", atCommit: second.hash)
        XCTAssertTrue(unscoped.isEmpty, "the parent has no such commit — which is the bug being avoided")
    }

    func testCompareWindowsAreKeyedPerRepository() {
        // The same path in a submodule and in its parent are different
        // files. Sharing a window id would make opening the second a no-op
        // that raises the first.
        let parent = CompareWindowPresenter.fileCompareID(path: "src/main.swift")
        let sub = CompareWindowPresenter.fileCompareID(
            path: "src/main.swift", repoPath: "/x/super/vendor/lib"
        )
        XCTAssertNotEqual(parent, sub)
    }

    func testSavingIntoASubmoduleWritesTheSubmodulesFile() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // The compare's save path resolves its repository the same way its
        // load does, so a file written from the submodule window lands in
        // the submodule — not at the same relative path under the parent.
        let target = URL(fileURLWithPath: f.submodulePath).appendingPathComponent("only-in-lib.txt")
        try "edited by compare\n".write(to: target, atomically: true, encoding: .utf8)

        let subStatus = try await f.git.status(repoPath: f.submodulePath)
        XCTAssertEqual(subStatus.map(\.path), ["only-in-lib.txt"])

        let parentStatus = try await f.git.status(repoPath: f.superPath)
        XCTAssertEqual(parentStatus.map(\.path), ["vendor/lib"],
                       "the parent sees a dirty submodule, not a file of its own")
    }
}
