import XCTest
@testable import SmallGit

final class StashDiffIntegrationTests: XCTestCase {

    func testStashDiffReturnsHunksForStashedChanges() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-stashdiff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        let fileA = tmp.appendingPathComponent("a.txt")
        let fileB = tmp.appendingPathComponent("b.txt")
        try "alpha\nbravo\ncharlie\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "one\ntwo\nthree\n".write(to: fileB, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "."])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])

        // Modify both files, stash them.
        try "alpha\nBRAVO-MOD\ncharlie\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "one\nTWO-MOD\nthree\n".write(to: fileB, atomically: true, encoding: .utf8)
        _ = try await git.stashSave(repoPath: repo, message: "multi-file")

        let hunks = try await git.stashDiff(repoPath: repo, index: 0)
        // Two files modified, one hunk per file → 2 hunks total.
        XCTAssertEqual(hunks.count, 2, "expected one hunk per modified file")

        let allContent = hunks.flatMap(\.lines).map(\.content)
        XCTAssertTrue(allContent.contains("BRAVO-MOD"), "missing change from a.txt; got: \(allContent)")
        XCTAssertTrue(allContent.contains("TWO-MOD"),   "missing change from b.txt; got: \(allContent)")

        // Each hunk knows which file it came from — that is what lets the
        // Stash window narrow the pane to one row of its list.
        XCTAssertEqual(Set(hunks.compactMap(\.file)), ["a.txt", "b.txt"])

        let onlyA = try await git.stashDiff(repoPath: repo, index: 0, path: "a.txt")
        XCTAssertEqual(onlyA.count, 1)
        XCTAssertTrue(onlyA.flatMap(\.lines).map(\.content).contains("BRAVO-MOD"))
        XCTAssertFalse(onlyA.flatMap(\.lines).map(\.content).contains("TWO-MOD"))

        let files = try await git.stashFiles(repoPath: repo, index: 0)
        XCTAssertEqual(files.map(\.path).sorted(), ["a.txt", "b.txt"])
        XCTAssertEqual(files.map(\.status.state), [.modified, .modified])
        // Nothing untracked went in, so every row points at the entry itself.
        XCTAssertTrue(files.allSatisfy { !$0.wasUntracked })
    }

    /// `git stash push -u` keeps the untracked files it swept up in a third
    /// parent of the entry rather than in the entry. They belong in the
    /// list and in the diff all the same — a stash that reads as empty
    /// because everything in it was new is the bug this covers.
    func testStashFilesAndDiffIncludeUntrackedFiles() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-stashuntracked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        let tracked = tmp.appendingPathComponent("tracked.txt")
        try "one\ntwo\n".write(to: tracked, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "."])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])

        try "one\nTWO-MOD\n".write(to: tracked, atomically: true, encoding: .utf8)
        try "brand new\n".write(
            to: tmp.appendingPathComponent("fresh.txt"), atomically: true, encoding: .utf8
        )
        _ = try await git.stashSave(repoPath: repo, message: "with untracked", includeUntracked: true)

        let files = try await git.stashFiles(repoPath: repo, index: 0)
        XCTAssertEqual(files.map(\.path).sorted(), ["fresh.txt", "tracked.txt"])
        let fresh = try XCTUnwrap(files.first { $0.path == "fresh.txt" })
        XCTAssertTrue(fresh.wasUntracked, "untracked files live in the entry's third parent")
        XCTAssertEqual(fresh.status.state, .added)

        let hunks = try await git.stashDiff(repoPath: repo, index: 0)
        XCTAssertEqual(Set(hunks.compactMap(\.file)), ["tracked.txt", "fresh.txt"])

        let onlyFresh = try await git.stashDiff(repoPath: repo, index: 0, path: "fresh.txt")
        XCTAssertEqual(onlyFresh.flatMap(\.lines).map(\.content), ["brand new"])
    }

    /// A stash's patch is a file someone applies elsewhere: it has to carry
    /// the untracked files from the third parent, each exactly once, or
    /// `git apply` either drops them or refuses the whole patch.
    func testStashPatchCarriesUntrackedFilesAndApplies() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-stashpatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        // Makes `git stash show -p` list untracked files on its own.
        _ = try await runner.run(in: repo, args: ["config", "stash.showIncludeUntracked", "true"])
        let tracked = tmp.appendingPathComponent("tracked.txt")
        try "one\ntwo\n".write(to: tracked, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "."])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])

        try "one\nTWO-MOD\n".write(to: tracked, atomically: true, encoding: .utf8)
        try "brand new\n".write(
            to: tmp.appendingPathComponent("fresh.txt"), atomically: true, encoding: .utf8
        )
        _ = try await git.stashSave(repoPath: repo, message: "with untracked", includeUntracked: true)

        let patch = try await git.createPatch(repoPath: repo, stashIndex: 0)
        let headers = patch.split(separator: "\n").filter { $0.hasPrefix("diff --git ") }
        XCTAssertEqual(headers.sorted(), [
            "diff --git a/fresh.txt b/fresh.txt",
            "diff --git a/tracked.txt b/tracked.txt",
        ])

        let patchFile = tmp.appendingPathComponent("stash.patch").path
        try patch.write(toFile: patchFile, atomically: true, encoding: .utf8)
        let check = try await runner.run(in: repo, args: ["apply", "--check", patchFile])
        XCTAssertTrue(check.succeeded, check.stderr)
    }
}
