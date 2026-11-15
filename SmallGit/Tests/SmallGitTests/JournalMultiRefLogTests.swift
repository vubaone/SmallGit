import XCTest
@testable import SmallGit

/// The journal graphing several refs at once, against a real repo:
/// ticking a branch has to add its commits, and only its commits.
@MainActor
final class JournalMultiRefLogTests: XCTestCase {

    private var runner = ProcessRunner()

    /// main: base → main1.  feature: base → feat1 → feat2 (not merged).
    private func makeRepo() async throws -> (path: String, root: URL) {
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-multiref-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: root.path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: root.path, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: root.path, args: ["config", "commit.gpgsign", "false"])

        _ = try await runner.run(in: root.path, args: ["commit", "-q", "--allow-empty", "-m", "base"])
        _ = try await runner.run(in: root.path, args: ["checkout", "-q", "-b", "feature"])
        _ = try await runner.run(in: root.path, args: ["commit", "-q", "--allow-empty", "-m", "feat1"])
        _ = try await runner.run(in: root.path, args: ["commit", "-q", "--allow-empty", "-m", "feat2"])
        _ = try await runner.run(in: root.path, args: ["tag", "-a", "v1", "-m", "v1"])
        _ = try await runner.run(in: root.path, args: ["checkout", "-q", "main"])
        _ = try await runner.run(in: root.path, args: ["commit", "-q", "--allow-empty", "-m", "main1"])
        return (root.path, root)
    }

    private func makeVM(_ path: String) -> JournalViewModel {
        let coord = CacheCoordinator()
        coord.switchRepo(to: path)
        return JournalViewModel(coordinator: coord)
    }

    func testHeadOnlyGraphsTheCheckedOutBranch() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let vm = makeVM(repo.path)
        await vm.load()
        XCTAssertEqual(vm.commits.map(\.subject), ["main1", "base"],
            "the feature branch isn't reachable from HEAD")
    }

    func testTickingABranchAddsItsCommits() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let vm = makeVM(repo.path)
        await vm.load()
        await vm.setRef("feature", checked: true)

        XCTAssertEqual(Set(vm.commits.map(\.subject)), ["main1", "feat2", "feat1", "base"],
            "the graph is the union of HEAD and the ticked branch")
        XCTAssertFalse(vm.refSelection.isHeadOnly)
    }

    func testUntickingHeadLeavesOnlyTheTickedRef() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let vm = makeVM(repo.path)
        await vm.setRefSelection(JournalRefSelection(head: false, refs: ["feature"]))
        XCTAssertEqual(vm.commits.map(\.subject), ["feat2", "feat1", "base"],
            "main1 is on HEAD only, which is no longer ticked")
        XCTAssertEqual(vm.branchFilter, "feature",
            "one ref and no HEAD is still the nameable 'pinned to a branch' state")
    }

    func testATagCanBeGraphedToo() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let vm = makeVM(repo.path)
        await vm.setRefSelection(JournalRefSelection(head: false, refs: ["v1"]))
        XCTAssertEqual(vm.commits.map(\.subject), ["feat2", "feat1", "base"])
    }

    func testNothingTickedShowsAnEmptyJournalRatherThanHead() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let vm = makeVM(repo.path)
        await vm.load()
        XCTAssertFalse(vm.commits.isEmpty)

        await vm.setRefSelection(JournalRefSelection(head: false, refs: []))
        XCTAssertTrue(vm.commits.isEmpty,
            "unticking everything must not fall back to HEAD's log")
        XCTAssertFalse(vm.hasMore)

        // Paging must stay quiet too — there is nothing to page through.
        await vm.loadMore()
        XCTAssertTrue(vm.commits.isEmpty)
    }

    /// A ref deleted while it was ticked would otherwise fail the whole
    /// query — `--ignore-missing` keeps the rest of the graph. Asserted
    /// against the service directly: the view model's answer can come
    /// from a cache entry written before the deletion.
    func testADeletedRefDoesNotBreakTheGraph() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }

        _ = try await runner.run(in: repo.path, args: ["branch", "-D", "feature"])
        _ = try await runner.run(in: repo.path, args: ["tag", "-d", "v1"])

        let commits = try await GitService.shared.log(
            repoPath: repo.path, count: 100, revisions: ["HEAD", "feature"]
        )
        XCTAssertEqual(commits.map(\.subject), ["main1", "base"],
            "the deleted ref is skipped, HEAD still graphs")
    }

    /// The `--stdin` path, taken when a selection is too big for argv.
    /// It can't use `--ignore-missing`, so it relies on pruning.
    func testAVeryLargeSelectionStillGraphs() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }

        // One very long ref name, repeated until the joined revisions
        // pass the inline limit — the threshold is about total bytes, so
        // this exercises the same branch of the code as a repo with
        // thousands of ticked refs, without creating thousands of them.
        let long = "topic/" + String(repeating: "a", count: 200)
        _ = try await runner.run(in: repo.path, args: ["branch", long, "feature"])
        let names = Array(repeating: long, count: 600)
        let commits = try await GitService.shared.log(
            repoPath: repo.path, count: 100, revisions: names
        )
        XCTAssertEqual(Set(commits.map(\.subject)), ["feat2", "feat1", "base"],
            "every one of those branches points at feature's tip")
    }

    func testPruningDropsTheDeletedRefAndReloads() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let vm = makeVM(repo.path)
        await vm.setRefSelection(JournalRefSelection(head: true, refs: ["feature", "v1"]))
        await vm.pruneRefSelection(keeping: ["main", "v1"])
        XCTAssertEqual(vm.refSelection.refs, ["v1"])
        XCTAssertTrue(vm.refSelection.head)
    }

    /// Two selections must not share a cache entry, or switching between
    /// them shows the other one's commits.
    func testSwitchingSelectionRefetchesRatherThanReusingTheCache() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let vm = makeVM(repo.path)
        await vm.load()
        let headOnly = vm.commits.map(\.subject)

        await vm.setRef("feature", checked: true)
        XCTAssertEqual(vm.commits.count, 4)

        await vm.setRef("feature", checked: false)
        XCTAssertEqual(vm.commits.map(\.subject), headOnly,
            "back to HEAD's own log, not the four-commit union")
    }

    func testTheBranchContextMenusLogStillPinsToOneBranch() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let vm = makeVM(repo.path)
        await vm.setBranchFilter("feature")
        XCTAssertEqual(vm.refSelection, JournalRefSelection(head: false, refs: ["feature"]))
        XCTAssertEqual(vm.commits.map(\.subject), ["feat2", "feat1", "base"])

        await vm.setBranchFilter(nil)
        XCTAssertTrue(vm.refSelection.isHeadOnly)
        XCTAssertEqual(vm.commits.map(\.subject), ["main1", "base"])
    }
}
