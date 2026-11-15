import XCTest
@testable import SmallGit

/// Pulling with a dirty working tree. git refuses outright unless the
/// changes are out of the way, so the pull stashes them for the duration
/// and puts them back — and keeps the stash when they won't go back.
final class PullAutostashTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        let mine: String        // the clone under test
        let theirs: String      // a collaborator's clone
        let root: URL
    }

    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-autostash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let origin = root.appendingPathComponent("origin.git").path
        _ = try await runner.run(in: root.path, args: ["init", "--bare", "-q", "-b", "main", "origin.git"])

        let seed = root.appendingPathComponent("seed").path
        _ = try await runner.run(in: root.path, args: ["clone", "-q", "file://\(origin)", "seed"])
        try await identify(runner, seed)
        // Ten lines, not three: a stash reapply is a three-way merge, and
        // in a tiny file two edits a line apart land inside one another's
        // diff context and conflict for reasons that have nothing to do
        // with what's being tested.
        try Self.file(line2: "line2", line9: "line9").write(
            to: URL(fileURLWithPath: seed).appendingPathComponent("f.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try await runner.run(in: seed, args: ["add", "f.txt"])
        _ = try await runner.run(in: seed, args: ["commit", "-q", "-m", "base"])
        _ = try await runner.run(in: seed, args: ["push", "-q", "origin", "main"])

        let mine = root.appendingPathComponent("mine").path
        let theirs = root.appendingPathComponent("theirs").path
        _ = try await runner.run(in: root.path, args: ["clone", "-q", "file://\(origin)", "mine"])
        _ = try await runner.run(in: root.path, args: ["clone", "-q", "file://\(origin)", "theirs"])
        try await identify(runner, mine)
        try await identify(runner, theirs)

        return Sandbox(runner: runner, git: GitService(runner: runner),
                       mine: mine, theirs: theirs, root: root)
    }

    /// The fixture file: ten numbered lines with two of them swappable, so
    /// a test can put an edit near the top and another near the bottom.
    private static func file(line2: String, line9: String) -> String {
        var lines = (1...10).map { "line\($0)" }
        lines[1] = line2
        lines[8] = line9
        return lines.joined(separator: "\n") + "\n"
    }

    private func identify(_ runner: ProcessRunner, _ repo: String) async throws {
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
    }

    /// The collaborator rewrites line 2 and pushes.
    private func pushUpstreamChange(_ s: Sandbox) async throws {
        try Self.file(line2: "UPSTREAM", line9: "line9").write(
            to: URL(fileURLWithPath: s.theirs).appendingPathComponent("f.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try await s.runner.run(in: s.theirs, args: ["commit", "-qam", "upstream"])
        _ = try await s.runner.run(in: s.theirs, args: ["push", "-q", "origin", "main"])
    }

    private func write(_ text: String, to file: String, in repo: String) throws {
        try text.write(
            to: URL(fileURLWithPath: repo).appendingPathComponent(file),
            atomically: true, encoding: .utf8
        )
    }

    private func read(_ file: String, in repo: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: repo).appendingPathComponent(file), encoding: .utf8)
    }

    private func stashList(_ s: Sandbox) async throws -> String {
        try await s.runner.run(in: s.mine, args: ["stash", "list"]).stdout
    }

    // MARK: - The reported failure

    /// "error: cannot pull with rebase: You have unstaged changes." —
    /// which is the ordinary state of a working tree.
    func testPullWithADirtyTreeNoLongerRefuses() async throws {
        let s = try await makeSandbox(); defer { try? FileManager.default.removeItem(at: s.root) }
        try await pushUpstreamChange(s)
        try write("scratch\n", to: "notes.txt", in: s.mine)
        _ = try await s.runner.run(in: s.mine, args: ["add", "notes.txt"])
        try write(Self.file(line2: "line2", line9: "MINE"), to: "f.txt", in: s.mine)

        let result = try await s.git.pull(repoPath: s.mine, rebase: true)
        XCTAssertTrue(result.succeeded, "pull refused a dirty tree: \(result.combinedOutput)")
        XCTAssertEqual(GitOutputParser.autostashOutcome(in: result.combinedOutput), .applied)
    }

    func testLocalChangesComeBackAfterThePull() async throws {
        let s = try await makeSandbox(); defer { try? FileManager.default.removeItem(at: s.root) }
        try await pushUpstreamChange(s)
        try write("work in progress\n", to: "notes.txt", in: s.mine)
        _ = try await s.runner.run(in: s.mine, args: ["add", "notes.txt"])

        _ = try await s.git.pull(repoPath: s.mine, rebase: true)

        XCTAssertEqual(try read("notes.txt", in: s.mine), "work in progress\n",
            "the stashed change has to be back in the working tree")
        let stashes = try await stashList(s)
        XCTAssertTrue(stashes.isEmpty, "a clean reapply must not leave a stash behind")
        XCTAssertTrue(try read("f.txt", in: s.mine).contains("UPSTREAM"),
            "and the pull itself has to have landed")
    }

    /// The case SmartGit leaves for the user: the changes can't go back on
    /// top of what was pulled, so they stay in the stash.
    func testAConflictingReapplyKeepsTheStash() async throws {
        let s = try await makeSandbox(); defer { try? FileManager.default.removeItem(at: s.root) }
        try await pushUpstreamChange(s)
        // Same line the upstream commit rewrote.
        try write(Self.file(line2: "MINE", line9: "line9"), to: "f.txt", in: s.mine)

        let result = try await s.git.pull(repoPath: s.mine, rebase: true)
        XCTAssertTrue(result.succeeded,
            "git exits 0 here — the pull worked, only the reapply didn't")
        XCTAssertEqual(GitOutputParser.autostashOutcome(in: result.combinedOutput), .conflicted)

        let stashes = try await stashList(s)
        XCTAssertTrue(stashes.contains("autostash"),
            "the changes must be recoverable, not dropped")
        let status = try await s.runner.run(in: s.mine, args: ["status", "--porcelain"])
        XCTAssertTrue(status.stdout.contains("UU f.txt"),
            "the conflict is in the working tree for the user to resolve")
        XCTAssertTrue(try read("f.txt", in: s.mine).contains("MINE"),
            "their edit is one side of the conflict, not lost")
    }

    func testACleanTreePullsWithNoStashAtAll() async throws {
        let s = try await makeSandbox(); defer { try? FileManager.default.removeItem(at: s.root) }
        try await pushUpstreamChange(s)

        let result = try await s.git.pull(repoPath: s.mine, rebase: true)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(GitOutputParser.autostashOutcome(in: result.combinedOutput), .none,
            "nothing to stash means nothing to report")
        let stashes = try await stashList(s)
        XCTAssertTrue(stashes.isEmpty)
    }

    func testMergeModePullAlsoAutostashes() async throws {
        let s = try await makeSandbox(); defer { try? FileManager.default.removeItem(at: s.root) }
        try await pushUpstreamChange(s)
        try write("work in progress\n", to: "notes.txt", in: s.mine)
        _ = try await s.runner.run(in: s.mine, args: ["add", "notes.txt"])

        let result = try await s.git.pull(repoPath: s.mine, rebase: false)
        XCTAssertTrue(result.succeeded, result.combinedOutput)
        XCTAssertEqual(try read("notes.txt", in: s.mine), "work in progress\n")
    }

    func testAutostashCanBeTurnedOffToGetGitsOwnRefusal() async throws {
        let s = try await makeSandbox(); defer { try? FileManager.default.removeItem(at: s.root) }
        try await pushUpstreamChange(s)
        try write(Self.file(line2: "MINE", line9: "line9"), to: "f.txt", in: s.mine)

        let result = try await s.git.pull(repoPath: s.mine, rebase: true, autostash: false)
        XCTAssertFalse(result.succeeded, "this is the behaviour autostash replaces")
    }

    /// The upstream was deleted on the remote (merged, then removed with its
    /// MR). The pull fails — "no such ref was fetched" — but it must still
    /// prune, or the branch keeps claiming an upstream that isn't there.
    func testPullOnABranchWhoseUpstreamWasDeletedMarksItGone() async throws {
        let s = try await makeSandbox(); defer { try? FileManager.default.removeItem(at: s.root) }
        _ = try await s.runner.run(in: s.mine, args: ["checkout", "-q", "-b", "feature"])
        _ = try await s.runner.run(in: s.mine, args: ["push", "-q", "-u", "origin", "feature"])
        _ = try await s.runner.run(in: s.theirs, args: ["push", "-q", "origin", "--delete", "feature"])

        let result = try await s.git.pull(repoPath: s.mine, rebase: false)
        XCTAssertFalse(result.succeeded)

        let branches = try await s.git.localBranches(repoPath: s.mine)
        let feature = try XCTUnwrap(branches.first { $0.name == "feature" })
        XCTAssertTrue(feature.upstreamGone, "expected [gone], got \(feature.upstreamTrack ?? "nil")")
    }

    // MARK: - Merge and rebase

    /// A local branch to merge or rebase onto, one commit ahead on the
    /// same file the upstream test uses.
    private func makeFeatureBranch(_ s: Sandbox) async throws {
        _ = try await s.runner.run(in: s.mine, args: ["checkout", "-q", "-b", "feature"])
        try write(Self.file(line2: "FEATURE", line9: "line9"), to: "f.txt", in: s.mine)
        _ = try await s.runner.run(in: s.mine, args: ["commit", "-qam", "feature work"])
        _ = try await s.runner.run(in: s.mine, args: ["checkout", "-q", "main"])
    }

    func testMergeWithADirtyTreeStashesAndPutsItBack() async throws {
        let s = try await makeSandbox(); defer { try? FileManager.default.removeItem(at: s.root) }
        try await makeFeatureBranch(s)
        // A tracked file, edited but not committed: this is what git
        // refuses to work over. An untracked file never blocks anything,
        // so it would prove nothing here.
        try write(Self.file(line2: "line2", line9: "MINE-line9"), to: "f.txt", in: s.mine)

        let result = try await s.git.merge(repoPath: s.mine, branch: "feature")
        XCTAssertTrue(result.succeeded, result.combinedOutput)
        XCTAssertEqual(GitOutputParser.autostashOutcome(in: result.combinedOutput), .applied,
            "the merge had to stash the edit and put it back")
        let merged = try read("f.txt", in: s.mine)
        XCTAssertTrue(merged.contains("FEATURE"), "the merge landed")
        XCTAssertTrue(merged.contains("MINE-line9"), "and the uncommitted edit survived it")
        let stashes = try await stashList(s)
        XCTAssertTrue(stashes.isEmpty, "a clean reapply leaves no stash")
    }

    func testMergeKeepsTheStashWhenTheChangesWontGoBack() async throws {
        let s = try await makeSandbox(); defer { try? FileManager.default.removeItem(at: s.root) }
        try await makeFeatureBranch(s)
        try write(Self.file(line2: "MINE", line9: "line9"), to: "f.txt", in: s.mine)

        let result = try await s.git.merge(repoPath: s.mine, branch: "feature")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(GitOutputParser.autostashOutcome(in: result.combinedOutput), .conflicted)
        let stashes = try await stashList(s)
        XCTAssertTrue(stashes.contains("autostash"))
    }

    func testRebaseWithADirtyTreeStashesAndPutsItBack() async throws {
        let s = try await makeSandbox(); defer { try? FileManager.default.removeItem(at: s.root) }
        try await pushUpstreamChange(s)
        _ = try await s.runner.run(in: s.mine, args: ["fetch", "-q"])
        // Line 9, while upstream moved line 2 — dirty enough to block the
        // rebase, far enough away to reapply cleanly.
        try write(Self.file(line2: "line2", line9: "MINE-line9"), to: "f.txt", in: s.mine)

        let result = try await s.git.rebase(repoPath: s.mine, onto: "origin/main")
        XCTAssertTrue(result.succeeded, result.combinedOutput)
        XCTAssertEqual(GitOutputParser.autostashOutcome(in: result.combinedOutput), .applied)
        let after = try read("f.txt", in: s.mine)
        XCTAssertTrue(after.contains("UPSTREAM"), "the rebase landed")
        XCTAssertTrue(after.contains("MINE-line9"), "and the uncommitted edit survived it")
    }

    /// The squash path drives `rebase -i` through a scripted sequence
    /// editor; the flag has to survive that too.
    func testSquashRangeAutostashesAsWell() async throws {
        let s = try await makeSandbox(); defer { try? FileManager.default.removeItem(at: s.root) }
        for i in 1...2 {
            try write("commit \(i)\n", to: "c\(i).txt", in: s.mine)
            _ = try await s.runner.run(in: s.mine, args: ["add", "c\(i).txt"])
            _ = try await s.runner.run(in: s.mine, args: ["commit", "-qm", "c\(i)"])
        }
        let head = try await s.runner.run(in: s.mine, args: ["rev-parse", "HEAD"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = try await s.runner.run(in: s.mine, args: ["rev-parse", "HEAD~1"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try write(Self.file(line2: "line2", line9: "MINE-line9"), to: "f.txt", in: s.mine)

        let result = try await s.git.squashRange(
            repoPath: s.mine,
            onto: "HEAD~2",
            pickHash: parent,
            selectedHashes: [parent, head],
            lastSelectedHash: head,
            message: "squashed",
            authorName: nil, authorEmail: nil, authorDateISO: nil
        )
        XCTAssertTrue(result.succeeded, result.combinedOutput)
        XCTAssertEqual(GitOutputParser.autostashOutcome(in: result.combinedOutput), .applied)
        XCTAssertTrue(try read("f.txt", in: s.mine).contains("MINE-line9"),
            "the uncommitted edit has to survive the rewrite")
        let log = try await s.runner.run(in: s.mine, args: ["log", "-1", "--pretty=%s"])
        XCTAssertEqual(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "squashed")
    }

    // MARK: - Reading the outcome

    func testOutcomeParsingUsesGitsOwnWording() {
        XCTAssertEqual(GitOutputParser.autostashOutcome(in: """
            Updating 22f4db5..a9d123c
            Created autostash: 48e487f
            Fast-forward
            Applied autostash.
            """), .applied)

        XCTAssertEqual(GitOutputParser.autostashOutcome(in: """
            Created autostash: 0f652fc
            Applying autostash resulted in conflicts.
            Your changes are safe in the stash.
            You can run "git stash pop" or "git stash drop" at any time.
            """), .conflicted)

        XCTAssertEqual(GitOutputParser.autostashOutcome(in: """
            Updating 22f4db5..a9d123c
            Fast-forward
             f.txt | 2 +-
            """), .none)
    }
}
