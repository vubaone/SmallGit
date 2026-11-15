import XCTest
@testable import SmallGit

/// Regression: staging a hunk/line in a file whose final line has no
/// trailing newline must succeed. Git marks that line with
/// "\ No newline at end of file"; if the patch we build drops the marker,
/// `git apply --cached` rejects it with "patch does not apply".
@MainActor
final class StageNoNewlineTests: XCTestCase {

    private let git = GitService.shared
    private let runner = ProcessRunner()

    private func makeRepo() async throws -> (path: String, root: URL) {
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-nonl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: root.path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: root.path, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: root.path, args: ["config", "commit.gpgsign", "false"])
        return (root.path, root)
    }

    func testStageHunkOnFileWithoutTrailingNewline() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let file = URL(fileURLWithPath: repo.path).appendingPathComponent("text.txt")

        // Commit a file whose final line has NO trailing newline.
        try "1\n2\n3\n4\n5\n6".write(to: file, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo.path, args: ["add", "text.txt"])
        _ = try await runner.run(in: repo.path, args: ["commit", "-q", "-m", "init"])

        // Working tree gains lines 7-10 (now WITH a trailing newline).
        try "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n".write(to: file, atomically: true, encoding: .utf8)

        let hunks = try await git.diff(
            repoPath: repo.path,
            file: "text.txt",
            mode: .indexVsWorkingTree
        )
        XCTAssertFalse(hunks.isEmpty, "expected a diff")

        let patch = try XCTUnwrap(DiffPatchBuilder.buildPatch(file: "text.txt", hunks: hunks))

        // This is the assertion that fails before the fix: git rejects the
        // patch because the "\ No newline at end of file" marker is missing.
        let result = try await git.applyPatch(repoPath: repo.path, patch: patch, cached: true)
        XCTAssertTrue(result.succeeded, "git apply --cached should accept the patch: \(result.stderr)")

        // After staging the whole hunk the index matches the working tree.
        let staged = try await runner.run(
            in: repo.path,
            args: ["diff", "--cached", "--name-only"]
        )
        XCTAssertTrue(staged.stdout.contains("text.txt"))
        let unstaged = try await runner.run(in: repo.path, args: ["diff", "--name-only"])
        XCTAssertFalse(unstaged.stdout.contains("text.txt"), "nothing should remain unstaged")
    }

    /// Staging a single added line in the same no-newline scenario. The
    /// `-6` removal (which adds the trailing newline) and its re-add must be
    /// pulled in automatically, or the per-line patch is inconsistent and
    /// git rejects it.
    func testStageSingleAddedLineAcrossNoNewlineBoundary() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let file = URL(fileURLWithPath: repo.path).appendingPathComponent("text.txt")

        try "1\n2\n3\n4\n5\n6".write(to: file, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo.path, args: ["add", "text.txt"])
        _ = try await runner.run(in: repo.path, args: ["commit", "-q", "-m", "init"])
        try "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n".write(to: file, atomically: true, encoding: .utf8)

        let hunks = try await git.diff(
            repoPath: repo.path,
            file: "text.txt",
            mode: .indexVsWorkingTree
        )
        // Stage just the "+7" line.
        let plus7 = try XCTUnwrap(
            hunks.flatMap(\.lines).first { $0.type == .add && $0.content == "7" }
        )
        let patch = try XCTUnwrap(DiffPatchBuilder.buildLinesPatch(
            file: "text.txt",
            hunks: hunks,
            targetLineIDs: [plus7.id]
        ))
        let result = try await git.applyPatch(repoPath: repo.path, patch: patch, cached: true)
        XCTAssertTrue(result.succeeded, "per-line patch should apply: \(result.stderr)")

        // The index now ends at line 7 (with a trailing newline); 8-10 stay
        // unstaged.
        let staged = try await runner.run(in: repo.path, args: ["show", ":text.txt"])
        XCTAssertEqual(staged.stdout, "1\n2\n3\n4\n5\n6\n7\n")
    }

    /// Two-step flow that mirrors the UI: stage line 6, then line 7. The
    /// second stage must build its patch from a *re-fetched* diff. Using the
    /// stale pre-stage hunks (as the app did before the diff-panel reload
    /// fix) builds a patch whose old side no longer matches the index, and
    /// git rejects it.
    func testSequentialLineStagesNeedFreshDiff() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let file = URL(fileURLWithPath: repo.path).appendingPathComponent("text.txt")

        try "1\n2\n3\n4\n5\n6".write(to: file, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo.path, args: ["add", "text.txt"])
        _ = try await runner.run(in: repo.path, args: ["commit", "-q", "-m", "init"])
        try "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n".write(to: file, atomically: true, encoding: .utf8)

        // Stage line 6.
        let hunks1 = try await git.diff(repoPath: repo.path, file: "text.txt", mode: .indexVsWorkingTree)
        let plus6 = try XCTUnwrap(hunks1.flatMap(\.lines).first { $0.type == .add && $0.content == "6" })
        let patch6 = try XCTUnwrap(DiffPatchBuilder.buildLinesPatch(file: "text.txt", hunks: hunks1, targetLineIDs: [plus6.id]))
        try await git.applyPatch(repoPath: repo.path, patch: patch6, cached: true)

        // Building line 7's patch from the STALE hunks (hunks1) fails — this
        // is exactly the user-reported "patch does not apply".
        let stale7 = try XCTUnwrap(hunks1.flatMap(\.lines).first { $0.type == .add && $0.content == "7" })
        let stalePatch = try XCTUnwrap(DiffPatchBuilder.buildLinesPatch(file: "text.txt", hunks: hunks1, targetLineIDs: [stale7.id]))
        let staleResult = try? await git.applyPatch(repoPath: repo.path, patch: stalePatch, cached: true)
        XCTAssertNil(staleResult, "stale-hunk patch is expected to be rejected by git")

        // Re-fetching the diff (what the panel reload now does) yields hunks
        // that match the updated index, and staging line 7 succeeds.
        let hunks2 = try await git.diff(repoPath: repo.path, file: "text.txt", mode: .indexVsWorkingTree)
        let fresh7 = try XCTUnwrap(hunks2.flatMap(\.lines).first { $0.type == .add && $0.content == "7" })
        let freshPatch = try XCTUnwrap(DiffPatchBuilder.buildLinesPatch(file: "text.txt", hunks: hunks2, targetLineIDs: [fresh7.id]))
        let freshResult = try await git.applyPatch(repoPath: repo.path, patch: freshPatch, cached: true)
        XCTAssertTrue(freshResult.succeeded, "patch from fresh diff should apply: \(freshResult.stderr)")

        let staged = try await runner.run(in: repo.path, args: ["show", ":text.txt"])
        XCTAssertEqual(staged.stdout, "1\n2\n3\n4\n5\n6\n7\n")
    }
}
