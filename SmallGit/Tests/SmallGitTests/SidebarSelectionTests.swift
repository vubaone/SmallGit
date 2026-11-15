import XCTest
@testable import SmallGit

/// The Branches panel selects a set of rows, and a right-click acts on all of
/// them. Turning that set back into branches is the step everything else
/// depends on: a folder stands for its whole subtree, and a batch delete has
/// to leave the checked-out branch alone.
@MainActor
final class SidebarSelectionTests: XCTestCase {

    private let branches: [GitBranch] = [
        GitBranch(name: "main", upstream: "origin/main"),
        GitBranch(name: "social/ZSOC-1110-banner", upstream: nil),
        GitBranch(name: "social/ZSOC-1325-emoji", upstream: "origin/social/ZSOC-1325-emoji", isHead: true),
        GitBranch(name: "vubl-main", upstream: nil)
    ]

    private func makeViewModel() -> BranchesViewModel {
        let vm = BranchesViewModel(coordinator: CacheCoordinator())
        vm.localBranches = branches
        vm.remoteBranches = [
            GitBranch(name: "origin/main", isRemote: true, remoteName: "origin")
        ]
        vm.tags = ["v1.0"]
        vm.currentBranch = "social/ZSOC-1325-emoji"
        return vm
    }

    func testABranchSelectionResolvesToThatBranch() {
        let vm = makeViewModel()

        let resolved = vm.branches(in: [.branch("vubl-main")])

        XCTAssertEqual(resolved.map(\.name), ["vubl-main"])
    }

    func testAFolderStandsForEverythingUnderIt() {
        let vm = makeViewModel()

        let resolved = vm.branches(in: [.folder("Local Branches/social")])

        XCTAssertEqual(
            resolved.map(\.name),
            ["social/ZSOC-1110-banner", "social/ZSOC-1325-emoji"]
        )
    }

    /// Selecting a folder and a branch inside it is one gesture away — ⌘-click
    /// the folder, then the branch — and it must not mean deleting that
    /// branch twice.
    func testAFolderAndABranchInsideItCountOnce() {
        let vm = makeViewModel()

        let resolved = vm.branches(in: [
            .folder("Local Branches/social"),
            .branch("social/ZSOC-1110-banner")
        ])

        XCTAssertEqual(
            resolved.map(\.name),
            ["social/ZSOC-1110-banner", "social/ZSOC-1325-emoji"]
        )
    }

    /// HEAD, tags, stashes and submodules are selectable rows, but none of
    /// them names a branch: a batch action has to skip them rather than
    /// guessing.
    func testRowsThatAreNotBranchesResolveToNothing() {
        let vm = makeViewModel()

        let resolved = vm.branches(in: [.head, .tag("v1.0"), .stash(0), .submodule("Vendor/lib")])

        XCTAssertTrue(resolved.isEmpty)
    }

    func testARemoteBranchRowResolvesFromTheRemoteTree() {
        let vm = makeViewModel()

        let resolved = vm.branches(in: [.branch("origin/main")])

        XCTAssertEqual(resolved.map(\.name), ["origin/main"])
        XCTAssertTrue(resolved.allSatisfy(\.isRemote))
    }

    /// The set has no order of its own, and "Delete 3 Branches" has to mean
    /// the same three in the same sequence every time it is invoked.
    func testMenuOrderIsStableAndGroupedByKind() {
        let items: Set<SidebarSelection> = [
            .tag("v1.0"), .branch("main"), .head, .folder("Local Branches/social")
        ]

        XCTAssertEqual(
            items.sortedForMenu,
            [.head, .branch("main"), .folder("Local Branches/social"), .tag("v1.0")]
        )
    }

    /// The half that runs against real git: a batch delete has to remove every
    /// branch in it, and the request has to drop the two kinds of row a
    /// dragged selection picks up by accident — the checked-out branch and
    /// anything remote.
    func testBatchDeleteRemovesEveryBranchAndSparesTheCheckedOutOne() async throws {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-batch-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = try await runner.run(in: path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: path, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: path, args: ["config", "commit.gpgsign", "false"])
        _ = try await runner.run(in: path, args: ["commit", "-q", "--allow-empty", "-m", "first"])
        for name in ["spike/one", "spike/two", "spike/three"] {
            _ = try await runner.run(in: path, args: ["branch", name])
        }

        let app = makeIsolatedAppState(git: GitService(runner: runner))
        await app.addRepository(at: path)
        let repo = try XCTUnwrap(app.allRepositories.first { $0.path == path })
        await app.selectRepo(repo)

        let all = app.branchesVM.localBranches
        XCTAssertEqual(all.count, 4, "main plus three spikes")

        // Every local branch, the checked-out one included.
        await app.requestBranchDeletion(all)
        let target = try XCTUnwrap(app.branchPendingDelete)
        XCTAssertEqual(
            target.branches.map(\.name).sorted(),
            ["spike/one", "spike/three", "spike/two"],
            "main is checked out, so it is not up for deletion"
        )
        XCTAssertTrue(
            target.needingForce.isEmpty,
            "each spike points at main's commit, so a plain -d takes them"
        )

        let report = await app.confirmBranchDeletion(target.branches, force: false)

        XCTAssertTrue(report.isComplete, "git refused: \(report.failed.map(\.message))")
        XCTAssertEqual(report.deleted.count, 3)
        XCTAssertNil(app.branchPendingDelete, "a complete delete closes the sheet")

        await app.branchesVM.forceRefresh()
        XCTAssertEqual(app.branchesVM.localBranches.map(\.name), ["main"])
    }
}
