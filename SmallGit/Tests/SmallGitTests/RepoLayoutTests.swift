import XCTest
@testable import SmallGit

/// Where a repository keeps its data, and what the invalidation rules make of
/// a path once they know. The shape under test is `git worktree add`: `.git`
/// is a file, per-worktree state sits under the main checkout's `.git`, and
/// the refs are shared with it.
final class RepoLayoutTests: XCTestCase {

    /// The real thing, as `git rev-parse` reports it for a linked worktree.
    private let linked = RepoLayout(
        workTree: "/work/repo-linked",
        gitDir: "/work/repo-main/.git/worktrees/repo-linked",
        commonDir: "/work/repo-main/.git"
    )

    private let plain = RepoLayout.assumed(workTree: "/work/repo")

    // MARK: - The layout itself

    func testAnOrdinaryRepositoryKeepsEverythingInOnePlace() {
        XCTAssertEqual(plain.gitDir, "/work/repo/.git")
        XCTAssertEqual(plain.commonDir, "/work/repo/.git")
        XCTAssertFalse(plain.isLinkedWorktree)
        XCTAssertEqual(plain.gitPath("rebase-merge"), "/work/repo/.git/rebase-merge")
    }

    /// `--absolute-git-dir` answers with symlinks resolved, so a repository
    /// opened through a symlinked path has a `gitDir` that does not spell out
    /// as `<workTree>/.git`. That must not read as a linked worktree, or the
    /// rules below would stop believing its `HEAD` and `index`.
    func testAnOrdinaryRepositoryReachedThroughASymlinkIsNotLinked() {
        let viaSymlink = RepoLayout(
            workTree: "/work/link",
            gitDir: "/private/work/real/.git",
            commonDir: "/private/work/real/.git"
        )
        XCTAssertFalse(viaSymlink.isLinkedWorktree)
        XCTAssertEqual(
            InvalidationEngine.keysToInvalidate(
                changedPath: "/private/work/real/.git/index", layout: viaSymlink
            ),
            [.fileStatus, .trackedFiles, .assumeUnchangedFiles]
        )
    }

    /// A submodule's `.git` is a file too, but nothing in its git directory
    /// belongs to another checkout, so it is not a linked worktree either.
    func testASubmoduleIsNotALinkedWorktree() {
        let submodule = RepoLayout(
            workTree: "/work/super/mysub",
            gitDir: "/work/super/.git/modules/mysub",
            commonDir: "/work/super/.git/modules/mysub"
        )
        XCTAssertFalse(submodule.isLinkedWorktree)
        XCTAssertEqual(
            InvalidationEngine.keysToInvalidate(
                changedPath: "/work/super/.git/modules/mysub/HEAD", layout: submodule
            ),
            [.currentBranch, .log(refs: CacheKey.currentBranchSentinel)]
        )
    }

    func testALinkedWorktreeIsRecognisedAsOne() {
        XCTAssertTrue(linked.isLinkedWorktree)
        XCTAssertEqual(
            linked.gitPath("rebase-merge"),
            "/work/repo-main/.git/worktrees/repo-linked/rebase-merge",
            "the paused-operation markers are per-worktree"
        )
    }

    func testTrailingSlashesAreRemovedOnce() {
        let l = RepoLayout(workTree: "/work/repo/", gitDir: "/work/repo/.git/", commonDir: "/g/")
        XCTAssertEqual(l.workTree, "/work/repo")
        XCTAssertEqual(l.gitDir, "/work/repo/.git")
        XCTAssertEqual(l.commonDir, "/g")
    }

    /// An ordinary repository must end up watching exactly what it watched
    /// before layouts existed: one root, the checkout.
    func testAnOrdinaryRepositoryWatchesOnlyItsCheckout() {
        XCTAssertEqual(plain.watchRoots, ["/work/repo"])
    }

    /// The worktree's own git directory lives inside the common one, so a
    /// stream given both would report every change under it twice.
    func testALinkedWorktreeWatchesItsCheckoutAndTheSharedGitDirectory() {
        XCTAssertEqual(linked.watchRoots, ["/work/repo-linked", "/work/repo-main/.git"])
    }

    func testMinimalRootsDropsContainedPathsAndDuplicates() {
        XCTAssertEqual(
            RepoLayout.minimalRoots(["/a", "/a/b", "/a", "/c"]),
            ["/a", "/c"]
        )
        XCTAssertEqual(
            RepoLayout.minimalRoots(["/a-sibling", "/a"]),
            ["/a-sibling", "/a"],
            "a shared textual prefix is not containment"
        )
    }

    // MARK: - Mapping changed paths

    func testWorktreeLocalStateMapsToThisCheckout() {
        XCTAssertEqual(
            InvalidationEngine.keysToInvalidate(
                changedPath: "/work/repo-main/.git/worktrees/repo-linked/HEAD", layout: linked
            ),
            [.currentBranch, .log(refs: CacheKey.currentBranchSentinel)]
        )
        XCTAssertEqual(
            InvalidationEngine.keysToInvalidate(
                changedPath: "/work/repo-main/.git/worktrees/repo-linked/index", layout: linked
            ),
            [.fileStatus, .trackedFiles, .assumeUnchangedFiles]
        )
    }

    func testSharedRefsMapThroughTheCommonDirectory() {
        let remote = InvalidationEngine.keysToInvalidate(
            changedPath: "/work/repo-main/.git/refs/remotes/origin/main", layout: linked
        )
        XCTAssertTrue(remote.contains(.remoteBranches))
        XCTAssertTrue(remote.contains(.log(refs: CacheKey.currentBranchSentinel)))

        let heads = InvalidationEngine.keysToInvalidate(
            changedPath: "/work/repo-main/.git/refs/heads/main", layout: linked
        )
        XCTAssertTrue(heads.contains(.branchList))
    }

    /// `HEAD` and `index` exist in the common directory too — they are the
    /// *main* checkout's. A sibling worktree staging a file must not refresh
    /// this one's Files panel.
    func testTheMainCheckoutsOwnStateIsNotThisWorktreesBusiness() {
        XCTAssertEqual(
            InvalidationEngine.keysToInvalidate(
                changedPath: "/work/repo-main/.git/index", layout: linked
            ),
            []
        )
        XCTAssertEqual(
            InvalidationEngine.keysToInvalidate(
                changedPath: "/work/repo-main/.git/HEAD", layout: linked
            ),
            []
        )
        XCTAssertEqual(
            InvalidationEngine.keysToInvalidate(
                changedPath: "/work/repo-main/.git/worktrees/repo-other/HEAD", layout: linked
            ),
            [],
            "another worktree's HEAD moving changes nothing here"
        )
    }

    func testWorkingTreeFilesStillMapRelativeToTheCheckout() {
        let keys = InvalidationEngine.keysToInvalidate(
            changedPath: "/work/repo-linked/Sources/a.swift", layout: linked
        )
        XCTAssertTrue(keys.contains(.fileStatus))
        XCTAssertTrue(keys.contains(
            .diff(file: "Sources/a.swift", mode: .indexVsWorkingTree, compact: true)
        ))
    }

    /// The assumed layout has to be the old behaviour exactly — every caller
    /// that still passes `repoRoot:` goes through it.
    func testTheAssumedLayoutAnswersAsPlainPrefixStrippingDid() {
        for path in [
            "/work/repo/.git/HEAD",
            "/work/repo/.git/index",
            "/work/repo/.git/refs/heads/main",
            "/work/repo/.git/refs/remotes/origin/main",
            "/work/repo/.git/COMMIT_EDITMSG",
            "/work/repo/Sources/a.swift"
        ] {
            XCTAssertEqual(
                InvalidationEngine.keysToInvalidate(changedPath: path, layout: plain),
                InvalidationEngine.keysToInvalidate(changedPath: path, repoRoot: "/work/repo"),
                "layout and repoRoot forms disagree on \(path)"
            )
        }
    }
}
