import XCTest
@testable import SmallGit

/// Covers the split between index-backed paths (`git rm`) and paths Git has
/// never tracked (`git clean`). A mixed context-menu selection must not let
/// one untracked or ignored path make the whole removal fail.
final class FileRemovalIntegrationTests: XCTestCase {
    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        let repo: URL
    }

    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-remove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await runner.run(in: repo.path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo.path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo.path, args: ["config", "user.name", "T"])

        try "ignored.txt\n".write(
            to: repo.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "tracked\n".write(
            to: repo.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await runner.run(in: repo.path, args: ["add", ".gitignore", "tracked.txt"])
        _ = try await runner.run(in: repo.path, args: ["commit", "-q", "-m", "seed"])

        return Sandbox(runner: runner, git: GitService(runner: runner), repo: repo)
    }

    private func row(_ path: String, marker: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: marker, workTreeStatus: marker)
    }

    @MainActor
    func testDeletingMixedSelectionRemovesEveryPathAndStagesTrackedDeletion() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.repo) }

        try "untracked\n".write(
            to: box.repo.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored\n".write(
            to: box.repo.appendingPathComponent("ignored.txt"),
            atomically: true,
            encoding: .utf8
        )

        let platform = RecordingPlatformServices()
        platform.confirmWarningAnswer = true
        let app = makeIsolatedAppState(git: box.git, platform: platform)
        app.activeRepo = RepositoryEntry(path: box.repo.path, name: "remove-test")
        app.coordinator.switchRepo(to: box.repo.path)

        await app.removeFiles(
            files: [
                row("tracked.txt", marker: "M"),
                row("untracked.txt", marker: "?"),
                row("ignored.txt", marker: "!")
            ],
            deleteFromDisk: true
        )

        XCTAssertEqual(platform.warnings.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.repo.appendingPathComponent("tracked.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.repo.appendingPathComponent("untracked.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.repo.appendingPathComponent("ignored.txt").path))

        let staged = try await box.runner.run(
            in: box.repo.path,
            args: ["diff", "--cached", "--name-status"]
        )
        XCTAssertTrue(staged.stdout.contains("D\ttracked.txt"), staged.stdout)
    }

    func testRemovingAMissingTrackedPathReportsGitFailure() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.repo) }

        do {
            _ = try await box.git.removeFile(
                repoPath: box.repo.path,
                path: "not-in-the-index.txt"
            )
            XCTFail("git rm failure should be thrown")
        } catch let GitServiceError.gitFailed(_, exitCode, _) {
            XCTAssertNotEqual(exitCode, 0)
        }
    }
}
