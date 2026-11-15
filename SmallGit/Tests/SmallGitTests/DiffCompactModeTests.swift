import XCTest
@testable import SmallGit

/// Compact (the default) fetches the short diff — changed regions plus a
/// few lines of context. Non-compact passes `--unified=<all>` so the diff
/// spans the whole file. These run against real git to prove the context
/// actually differs at the `git diff` level (it's git, not the view, that
/// decides how much context to emit).
final class DiffCompactModeTests: XCTestCase {

    private let runner = ProcessRunner()

    private func makeRepo() async throws -> (path: String, root: URL) {
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-compact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: root.path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: root.path, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: root.path, args: ["config", "commit.gpgsign", "false"])
        return (root.path, root)
    }

    /// A 40-line file with a single edit in the middle: compact shows a
    /// small window of context, full shows every unchanged line too.
    func testFullFileShowsMoreContextThanCompact() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let file = URL(fileURLWithPath: repo.path).appendingPathComponent("a.txt")

        let original = (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo.path, args: ["add", "a.txt"])
        _ = try await runner.run(in: repo.path, args: ["commit", "-q", "-m", "init"])

        // Edit one line in the middle.
        var lines = (1...40).map { "line \($0)" }
        lines[19] = "line 20 CHANGED"
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let git = GitService(runner: runner)

        let compact = try await git.diff(
            repoPath: repo.path, file: "a.txt",
            mode: .indexVsWorkingTree, fullFile: false
        )
        let full = try await git.diff(
            repoPath: repo.path, file: "a.txt",
            mode: .indexVsWorkingTree, fullFile: true
        )

        func contextCount(_ hunks: [DiffHunk]) -> Int {
            hunks.flatMap(\.lines).filter { $0.type == .context }.count
        }

        // Compact's default context is small (a handful of lines); full
        // carries all 39 unchanged lines.
        XCTAssertEqual(contextCount(full), 39, "full-file diff should include every unchanged line")
        XCTAssertLessThan(contextCount(compact), contextCount(full))

        // Both still capture the same single change.
        for hunks in [compact, full] {
            let adds = hunks.flatMap(\.lines).filter { $0.type == .add }.map(\.content)
            let dels = hunks.flatMap(\.lines).filter { $0.type == .del }.map(\.content)
            XCTAssertEqual(adds, ["line 20 CHANGED"])
            XCTAssertEqual(dels, ["line 20"])
        }
    }
}
