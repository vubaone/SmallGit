import XCTest
@testable import SmallGit

/// End-to-end coverage for changing a commit's message: `GitService`
/// rewrites the one commit and replays the rest untouched, and `AppState`
/// works out beforehand whether that rewrite lands on published history.
final class RewordCommitTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        let repo: String
        let root: URL
        /// Bare repo `repo` pushes to. Only set up by `makeSandbox(withRemote:)`.
        let origin: String
    }

    private func makeSandbox(withRemote: Bool = false) async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let git = GitService(runner: runner)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-reword-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let origin = root.appendingPathComponent("origin.git").path
        if withRemote {
            _ = try await runner.run(in: root.path, args: ["init", "-q", "--bare", "-b", "main", "origin.git"])
        }

        let repo = root.appendingPathComponent("repo").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main", "repo"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        if withRemote {
            _ = try await runner.run(in: repo, args: ["remote", "add", "origin", origin])
        }
        return Sandbox(runner: runner, git: git, repo: repo, root: root, origin: origin)
    }

    /// Overwrites `a.txt` so every commit carries a real change.
    @discardableResult
    private func commit(_ box: Sandbox, _ message: String) async throws -> String {
        let file = URL(fileURLWithPath: box.repo).appendingPathComponent("a.txt")
        try "\(message)\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await box.runner.run(in: box.repo, args: ["add", "a.txt"])
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-q", "-m", message])
        return try await show(box, "%H", ref: "HEAD")
    }

    /// One `git log -1` field for `ref`.
    private func show(_ box: Sandbox, _ format: String, ref: String) async throws -> String {
        let r = try await box.runner.run(
            in: box.repo,
            args: ["log", "-1", "--pretty=format:\(format)", ref]
        )
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func subjects(_ box: Sandbox) async throws -> [String] {
        let r = try await box.runner.run(in: box.repo, args: ["log", "--pretty=format:%s"])
        return r.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - GitService.rewordCommit

    /// The target commit gets the new message and keeps its tree; the
    /// commits on top of it are replayed unchanged apart from their hashes.
    func testRewordsAMiddleCommitAndLeavesTheRestAlone() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        _ = try await commit(box, "c1")
        let c2 = try await commit(box, "c2")
        _ = try await commit(box, "c3")

        let treeBefore = try await show(box, "%T", ref: c2)
        let authorBefore = try await show(box, "%an <%ae> %aI", ref: c2)

        let result = try await box.git.rewordCommit(
            repoPath: box.repo,
            onto: "\(c2)^",
            hash: c2,
            message: "c2 renamed\n\nwith a body"
        )
        XCTAssertTrue(result.succeeded, "reword rebase should succeed: \(result.stderr)")

        let after = try await subjects(box)
        XCTAssertEqual(after, ["c3", "c2 renamed", "c1"])

        // The reworded commit is the middle one — HEAD~1 after the replay.
        let message = try await show(box, "%B", ref: "HEAD~1")
        XCTAssertEqual(message, "c2 renamed\n\nwith a body")
        let treeAfter = try await show(box, "%T", ref: "HEAD~1")
        XCTAssertEqual(treeAfter, treeBefore,
            "the message is all that changes — the tree is the commit's own")
        let authorAfter = try await show(box, "%an <%ae> %aI", ref: "HEAD~1")
        XCTAssertEqual(authorAfter, authorBefore,
            "authorship and author date survive the rewrite")
        let hashAfter = try await show(box, "%H", ref: "HEAD~1")
        XCTAssertNotEqual(hashAfter, c2, "a rewritten commit is a new commit")
    }

    /// A repository's first commit has no parent, so the rebase has to be
    /// driven from `--root` rather than `<hash>^`.
    func testRewordsTheRootCommit() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let c1 = try await commit(box, "c1")
        _ = try await commit(box, "c2")

        let result = try await box.git.rewordCommit(
            repoPath: box.repo,
            onto: "--root",
            hash: c1,
            message: "c1 renamed"
        )
        XCTAssertTrue(result.succeeded, "root reword should succeed: \(result.stderr)")
        let after = try await subjects(box)
        XCTAssertEqual(after, ["c2", "c1 renamed"])
    }

    /// `git commit --amend` would fold whatever is staged into the commit.
    /// Changing a message must not commit the user's work behind their
    /// back, which is why this drives a rebase even for HEAD.
    func testRewordingHeadDoesNotSwallowStagedWork() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let c1 = try await commit(box, "c1")

        let staged = URL(fileURLWithPath: box.repo).appendingPathComponent("staged.txt")
        try "work in progress\n".write(to: staged, atomically: true, encoding: .utf8)
        _ = try await box.runner.run(in: box.repo, args: ["add", "staged.txt"])

        let result = try await box.git.rewordCommit(
            repoPath: box.repo,
            onto: "--root",
            hash: c1,
            message: "c1 renamed"
        )
        XCTAssertTrue(result.succeeded, "reword should succeed: \(result.stderr)")

        let subject = try await show(box, "%s", ref: "HEAD")
        XCTAssertEqual(subject, "c1 renamed")
        let files = try await box.runner.run(
            in: box.repo, args: ["ls-tree", "--name-only", "HEAD"]
        ).stdout
        XCTAssertFalse(files.contains("staged.txt"),
            "the staged file must not be swept into the reworded commit")
        let stagedText = try String(contentsOf: staged, encoding: .utf8)
        XCTAssertEqual(stagedText, "work in progress\n",
            "and it must still be there afterwards")
    }

    /// A hash that isn't on the branch is a caller error, not a rebase to
    /// attempt — the todo would replay every commit and amend none of them.
    func testRewordRejectsACommitThatIsNotOnTheBranch() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let c1 = try await commit(box, "c1")
        _ = try await commit(box, "c2")

        let result = try await box.git.rewordCommit(
            repoPath: box.repo,
            onto: "\(c1)^",             // c1 is the root, so this is unresolvable
            hash: String(repeating: "0", count: 40),
            message: "nope"
        )
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderr.contains("not on the current branch"), result.stderr)
        let after = try await subjects(box)
        XCTAssertEqual(after, ["c2", "c1"], "history is untouched")
    }

    /// The consequence the sheet warns about, checked end to end: once a
    /// pushed commit is reworded it is a different commit, so the branch
    /// is ahead of its upstream again and the journal's unpushed markers
    /// come back on. Nothing has to be told about this — it falls out of
    /// `@{upstream}..HEAD` — but it is the behaviour the warning promises.
    func testRewordingAPushedCommitLeavesTheBranchUnpushed() async throws {
        let box = try await makeSandbox(withRemote: true)
        defer { try? FileManager.default.removeItem(at: box.root) }
        let c1 = try await commit(box, "c1")
        _ = try await box.runner.run(in: box.repo, args: ["push", "-q", "-u", "origin", "main"])

        let clean = try await box.git.unpushedHashes(repoPath: box.repo)
        XCTAssertTrue(clean.isEmpty, "everything is on the remote before the reword")

        let result = try await box.git.rewordCommit(
            repoPath: box.repo,
            onto: "--root",
            hash: c1,
            message: "c1 renamed"
        )
        XCTAssertTrue(result.succeeded, result.stderr)

        let head = try await show(box, "%H", ref: "HEAD")
        let unpushed = try await box.git.unpushedHashes(repoPath: box.repo)
        XCTAssertEqual(unpushed, [head],
            "the reworded commit is a new commit the remote has never seen")
    }

    // MARK: - AppState.prepareReword

    /// Adding other refs to the graph must not hide Change Message on a
    /// published HEAD or its ancestors. Only the unrelated branch is excluded.
    @MainActor
    func testPublishedMessagesRemainEditableInAMultiRefGraph() async throws {
        let box = try await makeSandbox(withRemote: true)
        defer { try? FileManager.default.removeItem(at: box.root) }
        let base = try await commit(box, "base")
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "-b", "feature"])
        let ancestor = try await commit(box, "published ancestor")
        let head = try await commit(box, "published HEAD")
        _ = try await box.runner.run(in: box.repo, args: ["push", "-q", "-u", "origin", "feature"])
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "-b", "other", "main"])
        let unrelated = try await commit(box, "other branch")
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "feature"])

        let app = makeIsolatedAppState(git: box.git)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)
        defer {
            let coordinator = app.coordinator
            Task { await coordinator.purgeDiskCache(forRepoPath: box.repo) }
        }
        let journal = app.journalVM
        await journal.setRefSelection(JournalRefSelection(head: true, refs: ["main", "other"]))
        XCTAssertEqual(journal.refSelection.refs.count, 2)
        XCTAssertTrue(journal.unpushedHashes.isEmpty, "all of HEAD's history has been pushed")

        for hash in [head, ancestor, base] {
            let row = try XCTUnwrap(journal.commit(withID: hash))
            XCTAssertTrue(journal.canChangeMessage(of: row), row.subject)
        }
        let other = try XCTUnwrap(journal.commit(withID: unrelated))
        XCTAssertFalse(journal.canChangeMessage(of: other), "the other branch is not HEAD's to rewrite")

        let headRow = try XCTUnwrap(journal.commit(withID: head))
        await app.prepareReword(headRow)
        XCTAssertEqual(app.pendingReword?.originalMessage, "published HEAD")
        XCTAssertEqual(app.pendingReword?.rewritesPublishedCommits, true)
        XCTAssertEqual(app.pendingReword?.commitsReplayedOnTop, 0)

        // Selecting the checked-out branch by name is the same history.
        await journal.setRefSelection(JournalRefSelection(head: false, refs: ["feature", "other"]))
        XCTAssertTrue(journal.canChangeMessage(of: headRow))
        XCTAssertFalse(journal.canChangeMessage(of: other))

        journal.searchResults = JournalSearchResults(
            query: "published", scope: .message, commits: [headRow], failed: false
        )
        XCTAssertFalse(journal.canChangeMessage(of: headRow), "search results remain read-only")
    }

    /// The two questions the sheet warns on, answered against a real
    /// upstream: has this commit been pushed, and how much gets replayed.
    @MainActor
    func testPrepareRewordFlagsACommitThatIsAlreadyPushed() async throws {
        let box = try await makeSandbox(withRemote: true)
        defer { try? FileManager.default.removeItem(at: box.root) }
        _ = try await commit(box, "base")
        _ = try await commit(box, "pushed")
        _ = try await box.runner.run(in: box.repo, args: ["push", "-q", "-u", "origin", "main"])
        _ = try await commit(box, "local only")

        let app = makeIsolatedAppState(git: box.git)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)

        // Newest first: ["local only", "pushed", "base"].
        let log = try await box.git.log(repoPath: box.repo, count: 10)
        XCTAssertEqual(log.map(\.subject), ["local only", "pushed", "base"])

        await app.prepareReword(log[1])
        XCTAssertEqual(app.pendingReword?.rewritesPublishedCommits, true,
            "the pushed commit needs the warning")
        XCTAssertEqual(app.pendingReword?.commitsReplayedOnTop, 1)
        XCTAssertEqual(app.pendingReword?.originalMessage, "pushed")
        XCTAssertEqual(app.pendingReword?.onto, "\(log[1].hash)^")

        app.pendingReword = nil
        await app.prepareReword(log[0])
        XCTAssertEqual(app.pendingReword?.rewritesPublishedCommits, false,
            "a commit the remote has never seen needs no warning")
        XCTAssertEqual(app.pendingReword?.commitsReplayedOnTop, 0)
    }

    // MARK: - AppState.performReword

    @MainActor
    func testDecliningPublishedRewordLeavesLocalAndRemoteHistoryUntouched() async throws {
        let box = try await makeSandbox(withRemote: true)
        defer { try? FileManager.default.removeItem(at: box.root) }
        let original = try await commit(box, "published")
        _ = try await box.runner.run(in: box.repo, args: ["push", "-q", "-u", "origin", "main"])

        let platform = RecordingPlatformServices()
        let app = makeIsolatedAppState(git: box.git, platform: platform)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)
        let log = try await box.git.log(repoPath: box.repo, count: 10)
        let row = try XCTUnwrap(log.first)
        app.journalVM.selectOnly(row)
        await app.prepareReword(row)
        let plan = try XCTUnwrap(app.pendingReword)

        await app.performReword(plan, message: "renamed")

        let local = try await show(box, "%H", ref: "HEAD")
        let remote = try await box.git.currentHeadSHA(repoPath: box.origin)
        XCTAssertEqual(local, original, "declining must happen before any rewrite")
        XCTAssertEqual(remote, original)
        XCTAssertEqual(app.journalVM.selectedCommitID, original)
        XCTAssertEqual(platform.warnings.count, 1)
        XCTAssertEqual(platform.warnings.first?.primaryButton, "Change Message")
    }

    /// Both HEAD and an older published commit leave a fork immediately
    /// after the edit, until a separate force push or branch creation.
    @MainActor
    func testConfirmedPublishedRewordKeepsBothGraphTipsUntilUserActs() async throws {
        for editedIndex in [0, 1] {
            let box = try await makeSandbox(withRemote: true)
            defer { try? FileManager.default.removeItem(at: box.root) }
            _ = try await commit(box, "base")
            _ = try await commit(box, "middle")
            let publishedHead = try await commit(box, "tip")
            _ = try await box.runner.run(in: box.repo, args: ["push", "-q", "-u", "origin", "main"])

            let platform = RecordingPlatformServices()
            platform.confirmWarningAnswer = true
            let app = makeIsolatedAppState(git: box.git, platform: platform)
            app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
            app.coordinator.switchRepo(to: box.repo)
            defer {
                let coordinator = app.coordinator
                Task { await coordinator.purgeDiskCache(forRepoPath: box.repo) }
            }
            await app.journalVM.load(force: true)
            let row = app.journalVM.commits[editedIndex]
            app.journalVM.selectOnly(row)
            await app.prepareReword(row)
            let plan = try XCTUnwrap(app.pendingReword)
            XCTAssertTrue(plan.rewritesPublishedCommits)

            await app.performReword(plan, message: "renamed")

            let local = try await show(box, "%H", ref: "HEAD")
            let remote = try await box.git.currentHeadSHA(repoPath: box.origin)
            XCTAssertNotEqual(local, publishedHead)
            XCTAssertEqual(remote, publishedHead, "confirming the edit must not publish it")
            XCTAssertEqual(platform.warnings.count, 1, "no force-push prompt follows the edit")
            XCTAssertEqual(platform.warnings.first?.primaryButton, "Change Message")

            let journal = app.journalVM
            XCTAssertTrue(journal.refSelection.isHeadOnly, "the fork appears without ticking the remote")
            let localTip = try XCTUnwrap(journal.commit(withID: local))
            let remoteTip = try XCTUnwrap(journal.commit(withID: publishedHead))
            XCTAssertTrue(localTip.isHead)
            XCTAssertTrue(journal.isUnpushed(localTip))
            XCTAssertTrue(remoteTip.refList.contains("origin/main"))
            XCTAssertTrue(journal.isIncoming(remoteTip))
            XCTAssertTrue(journal.selectedCommitIDs.isEmpty)
            let divergence = try XCTUnwrap(journal.upstreamDivergence)
            XCTAssertEqual(divergence.ahead, editedIndex + 1)
            XCTAssertEqual(divergence.behind, editedIndex + 1)

            if editedIndex == 0 {
                let pushed = await app.push(force: true)
                XCTAssertTrue(pushed)
                let remoteAfterPush = try await box.git.currentHeadSHA(repoPath: box.origin)
                XCTAssertEqual(remoteAfterPush, local)
                XCTAssertNil(journal.upstreamDivergence)
            } else {
                await app.createBranch(name: "edited-message", from: local)
                let branch = try await show(box, "%H", ref: "edited-message")
                let remoteAfterBranch = try await box.git.currentHeadSHA(repoPath: box.origin)
                XCTAssertEqual(branch, local)
                XCTAssertEqual(remoteAfterBranch, publishedHead)
            }
        }
    }

    @MainActor
    func testUnpublishedRewordDoesNotAskForPublishedHistoryConfirmation() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        _ = try await commit(box, "local only")
        let platform = RecordingPlatformServices()
        let app = makeIsolatedAppState(git: box.git, platform: platform)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)
        defer {
            let coordinator = app.coordinator
            Task { await coordinator.purgeDiskCache(forRepoPath: box.repo) }
        }
        let log = try await box.git.log(repoPath: box.repo, count: 10)
        await app.prepareReword(try XCTUnwrap(log.first))
        let plan = try XCTUnwrap(app.pendingReword)
        XCTAssertFalse(plan.rewritesPublishedCommits)

        await app.performReword(plan, message: "renamed")

        let subject = try await show(box, "%s", ref: "HEAD")
        XCTAssertEqual(subject, "renamed")
        XCTAssertTrue(platform.warnings.isEmpty)
    }
}
