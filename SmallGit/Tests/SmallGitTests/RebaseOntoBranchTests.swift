import XCTest
@testable import SmallGit

/// Rebasing the current branch onto another line of history — "take that
/// branch as the base and put my commits on its end".
///
/// The Journal used to refuse this with "Rebase Interactive — this commit
/// isn't on HEAD", on the grounds that `<commit>..HEAD` would then resolve to
/// everything since the merge-base. It does, and that is the correct range:
/// it is exactly what `git rebase -i <commit>` replays. What was missing was
/// naming the direction, and checking the two things that really are wrong —
/// an empty range, and a merge git would flatten — against git rather than
/// against the journal's loaded window, which the range routinely outreaches.
final class RebaseOntoBranchTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        let repo: String
        let root: URL
    }

    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-rebaseonto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main", "repo"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        return Sandbox(runner: runner, git: GitService(runner: runner), repo: repo, root: root)
    }

    private func commit(_ box: Sandbox, _ name: String, _ subject: String) async throws {
        try "\(name)\n".write(
            to: URL(fileURLWithPath: box.repo).appendingPathComponent(name),
            atomically: true, encoding: .utf8
        )
        _ = try await box.runner.run(in: box.repo, args: ["add", "-A"])
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-qm", subject])
    }

    private func subjects(_ box: Sandbox, _ revisions: String...) async throws -> [String] {
        let result = try await box.runner.run(
            in: box.repo, args: ["log", "--pretty=%s"] + revisions
        )
        return result.stdout.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// `main` → `emoji` carries one commit of its own; `mywork` branches off
    /// `main` before that and carries two. Nothing on `mywork` is on `emoji`'s
    /// history and vice versa — the shape in the bug report.
    private func divergedBranches() async throws -> Sandbox {
        let box = try await makeSandbox()
        try await commit(box, "base.txt", "base")

        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "-b", "emoji"])
        try await commit(box, "e.txt", "[ZSOC-1318] Add EmojiStatus")

        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "main"])
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "-b", "mywork"])
        try await commit(box, "a.txt", "mine 1")
        try await commit(box, "b.txt", "mine 2")
        return box
    }

    // MARK: - The range

    /// The plan SmallGit writes has to be the plan git would have generated:
    /// the todo is overwritten wholesale via `GIT_SEQUENCE_EDITOR`, so a list
    /// that disagreed with git's would replay the wrong commits rather than
    /// fail.
    func testTheListedRangeMatchesGitsOwnTodo() async throws {
        let box = try await divergedBranches()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let listed = try await box.git.commitsToRebase(repoPath: box.repo, base: "emoji")
        XCTAssertEqual(listed.map(\.subject), ["mine 1", "mine 2"],
                       "oldest first, which is the order git's todo is written in")

        // What git itself would put in the todo, read by making the sequence
        // editor print it and abort.
        let generated = try await box.runner.run(
            in: box.repo,
            args: ["rebase", "-i", "emoji"],
            env: ["GIT_SEQUENCE_EDITOR": "cat"]
        )
        _ = try? await box.git.abortOperation(repoPath: box.repo, operation: .rebase)
        let picks = generated.combinedOutput
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("pick ") }
        XCTAssertEqual(picks.count, listed.count, "got: \(generated.combinedOutput)")
        for todo in listed {
            XCTAssertTrue(picks.contains { $0.contains(todo.shortHash) },
                          "git's todo is missing \(todo.shortHash) \(todo.subject)")
        }
    }

    func testNoMergesInALinearRange() async throws {
        let box = try await divergedBranches()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let merges = try await box.git.mergesToRebase(repoPath: box.repo, base: "emoji")
        XCTAssertTrue(merges.isEmpty)
    }

    /// git's own todo drops the merge and replays its side branch inline. Ours
    /// would have carried `pick <merge>`, a line git never writes — so the
    /// range has to be refused, and this is what notices it.
    func testAMergeInTheRangeIsFound() async throws {
        let box = try await divergedBranches()
        defer { try? FileManager.default.removeItem(at: box.root) }
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "-b", "side", "main"])
        try await commit(box, "s.txt", "side work")
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "mywork"])
        _ = try await box.runner.run(in: box.repo, args: ["merge", "--no-ff", "-m", "merge side", "side"])

        let merges = try await box.git.mergesToRebase(repoPath: box.repo, base: "emoji")
        XCTAssertEqual(merges.count, 1, "got \(merges)")

        // The plan itself leaves the merge out, exactly as git's todo does —
        // which is why something else has to notice it is there at all.
        let listed = try await box.git.commitsToRebase(repoPath: box.repo, base: "emoji")
        XCTAssertFalse(listed.contains { $0.subject == "merge side" })
        XCTAssertTrue(listed.contains { $0.subject == "side work" },
                      "and its side branch is inlined, which is the flattening")
    }

    // MARK: - The planner

    @MainActor
    func testThePlannerOpensWithTheCommitsToReplayOntoTheOtherBranch() async throws {
        let box = try await divergedBranches()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let app = makeIsolatedAppState(git: box.git)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)

        await app.startInteractiveRebase(onto: "emoji")

        let target = try XCTUnwrap(app.pendingInteractiveRebase)
        XCTAssertEqual(target.base, "emoji")
        XCTAssertEqual(target.initialTodo.map(\.subject), ["mine 1", "mine 2"])
        XCTAssertTrue(target.initialTodo.allSatisfy { $0.action == .pick })
    }

    /// A commit HEAD already sits on top of: git would fast-forward or do
    /// nothing, and the planner would be an empty list with a Start button.
    @MainActor
    func testNothingToReplayDoesNotOpenThePlanner() async throws {
        let box = try await divergedBranches()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let app = makeIsolatedAppState(git: box.git)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)

        await app.startInteractiveRebase(onto: "HEAD", display: "HEAD")

        XCTAssertNil(app.pendingInteractiveRebase)
        XCTAssertEqual(app.statusText, "Nothing to rebase — HEAD is already on top of HEAD")
    }

    @MainActor
    func testAMergeInTheRangeDoesNotOpenThePlanner() async throws {
        let box = try await divergedBranches()
        defer { try? FileManager.default.removeItem(at: box.root) }
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "-b", "side", "main"])
        try await commit(box, "s.txt", "side work")
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "mywork"])
        _ = try await box.runner.run(in: box.repo, args: ["merge", "--no-ff", "-m", "merge side", "side"])

        let app = makeIsolatedAppState(git: box.git)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)

        await app.startInteractiveRebase(onto: "emoji")

        XCTAssertNil(app.pendingInteractiveRebase, "the plan would have carried a pick for the merge")
        XCTAssertTrue(app.statusText.contains("would be flattened"), "got: \(app.statusText)")
    }

    // MARK: - Commits the base already has

    /// The reported bug. Branch B off A, let someone rewrite A's history and
    /// add to it, then rebase B onto A: A's original commits are still on B
    /// under their old SHAs, so `A..B` lists them as work to replay. git knows
    /// better — it matches by patch and skips them — and the plan has to say
    /// the same, or the user is made to drop A1, A2, A3 by hand and replays
    /// what A already has if they don't.
    private func rewrittenUpstream() async throws -> Sandbox {
        let box = try await makeSandbox()
        try await commit(box, "root.txt", "root")
        for n in 1...3 { try await commit(box, "a\(n).txt", "A\(n)") }

        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "-b", "B"])
        for n in 1...3 { try await commit(box, "b\(n).txt", "B\(n)") }

        // Someone force-pushes A: same three changes, new SHAs, plus more work.
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "main"])
        _ = try await box.runner.run(in: box.repo, args: ["reset", "-q", "--hard", "HEAD~3"])
        for n in 1...3 {
            // Byte-for-byte what `commit` wrote the first time: the whole point
            // is a commit with the same patch and a different SHA.
            try "a\(n).txt\n".write(
                to: URL(fileURLWithPath: box.repo).appendingPathComponent("a\(n).txt"),
                atomically: true, encoding: .utf8
            )
            _ = try await box.runner.run(in: box.repo, args: ["add", "-A"])
            _ = try await box.runner.run(
                in: box.repo,
                args: ["commit", "-qm", "A\(n)"],
                env: ["GIT_COMMITTER_DATE": "2030-01-0\(n)T00:00:00"]
            )
        }
        for n in 5...7 { try await commit(box, "a\(n).txt", "A\(n)") }
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "B"])
        return box
    }

    func testCommitsTheBaseAlreadyHasAreSkippedNotListed() async throws {
        let box = try await rewrittenUpstream()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let range = try await box.git.rebaseRange(repoPath: box.repo, base: "main")

        XCTAssertEqual(range.todo.map(\.subject), ["B1", "B2", "B3"],
                       "only my own work is a decision")
        XCTAssertEqual(range.alreadyOnBase.map(\.subject), ["A1", "A2", "A3"],
                       "kept so the sheet can say where they went")
    }

    /// The same list git would have written, checked against git itself —
    /// the todo is overwritten wholesale, so agreeing with git is the contract.
    func testTheSkippedListMatchesWhatGitSkips() async throws {
        let box = try await rewrittenUpstream()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let range = try await box.git.rebaseRange(repoPath: box.repo, base: "main")
        let generated = try await box.runner.run(
            in: box.repo, args: ["rebase", "-i", "main"], env: ["GIT_SEQUENCE_EDITOR": "cat"]
        )
        _ = try? await box.git.abortOperation(repoPath: box.repo, operation: .rebase)

        let picks = generated.combinedOutput
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("pick ") }
        XCTAssertEqual(picks.count, range.todo.count, "got: \(generated.combinedOutput)")
        for skipped in range.alreadyOnBase {
            XCTAssertFalse(picks.contains { $0.contains(skipped.shortHash) },
                           "git would not have picked \(skipped.shortHash) \(skipped.subject)")
        }
    }

    /// Running it: B lands on the rewritten A with three commits, not six, and
    /// no conflict from replaying changes that were already there.
    func testRunningItReplaysOnlyMyOwnCommits() async throws {
        let box = try await rewrittenUpstream()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let range = try await box.git.rebaseRange(repoPath: box.repo, base: "main")
        let result = try await box.git.runInteractiveRebase(
            repoPath: box.repo, onto: "main", todo: range.todo
        )
        XCTAssertTrue(result.succeeded, "got: \(result.combinedOutput)")

        let head = try await subjects(box, "HEAD")
        XCTAssertEqual(head, ["B3", "B2", "B1", "A7", "A6", "A5", "A3", "A2", "A1", "root"],
                       "my three commits on top of A's seven, with nothing replayed twice")
        let op = await box.git.inProgressOperation(repoPath: box.repo)
        XCTAssertNil(op)
    }

    /// A branch whose every commit is already upstream — the shape of a
    /// squash-merged PR — has no plan to offer, and the reason is not the
    /// same as "HEAD is already on top".
    @MainActor
    func testABranchAlreadyFullyOnTheBaseSaysSo() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try await commit(box, "root.txt", "root")
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "-b", "B"])
        try await commit(box, "b1.txt", "B1")
        // main moves first, *then* picks up the same change — the ordering
        // matters: cherry-picking straight onto the original parent can
        // reproduce the commit byte for byte, SHA included, and then there is
        // no duplicate to recognise.
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "main"])
        try await commit(box, "m.txt", "main moves on")
        _ = try await box.runner.run(in: box.repo, args: ["cherry-pick", "B"])
        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "B"])

        let app = makeIsolatedAppState(git: box.git)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)

        await app.startInteractiveRebase(onto: "main")

        XCTAssertNil(app.pendingInteractiveRebase)
        XCTAssertEqual(app.statusText,
                       "Nothing to rebase — main already has all 1 of these commits")
    }

    /// The ordinary case must not change: with nothing duplicated, the plan is
    /// still every commit since the two lines diverged.
    func testNothingIsSkippedWhenNothingIsDuplicated() async throws {
        let box = try await divergedBranches()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let range = try await box.git.rebaseRange(repoPath: box.repo, base: "emoji")
        XCTAssertEqual(range.todo.map(\.subject), ["mine 1", "mine 2"])
        XCTAssertTrue(range.alreadyOnBase.isEmpty)
    }

    /// And the "From Here" direction — base is an ancestor of HEAD — is
    /// untouched by the cherry-mark walk.
    func testAnAncestorBaseStillListsEverythingAfterIt() async throws {
        let box = try await divergedBranches()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let range = try await box.git.rebaseRange(repoPath: box.repo, base: "HEAD~2")
        XCTAssertEqual(range.todo.map(\.subject), ["mine 1", "mine 2"])
        XCTAssertTrue(range.alreadyOnBase.isEmpty)
    }

    // MARK: - What the sheet calls the base

    /// git lists decorations remote-first, so the naive "first ref" reads the
    /// upstream copy — `origin/social/…` — for a commit the user picked by its
    /// local branch.
    func testALocalBranchWinsOverItsUpstreamCopyAsTheLabel() {
        let commit = GitCommit(
            hash: "4618fa25d60", shortHash: "4618fa2", subject: "s",
            authorName: "T", authorEmail: "t@x", date: Date(),
            refs: "origin/social/ZSOC-1318-emoji, social/ZSOC-1318-emoji",
            parentHashes: []
        )
        XCTAssertEqual(
            commit.branchLabel(knownLocal: ["social/ZSOC-1318-emoji", "main"]),
            "social/ZSOC-1318-emoji"
        )
    }

    /// A remote-only branch is still a better label than a hash.
    func testARemoteOnlyBranchIsStillUsed() {
        let commit = GitCommit(
            hash: "h", shortHash: "h", subject: "s",
            authorName: "T", authorEmail: "t@x", date: Date(),
            refs: "origin/feature", parentHashes: []
        )
        XCTAssertEqual(commit.branchLabel(knownLocal: ["main"]), "origin/feature")
    }

    /// Tags name a point, not the line of work being rebased onto, and a bare
    /// commit has no name at all — both fall back to the short hash.
    func testTagsAndBareCommitsHaveNoBranchLabel() {
        func made(_ refs: String) -> GitCommit {
            GitCommit(
                hash: "h", shortHash: "h", subject: "s",
                authorName: "T", authorEmail: "t@x", date: Date(),
                refs: refs, parentHashes: []
            )
        }
        XCTAssertNil(made("tag: v1.2.0").branchLabel(knownLocal: []))
        XCTAssertNil(made("").branchLabel(knownLocal: []))
        XCTAssertNil(made("HEAD").branchLabel(knownLocal: []))
        XCTAssertEqual(made("HEAD -> main").branchLabel(knownLocal: ["main"]), "main")
    }

    // MARK: - Running it

    /// The whole point, end to end: `mywork`'s commits come off `main` and land
    /// on `emoji`'s tip, in order, with `emoji` itself untouched.
    func testRunningItPutsMyCommitsOnTheOtherBranchesTip() async throws {
        let box = try await divergedBranches()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let plan = try await box.git.commitsToRebase(repoPath: box.repo, base: "emoji")
        let result = try await box.git.runInteractiveRebase(
            repoPath: box.repo, onto: "emoji", todo: plan
        )
        XCTAssertTrue(result.succeeded, "got: \(result.combinedOutput)")

        let head = try await subjects(box, "HEAD")
        XCTAssertEqual(
            head,
            ["mine 2", "mine 1", "[ZSOC-1318] Add EmojiStatus", "base"],
            "my work replayed on top of emoji, in order"
        )
        let emoji = try await subjects(box, "emoji")
        XCTAssertEqual(emoji,
                       ["[ZSOC-1318] Add EmojiStatus", "base"],
                       "the branch used as the base is not rewritten")
        let op = await box.git.inProgressOperation(repoPath: box.repo)
        XCTAssertNil(op)
    }

    /// The plan is editable in the same pass — dropping one of my commits on
    /// the way over has to work, or "interactive" means nothing here.
    func testThePlanIsHonouredWhileRebasingOnto() async throws {
        let box = try await divergedBranches()
        defer { try? FileManager.default.removeItem(at: box.root) }

        var plan = try await box.git.commitsToRebase(repoPath: box.repo, base: "emoji")
        plan[0].action = .drop
        let result = try await box.git.runInteractiveRebase(
            repoPath: box.repo, onto: "emoji", todo: plan
        )
        XCTAssertTrue(result.succeeded, "got: \(result.combinedOutput)")

        let head = try await subjects(box, "HEAD")
        XCTAssertEqual(head, ["mine 2", "[ZSOC-1318] Add EmojiStatus", "base"])
    }
}
