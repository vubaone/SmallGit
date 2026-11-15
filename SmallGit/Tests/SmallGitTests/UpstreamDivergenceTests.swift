import XCTest
@testable import SmallGit

/// What the Journal does once the branch and its upstream have forked —
/// which, after a squash or a rebase, is every time.
///
/// The failure mode is not an error: the log draws the rewritten branch, the
/// rewritten commit is the one the user was looking for, and the commits
/// still sitting on the remote are simply not on screen. Nothing says a force
/// push is coming.
@MainActor
final class UpstreamDivergenceTests: XCTestCase {

    // MARK: - Which refs the log is asked for

    private func commit(_ n: Int) -> GitCommit {
        GitCommit(
            hash: "hash\(n)", shortHash: "h\(n)", subject: "c\(n)",
            authorName: "T", authorEmail: "t@x",
            date: Date(timeIntervalSince1970: TimeInterval(n)), refs: ""
        )
    }

    func testADivergedUpstreamJoinsTheHeadOnlyGraph() {
        let widened = JournalViewModel.effectiveSelection(
            .headOnly,
            gap: UpstreamGap(ref: "origin/main", incoming: ["a", "b"])
        )
        XCTAssertEqual(widened.revisions, ["HEAD", "origin/main"])
        // The user's own setting is untouched — "HEAD Only" is still what the
        // Branches panel reports, and the banner it drives stays away.
        XCTAssertTrue(JournalRefSelection.headOnly.isHeadOnly)
    }

    /// In sync, or merely ahead: the upstream is an ancestor of HEAD and
    /// naming it would add nothing but a second name for the same commits.
    func testAnUpstreamWithNothingNewLeavesTheQueryAlone() {
        let selection = JournalViewModel.effectiveSelection(
            .headOnly,
            gap: UpstreamGap(ref: "origin/main", incoming: [])
        )
        XCTAssertEqual(selection, .headOnly)
        XCTAssertEqual(JournalViewModel.effectiveSelection(.headOnly, gap: nil), .headOnly)
    }

    /// The cache is keyed off the refs, so a widened query must not be able
    /// to answer from — or poison — the plain `git log` entry.
    func testTheWidenedQueryGetsItsOwnCacheKey() {
        let widened = JournalViewModel.effectiveSelection(
            .headOnly,
            gap: UpstreamGap(ref: "origin/main", incoming: ["a"])
        )
        XCTAssertNotEqual(widened.cacheToken, JournalRefSelection.headOnly.cacheToken)
    }

    /// HEAD unticked is a graph about something else; its upstream is not
    /// part of the question.
    func testAGraphWithoutHeadIsNotWidened() {
        let pinned = JournalRefSelection(head: false, refs: ["main"])
        XCTAssertEqual(
            JournalViewModel.effectiveSelection(
                pinned, gap: UpstreamGap(ref: "origin/main", incoming: ["a"])
            ),
            pinned
        )
    }

    /// Unless the ref ticked is the branch HEAD has checked out: that is
    /// HEAD's history under its other name, and a rebased branch ticked that
    /// way beside another one showed no fork at all.
    func testTheCheckedOutBranchTickedByNameIsWidened() {
        let selection = JournalRefSelection(head: false, refs: ["main", "topic"])
        let widened = JournalViewModel.effectiveSelection(
            selection,
            gap: UpstreamGap(ref: "origin/topic", incoming: ["a"]),
            checkedOut: "topic"
        )
        XCTAssertEqual(widened.revisions, ["main", "origin/topic", "topic"])
    }

    // MARK: - Against real git

    /// Three commits pushed, then the top two squashed: the branch is one
    /// ahead and two behind, and both tips have to be on screen.
    func testASquashedBranchGraphsBothTipsAgainstRealGit() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-diverge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let lp = local.path

        _ = try await runner.run(in: lp, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: lp, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: lp, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: lp, args: ["config", "commit.gpgsign", "false"])
        // Real changes, not `--allow-empty`: a rebase drops commits whose
        // patch is empty, and the squash under test is a rebase.
        let file = local.appendingPathComponent("a.txt")
        for i in 1...3 {
            try "v\(i)\n".write(to: file, atomically: true, encoding: .utf8)
            _ = try await runner.run(in: lp, args: ["add", "a.txt"])
            _ = try await runner.run(in: lp, args: ["commit", "-q", "-m", "c\(i)"])
        }
        _ = try await runner.run(in: nil, args: [
            "-C", root.path, "init", "--bare", "-q", "-b", "main", "origin.git"
        ])
        _ = try await runner.run(in: lp, args: [
            "remote", "add", "origin", root.appendingPathComponent("origin.git").path
        ])
        _ = try await runner.run(in: lp, args: ["push", "-q", "-u", "origin", "main"])

        // Fold c2 + c3 into one, exactly as the Journal's Squash does.
        let hashes = try await git.log(repoPath: lp, count: 10, revisions: [])
        let c2 = try XCTUnwrap(hashes.first { $0.subject == "c2" })
        let c3 = try XCTUnwrap(hashes.first { $0.subject == "c3" })
        let result = try await git.squashRange(
            repoPath: lp,
            onto: "\(c2.hash)^",
            pickHash: c2.hash,
            selectedHashes: [c2.hash, c3.hash],
            lastSelectedHash: c3.hash,
            message: "c2 and c3",
            authorName: nil, authorEmail: nil, authorDateISO: nil
        )
        XCTAssertTrue(result.succeeded, result.stderr)

        let found = try await git.upstreamGap(repoPath: lp)
        let gap = try XCTUnwrap(found, "a tracked branch has an upstream to compare against")
        XCTAssertEqual(gap.ref, "origin/main")
        XCTAssertEqual(gap.incoming, [c2.hash, c3.hash], "the remote still holds what was squashed")

        let coordinator = CacheCoordinator(
            memoryCache: MemoryCache(), diskCache: DiskCache(), gitService: git
        )
        defer {
            let cleanup = coordinator
            Task { await cleanup.purgeDiskCache(forRepoPath: lp) }
        }
        coordinator.switchRepo(to: lp)
        let journal = JournalViewModel(coordinator: coordinator, git: git)
        await journal.load(force: true)

        // Still "HEAD Only" as far as the user and the Branches panel are
        // concerned — but both tips are in the graph.
        XCTAssertTrue(journal.refSelection.isHeadOnly)
        let subjects = journal.commits.map(\.subject)
        XCTAssertTrue(subjects.contains("c2 and c3"), "the squashed commit: \(subjects)")
        XCTAssertTrue(subjects.contains("c3"), "the remote's tip is graphed too: \(subjects)")

        let squashed = try XCTUnwrap(journal.commits.first { $0.subject == "c2 and c3" })
        let onRemote = try XCTUnwrap(journal.commits.first { $0.subject == "c3" })
        XCTAssertTrue(journal.isUnpushed(squashed))
        XCTAssertFalse(journal.isIncoming(squashed))
        XCTAssertTrue(journal.isIncoming(onRemote))
        XCTAssertFalse(journal.isUnpushed(onRemote))

        let divergence = try XCTUnwrap(journal.upstreamDivergence)
        XCTAssertEqual(divergence.ref, "origin/main")
        XCTAssertEqual(divergence.ahead, 1)
        XCTAssertEqual(divergence.behind, 2)

        // The remote's own commits are not HEAD's to rewrite, even though the
        // graph is nominally HEAD-only.
        XCTAssertTrue(journal.canChangeMessage(of: squashed))
        XCTAssertFalse(journal.canChangeMessage(of: onRemote))
        XCTAssertTrue(journal.canFixup(squashed))
        XCTAssertFalse(journal.canFixup(onRemote))
    }

    /// A branch with no upstream has nothing to diverge from, and the query
    /// must not fail or widen.
    func testNoUpstreamMeansNoGap() async throws {
        let runner = ProcessRunner()
        let git = GitService(runner: runner)
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-nogap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: root.path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: root.path, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: root.path, args: ["config", "commit.gpgsign", "false"])
        _ = try await runner.run(in: root.path, args: ["commit", "-q", "--allow-empty", "-m", "only"])

        let gap = try await git.upstreamGap(repoPath: root.path)
        XCTAssertNil(gap)
    }
}
