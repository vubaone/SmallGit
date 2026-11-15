import XCTest
@testable import SmallGit

/// The push failure git refuses to resolve itself: the branch and its
/// upstream have different names, so `push.default = simple` will not guess
/// which was meant and pushes nothing. SmallGit offers the command git
/// suggests — and only runs it if the user says yes.
final class PushUpstreamMismatchTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        let repo: String
        let origin: String
        let root: URL
    }

    /// A repo on `main` whose upstream is `origin/other-name` — the exact
    /// shape that makes git refuse.
    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let git = GitService(runner: runner)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-pushmismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let origin = root.appendingPathComponent("origin.git").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "--bare", "-b", "main", "origin.git"])

        let repo = root.appendingPathComponent("repo").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main", "repo"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        // The setting that makes git refuse rather than guess. It is git's
        // own default since 2.0; pinned here so the test doesn't depend on
        // whatever the machine running it has configured.
        _ = try await runner.run(in: repo, args: ["config", "push.default", "simple"])
        _ = try await runner.run(in: repo, args: ["remote", "add", "origin", origin])

        let box = Sandbox(runner: runner, git: git, repo: repo, origin: origin, root: root)
        try await commit(box, "c1")
        // Publish under a different name, then track it.
        _ = try await runner.run(in: repo, args: ["push", "-q", "origin", "main:other-name"])
        _ = try await runner.run(in: repo, args: ["branch", "--set-upstream-to=origin/other-name", "main"])
        return box
    }

    @discardableResult
    private func commit(_ box: Sandbox, _ message: String) async throws -> String {
        let file = URL(fileURLWithPath: box.repo).appendingPathComponent("a.txt")
        try "\(message)\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await box.runner.run(in: box.repo, args: ["add", "a.txt"])
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-q", "-m", message])
        return try await revParse(box, in: box.repo, ref: "HEAD")
    }

    private func revParse(_ box: Sandbox, in path: String, ref: String) async throws -> String {
        let r = try await box.runner.run(in: path, args: ["rev-parse", ref])
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Detection

    /// The detector has to match what git actually prints, which wraps the
    /// sentence across two lines — a plain `contains` on it finds nothing.
    func testRealGitProducesTheFailureWeDetect() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let result = try await box.git.push(repoPath: box.repo)
        XCTAssertFalse(result.succeeded, "git should refuse to guess")
        XCTAssertTrue(
            AppState.pushFailedUpstreamNameMismatch(result),
            "unrecognised: \(result.combinedOutput)"
        )
        XCTAssertFalse(
            AppState.pushFailedUpstreamNameMismatch(
                GitCommandResult(command: "git push", exitCode: 1,
                                 stdout: "", stderr: "Everything up-to-date", duration: 0)
            ),
            "an unrelated failure must not be mistaken for this one"
        )
    }

    /// Both halves of the upstream, read from config rather than split out
    /// of `origin/other-name` — which cannot be split back reliably.
    func testUpstreamOfBranchSeparatesTheRemoteFromTheBranch() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let upstream = try await box.git.upstreamOfBranch(repoPath: box.repo, branch: "main")
        XCTAssertEqual(upstream?.remote, "origin")
        XCTAssertEqual(upstream?.branch, "other-name")
    }

    func testPushToArgumentsSpellsOutTheRefspec() {
        XCTAssertEqual(
            GitService.pushToArguments(
                remote: "origin",
                localBranch: "main",
                remoteBranch: "other-name",
                force: true
            ),
            ["push", "--force-with-lease", "origin", "main:other-name"]
        )
        XCTAssertEqual(
            GitService.pushToArguments(
                remote: "origin",
                localBranch: "main",
                remoteBranch: "other-name",
                force: true,
                tags: true
            ),
            ["push", "--force-with-lease", "--tags", "origin", "main:other-name"],
            "a retry must not quietly stop pushing tags"
        )
    }

    // MARK: - The offer

    @MainActor
    func testForcePushOffersTheExactCommandAndRunsItOnceConfirmed() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let head = try await commit(box, "c2")

        let platform = RecordingPlatformServices()
        platform.confirmWarningAnswer = true
        let app = makeIsolatedAppState(git: box.git, platform: platform)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)

        let pushed = await app.push(force: true)

        XCTAssertTrue(pushed, "the confirmed push should go through")
        let remoteHead = try await revParse(box, in: box.origin, ref: "refs/heads/other-name")
        XCTAssertEqual(remoteHead, head, "origin/other-name should now hold c2")

        XCTAssertEqual(platform.warnings.count, 1, "asked exactly once")
        let warning = try XCTUnwrap(platform.warnings.first)
        XCTAssertEqual(warning.primaryButton, "Force Push")
        XCTAssertTrue(warning.title.contains("origin/other-name"), warning.title)
        XCTAssertTrue(
            warning.message.contains("git push --force-with-lease origin main:other-name"),
            "the dialog has to show the command it will run — got: \(warning.message)"
        )
    }

    /// The whole point of routing this through a button: saying no pushes
    /// nothing at all.
    @MainActor
    func testDecliningTheOfferPushesNothing() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let before = try await revParse(box, in: box.origin, ref: "refs/heads/other-name")
        _ = try await commit(box, "c2")

        let platform = RecordingPlatformServices()
        platform.confirmWarningAnswer = false
        let app = makeIsolatedAppState(git: box.git, platform: platform)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)

        let pushed = await app.push()

        XCTAssertFalse(pushed)
        XCTAssertEqual(app.statusText, "Push cancelled")
        let after = try await revParse(box, in: box.origin, ref: "refs/heads/other-name")
        XCTAssertEqual(after, before, "the remote must be untouched")

        let warning = try XCTUnwrap(platform.warnings.first)
        XCTAssertEqual(warning.primaryButton, "Push", "a plain push is not offered as a force push")
        XCTAssertTrue(
            warning.message.contains("git push origin main:other-name"),
            warning.message
        )
    }
}
