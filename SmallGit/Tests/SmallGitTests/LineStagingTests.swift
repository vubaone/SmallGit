import XCTest
@testable import SmallGit

final class LineStagingTests: XCTestCase {

    // MARK: - Unit: patch synthesis

    func testStageSingleAddDropsOtherAdds() {
        // Original hunk:
        //   context
        //   +alpha
        //   +beta
        //   context
        // Stage only `+beta` → expect patch with only beta added, alpha gone.
        let alpha = DiffLine(type: .add, content: "alpha", newLineNumber: 2)
        let beta  = DiffLine(type: .add, content: "beta",  newLineNumber: 3)
        let hunk = DiffHunk(
            oldStart: 1, oldCount: 2,
            newStart: 1, newCount: 4,
            lines: [
                DiffLine(type: .context, content: "head", oldLineNumber: 1, newLineNumber: 1),
                alpha,
                beta,
                DiffLine(type: .context, content: "tail", oldLineNumber: 2, newLineNumber: 4)
            ]
        )
        let patch = DiffPatchBuilder.buildLinePatch(file: "x.swift", hunk: hunk, targetLine: beta) ?? ""
        // Body of the patch (after the header) should be:
        //   context head
        //   +beta
        //   context tail
        XCTAssertTrue(patch.contains("\n+beta\n"))
        XCTAssertFalse(patch.contains("\n+alpha\n"), "alpha should be dropped, got:\n\(patch)")
        // Old:1 line of context + 1 trailing context = 2; New: 1 context + 1 add + 1 context = 3
        XCTAssertTrue(patch.contains("@@ -1,2 +1,3 @@"), "got header:\n\(patch)")
    }

    func testStageSingleDelDemotesOtherDels() {
        // Original hunk:
        //   context
        //   -alpha
        //   -beta
        //   context
        // Stage only `-beta` → expect patch where alpha is now context.
        let alpha = DiffLine(type: .del, content: "alpha", oldLineNumber: 2)
        let beta  = DiffLine(type: .del, content: "beta",  oldLineNumber: 3)
        let hunk = DiffHunk(
            oldStart: 1, oldCount: 4,
            newStart: 1, newCount: 2,
            lines: [
                DiffLine(type: .context, content: "head", oldLineNumber: 1, newLineNumber: 1),
                alpha,
                beta,
                DiffLine(type: .context, content: "tail", oldLineNumber: 4, newLineNumber: 2)
            ]
        )
        let patch = DiffPatchBuilder.buildLinePatch(file: "x.swift", hunk: hunk, targetLine: beta) ?? ""
        XCTAssertTrue(patch.contains("\n-beta\n"))
        XCTAssertTrue(patch.contains("\n alpha\n"), "alpha should be downgraded to context, got:\n\(patch)")
        // Old: head + alpha-context + beta-removed + tail = 4 ; New: head + alpha + tail = 3
        XCTAssertTrue(patch.contains("@@ -1,4 +1,3 @@"), "got header:\n\(patch)")
    }

    func testStageLineRejectsContextOrEmpty() {
        let ctx = DiffLine(type: .context, content: "x")
        let empty = DiffLine(type: .empty, content: "")
        let hunk = DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: [ctx, empty])
        XCTAssertNil(DiffPatchBuilder.buildLinePatch(file: "f", hunk: hunk, targetLine: ctx))
        XCTAssertNil(DiffPatchBuilder.buildLinePatch(file: "f", hunk: hunk, targetLine: empty))
    }

    func testStageLineRejectsLineFromDifferentHunk() {
        let foreign = DiffLine(type: .add, content: "orphan")
        let local   = DiffLine(type: .add, content: "local")
        let hunk = DiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 1, lines: [local])
        XCTAssertNil(DiffPatchBuilder.buildLinePatch(file: "f", hunk: hunk, targetLine: foreign))
    }

    // MARK: - Unit: multi-line / multi-hunk patch synthesis

    func testStageMultipleAddsKeepsBoth() {
        let alpha = DiffLine(type: .add, content: "alpha", newLineNumber: 2)
        let beta  = DiffLine(type: .add, content: "beta",  newLineNumber: 3)
        let gamma = DiffLine(type: .add, content: "gamma", newLineNumber: 4)
        let hunk = DiffHunk(
            oldStart: 1, oldCount: 1,
            newStart: 1, newCount: 4,
            lines: [
                DiffLine(type: .context, content: "head", oldLineNumber: 1, newLineNumber: 1),
                alpha, beta, gamma
            ]
        )
        let patch = DiffPatchBuilder.buildLinesPatch(
            file: "x.swift",
            hunks: [hunk],
            targetLineIDs: [alpha.id, gamma.id]
        ) ?? ""
        // alpha + gamma kept; beta dropped.
        XCTAssertTrue(patch.contains("\n+alpha\n"))
        XCTAssertTrue(patch.contains("\n+gamma\n"))
        XCTAssertFalse(patch.contains("\n+beta\n"), "beta should be dropped, got:\n\(patch)")
    }

    func testStageLinesAcrossHunksKeepsOnlyHunksWithTargets() {
        let a1 = DiffLine(type: .add, content: "a1", newLineNumber: 2)
        let a2 = DiffLine(type: .add, content: "a2", newLineNumber: 3)
        let hunk1 = DiffHunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 3,
            lines: [
                DiffLine(type: .context, content: "h1", oldLineNumber: 1, newLineNumber: 1),
                a1, a2
            ]
        )
        let b1 = DiffLine(type: .add, content: "b1", newLineNumber: 22)
        let hunk2 = DiffHunk(
            oldStart: 20, oldCount: 1, newStart: 20, newCount: 2,
            lines: [
                DiffLine(type: .context, content: "h2", oldLineNumber: 20, newLineNumber: 20),
                b1
            ]
        )
        // Only target a1 → hunk2 has no target lines and should be omitted.
        let patch = DiffPatchBuilder.buildLinesPatch(
            file: "x", hunks: [hunk1, hunk2], targetLineIDs: [a1.id]
        ) ?? ""
        XCTAssertTrue(patch.contains("\n+a1\n"))
        XCTAssertFalse(patch.contains("\n+a2\n"))
        XCTAssertFalse(patch.contains("\n+b1\n"))
        XCTAssertFalse(patch.contains(" h2"), "second hunk should be skipped, got:\n\(patch)")
    }

    func testBuildLinesPatchEmptySelectionReturnsNil() {
        let hunk = DiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 1, lines: [
            DiffLine(type: .add, content: "x")
        ])
        XCTAssertNil(DiffPatchBuilder.buildLinesPatch(
            file: "f", hunks: [hunk], targetLineIDs: []
        ))
    }

    // MARK: - Integration: real git

    func testStageOneLineLeavesOthersUnstaged() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git binary not available")
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-linestage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let repo = tmpDir.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])

        let original = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
        let fileURL = tmpDir.appendingPathComponent("a.txt")
        try original.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "a.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])

        // Add two new lines in a single hunk.
        var modified = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        modified.insert("ALPHA", at: 5)
        modified.insert("BETA", at: 6)
        try modified.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        let hunks = try await git.diff(repoPath: repo, file: "a.txt")
        XCTAssertEqual(hunks.count, 1)
        let hunk = try XCTUnwrap(hunks.first)

        // Stage only the BETA line.
        guard let beta = hunk.lines.first(where: { $0.type == .add && $0.content == "BETA" }) else {
            return XCTFail("BETA line not found in hunk: \(hunk.lines)")
        }
        let patch = try XCTUnwrap(
            DiffPatchBuilder.buildLinePatch(file: "a.txt", hunk: hunk, targetLine: beta)
        )
        _ = try await git.applyPatch(repoPath: repo, patch: patch, cached: true, reverse: false)

        // Index now contains the original + BETA only. The working tree still
        // has ALPHA staged-pending → file should be both staged and unstaged.
        let statuses = try await git.status(repoPath: repo)
        let entry = try XCTUnwrap(statuses.first { $0.path == "a.txt" })
        XCTAssertTrue(entry.isStaged,   "expected file to be staged")
        XCTAssertTrue(entry.isUnstaged, "expected file to still have unstaged changes (ALPHA)")

        // Sanity: the staged diff should contain BETA but not ALPHA.
        let stagedHunks = try await git.diff(repoPath: repo, file: "a.txt", mode: .headVsIndex)
        let stagedContents = stagedHunks.flatMap(\.lines).map(\.content)
        XCTAssertTrue(stagedContents.contains("BETA"))
        XCTAssertFalse(stagedContents.contains("ALPHA"),
                       "ALPHA should not be in the staged diff yet")
    }
}
