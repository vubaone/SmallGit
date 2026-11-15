import XCTest
@testable import SmallGit

/// The Submodule window's own repository context.
///
/// Its whole reason for existing is separation: the session commits to the
/// submodule, from its own window, while the main window's repository is
/// untouched. Both halves are checked here against real repositories.
@MainActor
final class SubmoduleSessionTests: XCTestCase {

    private struct Fixture {
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
            .appendingPathComponent("smallgit-session-\(UUID().uuidString)", isDirectory: true)
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
        try "one\n".write(to: URL(fileURLWithPath: lib).appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        _ = try await runner.run(in: lib, args: ["add", "-A"])
        _ = try await runner.run(in: lib, args: ["commit", "-q", "-m", "lib: first"])

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
        try await configure(root.appendingPathComponent("super/vendor/lib").path)

        return Fixture(git: GitService(runner: runner), runner: runner, root: root)
    }

    private func session(_ f: Fixture) -> SubmoduleSession {
        SubmoduleSession(parentPath: f.superPath, path: "vendor/lib", git: f.git, output: OutputLog())
    }

    func testItShowsTheSubmodulesOwnLogAndDirtyFiles() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try "edited\n".write(to: URL(fileURLWithPath: f.submodulePath).appendingPathComponent("a.txt"),
                             atomically: true, encoding: .utf8)

        let s = session(f)
        await s.load()
        XCTAssertEqual(s.commits.map(\.subject), ["lib: first"], "the submodule's history, not the parent's")
        // Through a real JournalViewModel, so the window draws the same
        // graph as the main one rather than a flat list beside it.
        XCTAssertNotNil(
            s.journal.graphRow(for: try XCTUnwrap(s.commits.first)),
            "every commit has a lane to draw in"
        )
        XCTAssertGreaterThanOrEqual(s.journal.graphLayout.maxLanes, 1)
        XCTAssertEqual(s.files.map(\.path), ["a.txt"])
        XCTAssertEqual(s.staged, ["a.txt"], "ticked to start with")
        XCTAssertTrue(s.isRecorded(try XCTUnwrap(s.commits.first)))
        XCTAssertFalse(s.parentIsBehind)
    }

    func testCommittingHappensInTheSubmoduleAndLeavesTheParentToRecordIt() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try "edited\n".write(to: URL(fileURLWithPath: f.submodulePath).appendingPathComponent("a.txt"),
                             atomically: true, encoding: .utf8)

        let s = session(f)
        await s.load()
        s.message = "lib: edit a"
        XCTAssertTrue(s.canCommit)
        await s.commit()

        XCTAssertEqual(s.commits.first?.subject, "lib: edit a")
        XCTAssertTrue(s.files.isEmpty)
        XCTAssertEqual(s.message, "")
        XCTAssertTrue(s.parentIsBehind, "the parent still records the old commit — that is correct, and the cue")

        // The parent has one changed path and it is the submodule itself:
        // nothing here reached into the parent's own files.
        let parentStatus = try await f.git.status(repoPath: f.superPath)
        XCTAssertEqual(parentStatus.map(\.path), ["vendor/lib"])
        XCTAssertEqual(parentStatus.first?.submodule?.commitChanged, true)
    }

    func testUntickedFilesAreLeftBehind() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sub = URL(fileURLWithPath: f.submodulePath)
        try "edited\n".write(to: sub.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: sub.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let s = session(f)
        await s.load()
        s.toggle(try XCTUnwrap(s.files.first { $0.path == "b.txt" }))
        s.message = "lib: only a"
        await s.commit()

        XCTAssertEqual(s.commits.first?.subject, "lib: only a")
        XCTAssertEqual(s.files.map(\.path), ["b.txt"], "still waiting, still unticked")
    }

    func testRecordingStagesInTheParentWithoutCommittingThere() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try "edited\n".write(to: URL(fileURLWithPath: f.submodulePath).appendingPathComponent("a.txt"),
                             atomically: true, encoding: .utf8)

        let s = session(f)
        await s.load()
        s.message = "lib: edit a"
        await s.commit()
        await s.recordInParent()

        let parentStatus = try await f.git.status(repoPath: f.superPath)
        let row = try XCTUnwrap(parentStatus.first { $0.path == "vendor/lib" })
        XCTAssertTrue(row.isStaged)
        XCTAssertFalse(s.parentIsBehind)
        let parentLog = try await f.git.log(repoPath: f.superPath, count: 5)
        XCTAssertEqual(parentLog.first?.subject, "vendor lib", "the parent's commit stays the user's to make")
    }

    func testTheDiffPaneIsPointedAtTheSubmodule() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try "edited\n".write(to: URL(fileURLWithPath: f.submodulePath).appendingPathComponent("a.txt"),
                             atomically: true, encoding: .utf8)

        let s = session(f)
        await s.load()
        await s.showDiff(for: try XCTUnwrap(s.files.first))
        // A diff loaded through the main window's cache would have come
        // back empty here: the parent has no `a.txt`.
        XCTAssertFalse(s.diffVM.hunks.isEmpty, "the session's own cache points at the submodule")
    }

    func testTheShownFileIsMarkedUntilTheSelectionMovesOn() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try "edited\n".write(to: URL(fileURLWithPath: f.submodulePath).appendingPathComponent("a.txt"),
                             atomically: true, encoding: .utf8)

        let s = session(f)
        await s.load()
        XCTAssertNil(s.shownFile, "nothing has been picked out to read yet")

        let file = try XCTUnwrap(s.files.first)
        await s.showDiff(for: file)
        XCTAssertEqual(s.shownFile, file.path, "the Files list marks the row the pane is answering")

        // Moving to a commit puts a whole commit in the pane below, so no
        // single file is the one being read any more — and a row left marked
        // would be pointing at a diff that is no longer on screen.
        s.selection = .commit(try XCTUnwrap(s.commits.first))
        await s.loadSelection()
        XCTAssertNil(s.shownFile)
    }
}
