import XCTest
@testable import SmallGit

/// A force push refused because the lease is stale: the remote has moved
/// since this repository last fetched, so `--force-with-lease` is protecting
/// commits nobody here has ever seen.
///
/// Git reports it as `! [rejected] main -> main (stale info)` and stops,
/// which says neither what is stale nor what to do about it. The recovery
/// fetches, names what arrived, and only then offers to overwrite it — the
/// decision `--force-with-lease` exists to force, made once with the facts
/// on screen instead of being lost to a plain `--force`.
final class PushStaleLeaseTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        /// The repository under test — tracking, and out of date.
        let repo: String
        /// A second clone, standing in for whoever else pushed.
        let other: String
        let origin: String
        let root: URL
    }

    /// `repo` and `other` both track `origin/main` at c1. `other` then
    /// pushes c2 and `repo` never fetches, so its lease is a commit behind
    /// reality. `repo` meanwhile rewrites its own history, which is what
    /// makes a force push necessary in the first place.
    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let git = GitService(runner: runner)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-stalelease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let origin = root.appendingPathComponent("origin.git").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "--bare", "-b", "main", "origin.git"])

        let repo = root.appendingPathComponent("repo").path
        try await makeClone(runner, origin: origin, at: repo, from: root, name: "repo")
        try await write(runner, in: repo, "v1", message: "c1")
        _ = try await runner.run(in: repo, args: ["push", "-q", "-u", "origin", "main"])

        let other = root.appendingPathComponent("other").path
        _ = try await runner.run(in: root.path, args: ["clone", "-q", origin, "other"])
        _ = try await runner.run(in: other, args: ["config", "user.email", "o@x"])
        _ = try await runner.run(in: other, args: ["config", "user.name",  "O"])
        _ = try await runner.run(in: other, args: ["config", "commit.gpgsign", "false"])
        try await write(runner, in: other, "v2", message: "someone else's work")
        _ = try await runner.run(in: other, args: ["push", "-q", "origin", "main"])

        // `repo` rewrites c1 without ever hearing about c2.
        try await write(runner, in: repo, "v1-rewritten", message: "c1 rewritten")
        _ = try await runner.run(in: repo, args: ["commit", "-q", "--amend", "-m", "c1 rewritten"])

        return Sandbox(runner: runner, git: git, repo: repo, other: other, origin: origin, root: root)
    }

    private func makeClone(
        _ runner: ProcessRunner, origin: String, at path: String, from root: URL, name: String
    ) async throws {
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main", name])
        _ = try await runner.run(in: path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: path, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: path, args: ["config", "commit.gpgsign", "false"])
        _ = try await runner.run(in: path, args: ["remote", "add", "origin", origin])
    }

    private func write(
        _ runner: ProcessRunner, in repo: String, _ body: String, message: String
    ) async throws {
        try "\(body)\n".write(
            to: URL(fileURLWithPath: repo).appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try await runner.run(in: repo, args: ["add", "a.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", message])
    }

    private func revParse(_ box: Sandbox, in path: String, _ ref: String) async throws -> String {
        let r = try await box.runner.run(in: path, args: ["rev-parse", ref])
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Detection

    func testRealGitProducesTheRejectionWeDetect() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let result = try await box.git.push(repoPath: box.repo, force: true)
        XCTAssertFalse(result.succeeded, "the lease is a commit out of date")
        XCTAssertTrue(
            AppState.pushRejectedStaleLease(result),
            "unrecognised: \(result.combinedOutput)"
        )
    }

    /// The two rejections mean different things and lead to different
    /// recoveries — "you are behind" versus "you are behind something you
    /// have never fetched" — so neither matcher may answer for the other.
    func testAnOrdinaryNonFastForwardIsNotMistakenForIt() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let result = try await box.git.push(repoPath: box.repo)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(
            AppState.pushRejectedStaleLease(result),
            "a plain rejection is not a stale lease: \(result.combinedOutput)"
        )
    }

    // MARK: - The recovery

    @MainActor
    func testDecliningLeavesTheRemoteAloneAndNamesWhatWouldHaveGone() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let remoteBefore = try await revParse(box, in: box.origin, "main")

        let platform = RecordingPlatformServices()
        platform.confirmWarningAnswer = false
        let app = makeIsolatedAppState(git: box.git, platform: platform)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)

        let pushed = await app.push(force: true)
        XCTAssertFalse(pushed)
        let remoteAfter = try await revParse(box, in: box.origin, "main")
        XCTAssertEqual(
            remoteAfter, remoteBefore,
            "declining must leave the remote exactly as it was"
        )

        let warning = try XCTUnwrap(platform.warnings.last, "the user has to be asked")
        XCTAssertTrue(warning.title.contains("origin/main"), warning.title)
        XCTAssertTrue(
            warning.message.contains("someone else's work"),
            "the commit at stake has to be named, not counted: \(warning.message)"
        )
    }

    @MainActor
    func testConfirmingFetchesFirstAndThenForcePushes() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let platform = RecordingPlatformServices()
        platform.confirmWarningAnswer = true
        let app = makeIsolatedAppState(git: box.git, platform: platform)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)

        let pushed = await app.push(force: true)
        XCTAssertTrue(pushed, "with the lease refreshed the push goes through")
        let onRemote = try await revParse(box, in: box.origin, "main")
        let local = try await revParse(box, in: box.repo, "HEAD")
        XCTAssertEqual(
            onRemote, local,
            "the remote branch is now this repository's"
        )
        XCTAssertEqual(platform.warnings.count, 1, "asked once, not once per attempt")
    }

    /// The fetch alone can settle it. A remote-tracking ref can fall out of
    /// date without the branch having diverged at all — an interrupted fetch,
    /// a ref rolled back — and then the lease is stale over commits that are
    /// already in this branch's history. Nothing is at stake, so nothing is
    /// asked: the fetch brings the lease current and the push goes.
    @MainActor
    func testNothingAtStakeAfterTheFetchNeedsNoConfirmation() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        // Take the remote's commit in and build on it, so HEAD contains
        // everything the remote has.
        _ = try await box.runner.run(in: box.repo, args: ["fetch", "-q", "origin"])
        _ = try await box.runner.run(in: box.repo, args: ["reset", "-q", "--hard", "origin/main"])
        // Then wind the remote-tracking ref back a commit: that, and only
        // that, is what makes the lease stale.
        _ = try await box.runner.run(in: box.repo, args: [
            "update-ref", "refs/remotes/origin/main", "HEAD~1"
        ])
        try await write(box.runner, in: box.repo, "v3", message: "built on top")

        let platform = RecordingPlatformServices()
        platform.confirmWarningAnswer = false
        let app = makeIsolatedAppState(git: box.git, platform: platform)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)

        let pushed = await app.push(force: true)
        XCTAssertTrue(pushed, "nothing of the remote's is at stake")
        XCTAssertTrue(platform.warnings.isEmpty, "so nothing to ask about")
    }
}
