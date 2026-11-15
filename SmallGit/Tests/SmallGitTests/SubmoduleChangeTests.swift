import XCTest
@testable import SmallGit

/// A moved submodule pointer, read back as commits.
///
/// Against real repositories, because the thing being tested is a question
/// asked of two repositories at once — the parent's index and the
/// submodule's own log — and neither half is interesting alone.
final class SubmoduleChangeTests: XCTestCase {

    private struct Fixture {
        let git: GitService
        let runner: ProcessRunner
        let root: URL
        var superPath: String { root.appendingPathComponent("super").path }
        var submodulePath: String { root.appendingPathComponent("super/vendor/lib").path }
    }

    /// A superproject with one submodule, both real, wired with a local
    /// path — which git only allows for submodules when asked, hence the
    /// `-c protocol.file.allow=always` on every command that clones one.
    private func makeFixture() async throws -> Fixture {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-submodule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func configure(_ path: String) async throws {
            _ = try await runner.run(in: path, args: ["config", "user.email", "t@x"])
            _ = try await runner.run(in: path, args: ["config", "user.name", "T"])
            _ = try await runner.run(in: path, args: ["config", "commit.gpgsign", "false"])
        }

        // The library the superproject will vendor: two commits, so the
        // pointer has somewhere to move.
        let lib = root.appendingPathComponent("lib").path
        try FileManager.default.createDirectory(atPath: lib, withIntermediateDirectories: true)
        _ = try await runner.run(in: lib, args: ["init", "-q", "-b", "main"])
        try await configure(lib)
        _ = try await runner.run(in: lib, args: ["commit", "-q", "--allow-empty", "-m", "lib: first"])

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

        return Fixture(git: GitService(runner: runner), runner: runner, root: root)
    }

    // MARK: - Moved pointer

    func testCommitsBehindAMovedPointer() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // Two commits inside the submodule that the parent has not pinned.
        for subject in ["lib: retry helper", "lib: and a second"] {
            _ = try await f.runner.run(in: f.submodulePath, args: ["commit", "-q", "--allow-empty", "-m", subject])
        }

        let loaded = await f.git.submoduleChange(repoPath: f.superPath, path: "vendor/lib")
        let change = try XCTUnwrap(loaded)
        XCTAssertFalse(change.pointerIsUnchanged)
        XCTAssertEqual(change.added.map(\.subject), ["lib: and a second", "lib: retry helper"],
                       "newest first, like every other log in the app")
        XCTAssertTrue(change.removed.isEmpty)
        XCTAssertEqual(change.summary, "2 ahead")

        // Both ends as commits, not just SHAs: the panel shows them side by
        // side with author and date, which is what a pointer move *is*.
        XCTAssertEqual(change.recordedCommit?.subject, "lib: first")
        XCTAssertEqual(change.currentCommit?.subject, "lib: and a second")
        XCTAssertEqual(change.recordedCommit?.hash, change.recorded)
        XCTAssertEqual(change.currentCommit?.hash, change.current)
    }

    func testInitialsForTheCommitCards() {
        XCTAssertEqual(SubmoduleCommitCards.initials(of: "Test Author"), "TA")
        XCTAssertEqual(SubmoduleCommitCards.initials(of: "prince"), "P")
        XCTAssertEqual(SubmoduleCommitCards.initials(of: "a.b.c"), "AB")
        XCTAssertEqual(SubmoduleCommitCards.initials(of: ""), "?")
    }

    func testPointerMovedBackwards() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        _ = try await f.runner.run(in: f.submodulePath, args: ["commit", "-q", "--allow-empty", "-m", "lib: newer"])
        _ = try await f.runner.run(in: f.superPath, args: ["add", "vendor/lib"])
        // Now walk the checkout back: the parent records the newer commit,
        // so the commit shows as one the pointer would *drop*.
        _ = try await f.runner.run(in: f.submodulePath, args: ["checkout", "-q", "HEAD~1"])

        let loaded = await f.git.submoduleChange(repoPath: f.superPath, path: "vendor/lib")
        let change = try XCTUnwrap(loaded)
        XCTAssertTrue(change.added.isEmpty)
        XCTAssertEqual(change.removed.map(\.subject), ["lib: newer"])
        XCTAssertEqual(change.summary, "1 behind")
    }

    // MARK: - Not a pointer move

    func testDirtyCheckoutIsNotAPointerMove() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // The distinction `XY` alone cannot make: this arrives as `.M` in
        // the parent's status exactly like a moved pointer does.
        try "scratch\n".write(
            to: URL(fileURLWithPath: f.submodulePath).appendingPathComponent("untracked.txt"),
            atomically: true, encoding: .utf8
        )

        let loaded = await f.git.submoduleChange(repoPath: f.superPath, path: "vendor/lib")
        let change = try XCTUnwrap(loaded)
        XCTAssertTrue(change.pointerIsUnchanged)
        XCTAssertTrue(change.hasUntrackedContent)
        XCTAssertTrue(change.added.isEmpty)
        XCTAssertEqual(change.summary, "Uncommitted changes inside")
        // Named, not just counted: "something is dirty in there" is not
        // actionable, "untracked.txt is" is.
        XCTAssertEqual(change.dirtyFiles.map(\.path), ["untracked.txt"])
    }

    func testAnOrdinaryPathIsNotASubmodule() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // `.gitmodules` is a tracked file, not a gitlink: asking for its
        // submodule change has to come back empty-handed rather than
        // inventing one.
        let change = await f.git.submoduleChange(repoPath: f.superPath, path: ".gitmodules")
        XCTAssertNil(change?.current)
    }

    // MARK: - Status parsing

    func testStatusTellsAMovedPointerFromADirtyCheckout() {
        // Both are `.M` in XY; only the third field separates them, and it
        // is the field the parser used to drop.
        let moved = GitOutputParser.parseStatus(
            "1 .M SC.. 160000 160000 160000 7c80a64 7c80a64 vendor/network"
        )
        XCTAssertEqual(moved.first?.submodule?.commitChanged, true)
        XCTAssertEqual(moved.first?.submodule?.modifiedContent, false)
        XCTAssertEqual(moved.first?.submodule?.label, "Submodule moved")

        let dirty = GitOutputParser.parseStatus(
            "1 .M S.M. 160000 160000 160000 bbe0699 bbe0699 vendor/parser"
        )
        XCTAssertEqual(dirty.first?.submodule?.commitChanged, false)
        XCTAssertEqual(dirty.first?.submodule?.modifiedContent, true)
        XCTAssertEqual(dirty.first?.submodule?.label, "Submodule dirty")

        // An ordinary file carries `N...`, which is not a submodule at all.
        let file = GitOutputParser.parseStatus(
            "1 .M N... 100644 100644 100644 abc123 abc123 src/main.swift"
        )
        XCTAssertNil(file.first?.submodule)
        XCTAssertFalse(file.first?.isSubmodule ?? true)
    }

    func testCachedRowsWithoutTheSubmoduleKeyStillDecode() throws {
        // Written by a build before the field existed; a strict decode
        // would throw the whole cached file status away.
        let json = #"{"path":"a.swift","indexStatus":".","workTreeStatus":"M","isConflict":false,"isAssumeUnchanged":false}"#
        let decoded = try JSONDecoder().decode(GitFileStatus.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.path, "a.swift")
        XCTAssertNil(decoded.submodule)
    }
}
