import XCTest
@testable import SmallGit

/// End-to-end against a real `git`: setting the flag, reading back which
/// paths carry it, and the disappearing act that makes the Files panel
/// need a view for it in the first place.
final class AssumeUnchangedIntegrationTests: XCTestCase {

    private func makeRepo() async throws -> (GitService, ProcessRunner, URL) {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-assume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])

        for name in ["config.yml", "README.md"] {
            try "seed\n".write(
                to: root.appendingPathComponent(name),
                atomically: true, encoding: .utf8
            )
        }
        // A path with a space, since the flag list comes back NUL-separated
        // precisely so this survives.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("some dir", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "seed\n".write(
            to: root.appendingPathComponent("some dir/local settings.json"),
            atomically: true, encoding: .utf8
        )
        _ = try await runner.run(in: repo, args: ["add", "-A"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "seed"])

        return (GitService(runner: runner), runner, root)
    }

    func testFlagRoundTrips() async throws {
        let (git, _, root) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.path

        let before = try await git.assumeUnchangedFiles(repoPath: repo)
        XCTAssertTrue(before.isEmpty, "a fresh repo flags nothing")

        let flagged = ["config.yml", "some dir/local settings.json"]
        let set = try await git.setAssumeUnchanged(repoPath: repo, paths: flagged, on: true)
        XCTAssertTrue(set.succeeded, set.stderr)

        let listed = try await git.assumeUnchangedFiles(repoPath: repo)
        XCTAssertEqual(Set(listed), Set(flagged),
                       "both paths come back, the one with a space included")

        let cleared = try await git.setAssumeUnchanged(
            repoPath: repo, paths: ["config.yml"], on: false
        )
        XCTAssertTrue(cleared.succeeded, cleared.stderr)
        let remaining = try await git.assumeUnchangedFiles(repoPath: repo)
        XCTAssertEqual(remaining, ["some dir/local settings.json"],
                       "clearing one flag leaves the other")
    }

    /// The reason the panel needs a separate list: an edit to a flagged
    /// file is invisible to status, so the row cannot come from there.
    func testAnEditToAFlaggedFileIsInvisibleToStatus() async throws {
        let (git, _, root) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.path

        _ = try await git.setAssumeUnchanged(repoPath: repo, paths: ["config.yml"], on: true)
        try "locally changed\n".write(
            to: root.appendingPathComponent("config.yml"),
            atomically: true, encoding: .utf8
        )

        let status = try await git.status(repoPath: repo)
        XCTAssertFalse(status.map(\.path).contains("config.yml"),
                       "git was told to stop looking — got \(status.map(\.path))")
        let listed = try await git.assumeUnchangedFiles(repoPath: repo)
        XCTAssertEqual(listed, ["config.yml"],
                       "…and the flag list is the only place it shows up")

        // Clearing the flag hands the edit back to status.
        _ = try await git.setAssumeUnchanged(repoPath: repo, paths: ["config.yml"], on: false)
        let after = try await git.status(repoPath: repo)
        XCTAssertTrue(after.contains { $0.path == "config.yml" && $0.state == .modified })
    }

    /// `update-index` fails the whole invocation over one untracked path,
    /// which is why `AppState.setAssumeUnchanged` drops them and the
    /// context-menu item switches off for a selection containing one.
    func testAnUntrackedPathFailsTheWholeInvocation() async throws {
        let (git, _, root) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.path

        try "new\n".write(
            to: root.appendingPathComponent("scratch.txt"),
            atomically: true, encoding: .utf8
        )
        let result = try await git.setAssumeUnchanged(
            repoPath: repo, paths: ["config.yml", "scratch.txt"], on: true
        )
        XCTAssertFalse(result.succeeded)
        let listed = try await git.assumeUnchangedFiles(repoPath: repo)
        XCTAssertTrue(listed.isEmpty,
                      "the tracked path in the same call was not flagged either")
    }

    /// The sidebar tree's two folder commands: an untracked folder excluded
    /// through `info/exclude` goes quiet without `.gitignore` changing, and
    /// a tracked folder's flag lands on the files inside it.
    func testAFolderCanBeExcludedLocallyOrFlagged() async throws {
        let (git, _, root) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.path

        let notes = root.appendingPathComponent(".notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "mine\n".write(to: notes.appendingPathComponent("todo.md"), atomically: true, encoding: .utf8)
        let pattern = GitService.ignorePattern(forRelativePath: ".notes", isDirectory: true)
        XCTAssertEqual(pattern, "/.notes/")

        let added = try await git.addToLocalExclude(repoPath: repo, patterns: [pattern])
        XCTAssertEqual(added, [pattern])
        let again = try await git.addToLocalExclude(repoPath: repo, patterns: [pattern])
        XCTAssertEqual(again, [], "not written twice")
        let status = try await git.status(repoPath: repo)
        XCTAssertFalse(status.contains { $0.path.hasPrefix(".notes") }, "\(status.map(\.path))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitignore").path))

        let inside = try await git.trackedFiles(repoPath: repo, under: "some dir")
        XCTAssertEqual(inside, ["some dir/local settings.json"])
        let flagged = try await git.setAssumeUnchanged(repoPath: repo, paths: inside, on: true)
        XCTAssertTrue(flagged.succeeded, flagged.stderr)
        let listed = try await git.assumeUnchangedFiles(repoPath: repo)
        XCTAssertEqual(listed, inside)
    }
}
