import XCTest
@testable import SmallGit

final class StashTests: XCTestCase {

    // MARK: - parser unit tests

    func testParseStashListEmpty() {
        XCTAssertEqual(GitOutputParser.parseStashList("").count, 0)
        XCTAssertEqual(GitOutputParser.parseStashList("\n\n").count, 0)
    }

    func testParseStashListMultipleEntries() {
        // Format we ship to git stash list: %gd\0%gs\0%aI
        let nul = "\u{0}"
        let lines = [
            "stash@{0}\(nul)On main: experimental\(nul)2026-05-17T10:00:00Z",
            "stash@{1}\(nul)WIP on feature/login: refactor\(nul)2026-05-15T08:30:00Z"
        ].joined(separator: "\n")
        let stashes = GitOutputParser.parseStashList(lines)
        XCTAssertEqual(stashes.count, 2)
        XCTAssertEqual(stashes[0].index, 0)
        XCTAssertEqual(stashes[0].message, "On main: experimental")
        XCTAssertEqual(stashes[0].branch, "main")
        XCTAssertEqual(stashes[1].index, 1)
        XCTAssertEqual(stashes[1].branch, "feature/login")
        XCTAssertNotNil(stashes[0].date)
    }

    func testParseStashListTolerantOfMissingDate() {
        let nul = "\u{0}"
        let line = "stash@{0}\(nul)On dev: hack"
        let stashes = GitOutputParser.parseStashList(line)
        XCTAssertEqual(stashes.count, 1)
        XCTAssertEqual(stashes[0].message, "On dev: hack")
        XCTAssertEqual(stashes[0].branch, "dev")
        XCTAssertNil(stashes[0].date)
    }

    // MARK: - integration: real git stash save → list → drop

    func testStashSaveListDropAgainstRealGit() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-stashtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])

        let file = tmp.appendingPathComponent("a.txt")
        try "alpha\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "a.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])

        // Make a dirty change and stash it.
        try "alpha-modified\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git.stashSave(repoPath: repo, message: "experimental")

        // Should have exactly one stash entry, indexed 0.
        let listed = try await git.stashList(repoPath: repo)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].index, 0)
        XCTAssertTrue(listed[0].message.contains("experimental"))

        // Drop it and verify the list is empty.
        _ = try await git.stashDrop(repoPath: repo, index: 0)
        let afterDrop = try await git.stashList(repoPath: repo)
        XCTAssertTrue(afterDrop.isEmpty, "expected stash list to be empty after drop, got \(afterDrop)")
    }

    // MARK: - integration: partial stash (pathspec-limited)

    func testPartialStashLeavesOtherChangesInWorkingTree() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-partialstash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])

        let fileA = tmp.appendingPathComponent("a.txt")
        let fileB = tmp.appendingPathComponent("b.txt")
        try "alpha\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "beta\n".write(to: fileB, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "."])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])

        // Dirty both files, stash only a.txt.
        try "alpha-2\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "beta-2\n".write(to: fileB, atomically: true, encoding: .utf8)
        let r = try await git.stashSave(repoPath: repo, message: "only a", paths: ["a.txt"])
        XCTAssertTrue(r.succeeded, r.stderr)

        // a.txt is clean again; b.txt keeps its change.
        let status = try await git.status(repoPath: repo)
        XCTAssertFalse(status.contains { $0.path == "a.txt" },
                       "a.txt should have been stashed away")
        XCTAssertTrue(status.contains { $0.path == "b.txt" },
                      "b.txt must stay dirty in the working tree")

        let listed = try await git.stashList(repoPath: repo)
        XCTAssertEqual(listed.count, 1)
    }

    // MARK: - integration: --keep-index

    func testKeepIndexStashLeavesStagedChangesStaged() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-keepindex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])

        let fileA = tmp.appendingPathComponent("a.txt")
        let fileB = tmp.appendingPathComponent("b.txt")
        try "alpha\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "beta\n".write(to: fileB, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "."])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])

        // Stage a change to a.txt; leave b.txt's change unstaged.
        try "alpha-2\n".write(to: fileA, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "a.txt"])
        try "beta-2\n".write(to: fileB, atomically: true, encoding: .utf8)

        let r = try await git.stashSave(repoPath: repo, keepIndex: true)
        XCTAssertTrue(r.succeeded, r.stderr)

        // The staged a.txt change must still be staged; b.txt's unstaged
        // change went into the stash.
        let status = try await git.status(repoPath: repo)
        let a = status.first { $0.path == "a.txt" }
        XCTAssertNotNil(a, "a.txt's staged change must survive --keep-index")
        XCTAssertFalse(status.contains { $0.path == "b.txt" },
                       "b.txt's unstaged change should be in the stash")
    }

    // MARK: - integration: snapshot (stash create + stash store)

    /// A repo with one commit of a.txt and b.txt, and git configured enough
    /// to commit. The caller removes `tmp`.
    private func makeSnapshotRepo(_ label: String) async throws -> (
        runner: ProcessRunner, git: GitService, tmp: URL
    ) {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let repo = tmp.path
        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        try "alpha\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "beta\n".write(to: tmp.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "."])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])
        return (runner, git, tmp)
    }

    /// The whole point of a snapshot: the entry is recorded and nothing in
    /// the working tree moves. The restore half proves the entry is a real
    /// stash and not just a commit parked in the reflog — down to which
    /// change was staged and which was not.
    func testSnapshotRecordsStashAndLeavesWorkingTreeAlone() async throws {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let (r, git, tmp) = try await makeSnapshotRepo("snapshot")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        // a.txt's change is staged, b.txt's is not.
        try "alpha-2\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await r.run(in: repo, args: ["add", "a.txt"])
        try "beta-2\n".write(to: tmp.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let before = try await git.status(repoPath: repo)

        let result = try await git.stashSnapshot(repoPath: repo, message: "checkpoint")
        XCTAssertTrue(result.succeeded, result.combinedOutput)

        let after = try await git.status(repoPath: repo)
        XCTAssertEqual(after, before,
                       "a snapshot must leave the working tree exactly as it was")
        XCTAssertEqual(
            try String(contentsOf: tmp.appendingPathComponent("a.txt"), encoding: .utf8), "alpha-2\n")
        XCTAssertEqual(
            try String(contentsOf: tmp.appendingPathComponent("b.txt"), encoding: .utf8), "beta-2\n")

        let listed = try await git.stashList(repoPath: repo)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.message, "On main: checkpoint")
        XCTAssertEqual(listed.first?.branch, "main")

        // Throw the working tree away and rebuild it from the entry.
        _ = try await r.run(in: repo, args: ["reset", "-q", "--hard"])
        let applied = try await r.run(in: repo, args: ["stash", "apply", "--index"])
        XCTAssertTrue(applied.succeeded, applied.combinedOutput)
        let restored = try await git.status(repoPath: repo)
        XCTAssertEqual(restored, before,
                       "the entry must carry the staged/unstaged split back")
    }

    /// `git stash create` ignores untracked files entirely, so the entry's
    /// third parent is built by hand. It must hold the untracked file — and
    /// the file must still be on disk afterwards.
    func testSnapshotIncludesUntrackedWithoutRemovingThem() async throws {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let (r, git, tmp) = try await makeSnapshotRepo("snapshot-untracked")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        try "alpha-2\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let newFile = tmp.appendingPathComponent("new note.txt")   // space: NUL-separated paths
        try "fresh\n".write(to: newFile, atomically: true, encoding: .utf8)
        let before = try await git.status(repoPath: repo)

        let result = try await git.stashSnapshot(
            repoPath: repo, message: "with untracked", includeUntracked: true
        )
        XCTAssertTrue(result.succeeded, result.combinedOutput)
        let after = try await git.status(repoPath: repo)
        XCTAssertEqual(after, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path),
                      "an untracked file must not be swept out of the working tree")

        let files = try await git.stashFiles(repoPath: repo, index: 0)
        XCTAssertTrue(files.contains { $0.path == "a.txt" && !$0.wasUntracked })
        XCTAssertTrue(files.contains { $0.path == "new note.txt" && $0.wasUntracked },
                      "the untracked file belongs in the entry's third parent")

        // And it restores: clear the tree the snapshot left in place — the
        // apply has to find room for both files — then apply.
        _ = try await r.run(in: repo, args: ["reset", "-q", "--hard"])
        try FileManager.default.removeItem(at: newFile)
        let applied = try await r.run(in: repo, args: ["stash", "apply"])
        XCTAssertTrue(applied.succeeded, applied.combinedOutput)
        XCTAssertEqual(try String(contentsOf: newFile, encoding: .utf8), "fresh\n")
        XCTAssertEqual(
            try String(contentsOf: tmp.appendingPathComponent("a.txt"), encoding: .utf8), "alpha-2\n")
    }

    /// With nothing but untracked changes `git stash create` prints nothing
    /// at all — by its reckoning there is nothing to stash — so the entry has
    /// to be assembled from HEAD instead.
    func testSnapshotOfUntrackedOnlyChanges() async throws {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let (r, git, tmp) = try await makeSnapshotRepo("snapshot-only-untracked")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        let newFile = tmp.appendingPathComponent("c.txt")
        try "gamma\n".write(to: newFile, atomically: true, encoding: .utf8)

        let result = try await git.stashSnapshot(repoPath: repo, includeUntracked: true)
        XCTAssertTrue(result.succeeded, result.combinedOutput)
        let listed = try await git.stashList(repoPath: repo)
        XCTAssertEqual(listed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path))

        let files = try await git.stashFiles(repoPath: repo, index: 0)
        XCTAssertEqual(files.map(\.path), ["c.txt"])

        try FileManager.default.removeItem(at: newFile)
        let applied = try await r.run(in: repo, args: ["stash", "apply"])
        XCTAssertTrue(applied.succeeded, applied.combinedOutput)
        XCTAssertEqual(try String(contentsOf: newFile, encoding: .utf8), "gamma\n")
    }

    /// A clean tree has nothing to snapshot, and says so instead of storing
    /// an empty entry.
    func testSnapshotOfCleanTreeSavesNothing() async throws {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let (_, git, tmp) = try await makeSnapshotRepo("snapshot-clean")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await git.stashSnapshot(repoPath: tmp.path, includeUntracked: true)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.combinedOutput.contains("No local changes to save"),
                      result.combinedOutput)
        let listed = try await git.stashList(repoPath: tmp.path)
        XCTAssertTrue(listed.isEmpty, "nothing should have been stored")
    }

    // MARK: - integration: rename

    /// A renamed stash stays at its index, keeps its branch prefix and its
    /// commit, and the entries around it are untouched.
    func testRenameKeepsStashInPlace() async throws {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let (_, git, tmp) = try await makeSnapshotRepo("stashrename")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path
        let file = tmp.appendingPathComponent("a.txt")

        for n in 1...3 {
            try "alpha-\(n)\n".write(to: file, atomically: true, encoding: .utf8)
            if n == 2 {
                _ = try await git.stashSave(repoPath: repo)  // "WIP on main: …"
            } else {
                _ = try await git.stashSave(repoPath: repo, message: "s\(n)")
            }
        }
        let shaBefore = try await runner.run(in: repo, args: ["rev-parse", "stash@{1}"]).stdout

        let r = try await git.stashRename(repoPath: repo, index: 1, message: "renamed")
        XCTAssertTrue(r.succeeded, r.stderr)

        let listed = try await git.stashList(repoPath: repo).map(\.message)
        XCTAssertEqual(listed, ["On main: s3", "On main: renamed", "On main: s1"])
        let shaAfter = try await runner.run(in: repo, args: ["rev-parse", "stash@{1}"]).stdout
        XCTAssertEqual(shaAfter, shaBefore)
    }
}
