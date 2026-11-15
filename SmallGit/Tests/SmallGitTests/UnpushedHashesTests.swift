import XCTest
@testable import SmallGit

final class UnpushedHashesTests: XCTestCase {

    func testIdentifiesCommitsAheadOfUpstreamAgainstRealGit() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        // Workflow: build the local repo first (so it has a commit), then
        // create the bare remote, then push -u to wire up tracking. This
        // avoids `git clone -b main` against an empty bare repo, which
        // fails because the `main` ref doesn't exist yet.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-unpushed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let remote = root.appendingPathComponent("origin.git")
        let local  = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let lp = local.path

        _ = try await runner.run(in: lp, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: lp, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: lp, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: lp, args: ["config", "commit.gpgsign", "false"])

        // Seed commit.
        try "alpha\n".write(to: local.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)
        _ = try await runner.run(in: lp, args: ["add", "a.txt"])
        _ = try await runner.run(in: lp, args: ["commit", "-q", "-m", "seed"])

        // Bare remote, then wire tracking by pushing -u.
        _ = try await runner.run(in: nil, args: [
            "-C", root.path, "init", "--bare", "-q", "-b", "main", "origin.git"
        ])
        _ = try await runner.run(in: lp, args: ["remote", "add", "origin", remote.path])
        _ = try await runner.run(in: lp, args: ["push", "-q", "-u", "origin", "main"])

        // Sanity: nothing unpushed yet.
        var unpushed = try await git.unpushedHashes(repoPath: lp)
        XCTAssertTrue(unpushed.isEmpty, "expected no unpushed commits right after push, got \(unpushed)")

        // Two more commits, NOT pushed.
        try "bravo\n".write(to: local.appendingPathComponent("b.txt"),
                            atomically: true, encoding: .utf8)
        _ = try await runner.run(in: lp, args: ["add", "b.txt"])
        _ = try await runner.run(in: lp, args: ["commit", "-q", "-m", "add b"])
        let bHash = try await git.currentHeadSHA(repoPath: lp)

        try "charlie\n".write(to: local.appendingPathComponent("c.txt"),
                              atomically: true, encoding: .utf8)
        _ = try await runner.run(in: lp, args: ["add", "c.txt"])
        _ = try await runner.run(in: lp, args: ["commit", "-q", "-m", "add c"])
        let cHash = try await git.currentHeadSHA(repoPath: lp)

        unpushed = try await git.unpushedHashes(repoPath: lp)
        XCTAssertEqual(unpushed.count, 2, "expected 2 unpushed commits, got \(unpushed)")
        XCTAssertTrue(unpushed.contains(bHash ?? ""), "missing add-b hash; got \(unpushed)")
        XCTAssertTrue(unpushed.contains(cHash ?? ""), "missing add-c hash; got \(unpushed)")

        // After pushing, set should clear.
        _ = try await runner.run(in: lp, args: ["push", "-q", "origin", "main"])
        unpushed = try await git.unpushedHashes(repoPath: lp)
        XCTAssertTrue(unpushed.isEmpty, "expected empty after push, got \(unpushed)")
    }

    /// The marker has to survive a wider graph.
    ///
    /// A branch one commit ahead of its remote draws the local chip and the
    /// `origin/…` chip on different rows — which is correct, and reads as a
    /// bug unless something says the row between them hasn't been pushed.
    /// While the marker was computed only for a HEAD-only graph, ticking a
    /// second ref switched off the one thing that explained the gap.
    @MainActor
    func testTheUnpushedMarkerSurvivesTickingASecondRef() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-unpushed-multiref-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let lp = local.path

        _ = try await runner.run(in: lp, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: lp, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: lp, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: lp, args: ["config", "commit.gpgsign", "false"])
        _ = try await runner.run(in: lp, args: ["commit", "-q", "--allow-empty", "-m", "v.18"])
        _ = try await runner.run(in: nil, args: [
            "-C", root.path, "init", "--bare", "-q", "-b", "main", "origin.git"
        ])
        _ = try await runner.run(in: lp, args: [
            "remote", "add", "origin", root.appendingPathComponent("origin.git").path
        ])
        _ = try await runner.run(in: lp, args: ["push", "-q", "-u", "origin", "main"])
        // A second ref for the graph to include, left where the remote is.
        _ = try await runner.run(in: lp, args: ["branch", "later"])
        // And the commit that isn't pushed — the one on the row in the report.
        _ = try await runner.run(in: lp, args: ["commit", "-q", "--allow-empty", "-m", "v.19"])

        let coordinator = CacheCoordinator(
            memoryCache: MemoryCache(), diskCache: DiskCache(), gitService: git
        )
        defer {
            let cleanup = coordinator
            Task { await cleanup.purgeDiskCache(forRepoPath: lp) }
        }
        coordinator.switchRepo(to: lp)
        let journal = JournalViewModel(coordinator: coordinator, git: git)

        await journal.setRefSelection(JournalRefSelection(head: true, refs: ["later"]))
        XCTAssertFalse(journal.refSelection.isHeadOnly, "the graph has to be the wider kind")

        let top = try XCTUnwrap(journal.commits.first)
        XCTAssertEqual(top.subject, "v.19")
        XCTAssertTrue(
            journal.isUnpushed(top),
            "the commit above origin/main is unpushed whatever else the graph is showing"
        )
        XCTAssertTrue(
            journal.canChangeMessage(of: top),
            "an unpushed HEAD commit must remain editable in a wider graph"
        )
        let pushed = try XCTUnwrap(journal.commits.first { $0.subject == "v.18" })
        XCTAssertFalse(journal.isUnpushed(pushed), "that one is on the remote")
        XCTAssertTrue(
            journal.canChangeMessage(of: pushed),
            "a published ancestor of HEAD must remain editable in a wider graph"
        )

        // HEAD out of the graph: there is no "ahead of my upstream" to draw,
        // and the query is skipped rather than answered for rows nobody asked
        // about.
        await journal.setRefSelection(JournalRefSelection(head: false, refs: ["later"]))
        XCTAssertTrue(journal.unpushedHashes.isEmpty)
        XCTAssertFalse(
            journal.canChangeMessage(of: top),
            "a graph without HEAD must not offer an operation that rewrites HEAD"
        )
    }

    func testFallsBackToNotRemotesForBranchesWithoutUpstream() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        // Same dual-repo setup as the upstream test, but after wiring
        // `main` to track origin, we branch off to a NEW local branch
        // that has no upstream and add a commit there. The new commit
        // must show up via the --not --remotes fallback even though
        // @{upstream}..HEAD fatals for that branch.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-noupstream-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let remote = root.appendingPathComponent("origin.git")
        let local  = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let lp = local.path

        _ = try await runner.run(in: lp, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: lp, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: lp, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: lp, args: ["config", "commit.gpgsign", "false"])
        try "alpha\n".write(to: local.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)
        _ = try await runner.run(in: lp, args: ["add", "a.txt"])
        _ = try await runner.run(in: lp, args: ["commit", "-q", "-m", "seed"])

        _ = try await runner.run(in: nil, args: [
            "-C", root.path, "init", "--bare", "-q", "-b", "main", "origin.git"
        ])
        _ = try await runner.run(in: lp, args: ["remote", "add", "origin", remote.path])
        _ = try await runner.run(in: lp, args: ["push", "-q", "-u", "origin", "main"])

        // Branch off into something with no upstream, add a commit.
        _ = try await runner.run(in: lp, args: ["checkout", "-q", "-b", "feature/new"])
        try "bravo\n".write(to: local.appendingPathComponent("b.txt"),
                            atomically: true, encoding: .utf8)
        _ = try await runner.run(in: lp, args: ["add", "b.txt"])
        _ = try await runner.run(in: lp, args: ["commit", "-q", "-m", "feature work"])
        let newHash = try await git.currentHeadSHA(repoPath: lp)

        // Sanity: there really is no upstream for this branch.
        let upstreamCheck = try await runner.run(in: lp, args: [
            "rev-parse", "--abbrev-ref", "@{upstream}"
        ])
        XCTAssertFalse(upstreamCheck.succeeded, "expected no upstream for feature/new")

        // The fallback path should still flag the new commit.
        let unpushed = try await git.unpushedHashes(repoPath: lp)
        XCTAssertTrue(unpushed.contains(newHash ?? ""),
                      "fallback failed: expected feature/new commit in unpushed set, got \(unpushed)")
    }

    func testReturnsEmptyWhenNoUpstreamConfigured() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-noupstream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        try "x\n".write(to: tmp.appendingPathComponent("x.txt"),
                        atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "x.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])

        // No remote — both `@{upstream}..HEAD` and `--not --remotes`
        // succeed but the latter returns *all* commits (none are on any
        // remote). That's the correct "everything is local" answer.
        let unpushed = try await git.unpushedHashes(repoPath: repo)
        XCTAssertEqual(unpushed.count, 1, "expected the single commit to be unpushed, got \(unpushed)")
    }
}
