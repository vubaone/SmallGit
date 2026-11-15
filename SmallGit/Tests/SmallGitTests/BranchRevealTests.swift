import XCTest
@testable import SmallGit

/// Switching repository asks the Branches panel to scroll the checked-out
/// branch into view. The row it has to scroll to may sit inside folders that
/// are shut, so "reveal" is two things: open the way down, and name the row.
@MainActor
final class BranchRevealTests: XCTestCase {

    private let branches: [GitBranch] = [
        GitBranch(name: "main", upstream: "origin/main"),
        GitBranch(name: "social/ZSOC-1324/avatar", upstream: nil, isHead: true)
    ]

    private func makeViewModel() -> BranchesViewModel {
        let vm = BranchesViewModel(coordinator: CacheCoordinator())
        vm.localBranches = branches
        vm.currentBranch = "social/ZSOC-1324/avatar"
        return vm
    }

    func testRowIDMatchesTheIDTheTreeBuilds() {
        let tree = BranchTreeNode.build(from: branches, root: BranchesViewModel.localRoot)
        let social = tree.children.first { $0.name == "social" }
        let ticket = social?.children.first { $0.name == "ZSOC-1324" }
        let leaf = ticket?.children.first { $0.branch != nil }

        XCTAssertEqual(
            leaf?.id,
            BranchTreeNode.rowID(
                for: "social/ZSOC-1324/avatar",
                root: BranchesViewModel.localRoot
            )
        )
    }

    func testRevealOpensEveryFolderAboveTheBranch() {
        let vm = makeViewModel()
        vm.localExpanded = false

        let rowID = vm.revealLocalBranch("social/ZSOC-1324/avatar")

        XCTAssertTrue(vm.localExpanded)
        XCTAssertEqual(rowID, "Local Branches/social/ZSOC-1324/avatar")
        XCTAssertEqual(
            vm.expandedFolders,
            ["Local Branches/social", "Local Branches/social/ZSOC-1324"]
        )
    }

    func testRevealingATopLevelBranchOpensNoFolders() {
        let vm = makeViewModel()

        let rowID = vm.revealLocalBranch("main")

        XCTAssertEqual(rowID, "Local Branches/main")
        XCTAssertTrue(vm.expandedFolders.isEmpty)
    }

    /// The bug this was reported for: the row has to be one the panel actually
    /// draws. While the folders above it were shut it was not, so `scrollTo`
    /// had nothing to find and the list stayed wherever the previous
    /// repository had left it — which reads as "it doesn't scroll".
    func testTheRevealedBranchIsOneOfTheDrawnRows() {
        let vm = makeViewModel()
        let branch = "social/ZSOC-1324/avatar"

        XCTAssertFalse(
            vm.rows(of: vm.localTree).contains { $0.id.hasSuffix("/avatar") },
            "inside two shut folders, the branch has no row"
        )

        let rowID = vm.revealLocalBranch(branch)
        let rows = vm.rows(of: vm.localTree)
        let revealed = rows.first { $0.id == rowID }

        XCTAssertNotNil(revealed, "the reveal has to draw the row it names")
        XCTAssertEqual(revealed?.depth, 2, "two folders deep, so indented twice")
        XCTAssertEqual(revealed?.node.branch?.name, branch)
    }

    func testShuttingAFolderDropsItsChildrenAgain() {
        let vm = makeViewModel()
        vm.revealLocalBranch("social/ZSOC-1324/avatar")
        XCTAssertEqual(vm.rows(of: vm.localTree).count, 4)  // main, social, ZSOC-1324, avatar

        vm.toggleFolder("Local Branches/social")
        XCTAssertEqual(vm.rows(of: vm.localTree).map(\.node.name), ["main", "social"])
    }

    /// The half that runs against real git: a repository switch has to leave a
    /// request behind, and it has to be the branch that is actually checked
    /// out — which is only known once `refreshPanels` has run.
    func testSwitchingRepositoryAsksForTheCheckedOutBranch() async throws {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-reveal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = try await runner.run(in: path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: path, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: path, args: ["config", "commit.gpgsign", "false"])
        _ = try await runner.run(in: path, args: ["commit", "-q", "--allow-empty", "-m", "first"])
        _ = try await runner.run(in: path, args: ["checkout", "-q", "-b", "social/ZSOC-1324/avatar"])

        let app = makeIsolatedAppState(git: GitService(runner: runner))
        await app.addRepository(at: path)
        let repo = try XCTUnwrap(app.allRepositories.first { $0.path == path })
        app.branchRevealTarget = nil

        await app.selectRepo(repo)

        XCTAssertEqual(app.branchesVM.currentBranch, "social/ZSOC-1324/avatar")
        XCTAssertEqual(app.branchRevealTarget, "social/ZSOC-1324/avatar")
    }
}
