import XCTest
@testable import SmallGit

/// Drives real `git submodule` against real repositories.
///
/// The parser tests pin down the formats; this checks those formats are the
/// ones git actually emits, and that the operations do what the UI promises.
final class SubmoduleIntegrationTests: XCTestCase {

    private var root: URL!
    private var parent: URL!
    private var child: URL!
    private let git = GitService.shared

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                          "git not available")
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Submodule-\(UUID().uuidString)")
        parent = root.appendingPathComponent("parent")
        child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try makeRepositories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func run(_ args: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        // `git submodule add` refuses a local path unless this is set, and
        // these fixtures are all local clones.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_ALLOW_PROTOCOL"] = "file:local"
        process.environment = environment
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func makeRepositories() throws {
        for repo in [parent!, child!] {
            try run(["init", "-q", "-b", "main", "."], in: repo)
            try run(["config", "user.email", "t@t"], in: repo)
            try run(["config", "user.name", "t"], in: repo)
        }
        try "child\n".write(to: child.appendingPathComponent("lib.txt"),
                            atomically: true, encoding: .utf8)
        try run(["add", "-A"], in: child)
        try run(["commit", "-qm", "child base"], in: child)

        try "parent\n".write(to: parent.appendingPathComponent("app.txt"),
                             atomically: true, encoding: .utf8)
        try run(["add", "-A"], in: parent)
        try run(["commit", "-qm", "parent base"], in: parent)

        try run(["-c", "protocol.file.allow=always",
                 "submodule", "add", "--", child.path, "vendor/lib"], in: parent)
        try run(["commit", "-qm", "add submodule"], in: parent)
    }

    // MARK: - Reading

    /// The end-to-end shape the sidebar renders.
    func testARealSubmoduleIsListedWithItsURLAndState() async throws {
        let submodules = await git.submodules(repoPath: parent.path)

        XCTAssertEqual(submodules.count, 1)
        let module = try XCTUnwrap(submodules.first)
        XCTAssertEqual(module.path, "vendor/lib")
        XCTAssertEqual(module.url, child.path, "the URL comes from .gitmodules")
        XCTAssertEqual(module.state, .current)
        XCTAssertFalse(module.sha.isEmpty)
        XCTAssertTrue(module.isCloned)
    }

    /// Nearly every repository has none, and that must not read as an error.
    func testARepositoryWithNoSubmodulesListsNothing() async throws {
        let submodules = await git.submodules(repoPath: child.path)
        XCTAssertTrue(submodules.isEmpty)
    }

    /// The state the sidebar has to call out: cloned but sitting somewhere
    /// other than the commit the parent records.
    func testMovingTheCheckoutReportsItAsModified() async throws {
        let sub = parent.appendingPathComponent("vendor/lib")
        try "changed\n".write(to: sub.appendingPathComponent("lib.txt"),
                              atomically: true, encoding: .utf8)
        try run(["commit", "-qam", "move the submodule"], in: sub)

        let listed = await git.submodules(repoPath: parent.path)
        let module = try XCTUnwrap(listed.first)
        XCTAssertEqual(module.state, .modified)
    }

    // MARK: - Operations

    /// The clone-then-init round trip, which is what a fresh checkout needs.
    func testDeinitEmptiesTheCheckoutAndUpdateRestoresIt() async throws {
        let deinitResult = try await git.deinitSubmodule(
            repoPath: parent.path, path: "vendor/lib", force: true
        )
        XCTAssertTrue(deinitResult.succeeded)

        var listed = await git.submodules(repoPath: parent.path)
        var module = try XCTUnwrap(listed.first)
        XCTAssertEqual(module.state, .uninitialized)
        XCTAssertFalse(module.isCloned, "nothing to open while it is empty")

        let updateResult = try await git.updateSubmodules(repoPath: parent.path)
        XCTAssertTrue(updateResult.succeeded)

        listed = await git.submodules(repoPath: parent.path)
        module = try XCTUnwrap(listed.first)
        XCTAssertEqual(module.state, .current)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: parent.appendingPathComponent("vendor/lib/lib.txt").path
        ), "update --init must produce a real checkout, not just registration")
    }

    func testSyncSucceedsOnARealRepository() async throws {
        let result = try await git.syncSubmodules(repoPath: parent.path)
        XCTAssertTrue(result.succeeded)
    }

    /// The submodule's own directory is a repository in its own right, which
    /// is what "Open as Repository" relies on.
    func testTheSubmoduleDirectoryIsItsOwnRepository() async throws {
        let listed = await git.submodules(repoPath: parent.path)
        let module = try XCTUnwrap(listed.first)
        let path = module.absolutePath(in: parent.path)

        let isRepository = await git.isRepository(at: path)
        XCTAssertTrue(isRepository)
        let branch = try? await git.currentBranch(repoPath: path)
        XCTAssertEqual(branch, "main")
    }
}
