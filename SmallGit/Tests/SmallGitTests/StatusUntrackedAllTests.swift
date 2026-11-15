import XCTest
@testable import SmallGit

/// Locks in the SmartGit-matching behavior: when the working tree has
/// a new untracked directory, the Files panel must surface each file
/// inside it — not collapse the whole directory into a single row.
/// Driven by passing `--untracked-files=all` to `git status`.
final class StatusUntrackedAllTests: XCTestCase {

    func testUntrackedDirectoryListsIndividualFiles() async throws {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let git = GitService(runner: runner)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-untracked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])

        // One committed file so HEAD exists.
        try "seed\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8
        )
        _ = try await runner.run(in: repo, args: ["add", "README.md"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "seed"])

        // Create a brand-new untracked directory with three files inside.
        let newDir = root.appendingPathComponent("_temp/profile_avatar/res", isDirectory: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        for name in ["config.json", "data.json", "Main.ts"] {
            try "stub\n".write(
                to: newDir.appendingPathComponent(name),
                atomically: true, encoding: .utf8
            )
        }

        let files = try await git.status(repoPath: repo)
        let paths = files.map(\.path)

        // We must see each file by its full path. The pre-fix behavior
        // would have collapsed to `_temp/` as a single entry.
        XCTAssertTrue(
            paths.contains("_temp/profile_avatar/res/config.json"),
            "expected individual files under untracked dir, got \(paths)"
        )
        XCTAssertTrue(paths.contains("_temp/profile_avatar/res/data.json"))
        XCTAssertTrue(paths.contains("_temp/profile_avatar/res/Main.ts"))

        // And the collapsed directory form should NOT be present — if
        // git ever regresses to "normal" untracked mode we want this
        // test to fail loudly.
        XCTAssertFalse(
            paths.contains(where: { $0.hasSuffix("/") || $0 == "_temp" }),
            "expected no directory-only entries, got \(paths)"
        )
    }
}
