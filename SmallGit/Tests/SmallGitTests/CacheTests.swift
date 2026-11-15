import XCTest
@testable import SmallGit

final class CacheTests: XCTestCase {

    @MainActor
    func testMemoryCacheRoundTrip() {
        let cache = MemoryCache()
        cache.set(.fileStatus, value: ["a", "b", "c"])
        let read: [String]? = cache.get(.fileStatus, as: [String].self)
        XCTAssertEqual(read, ["a", "b", "c"])
        XCTAssertTrue(cache.has(.fileStatus))
        cache.invalidate(.fileStatus)
        XCTAssertNil(cache.get(.fileStatus, as: [String].self))
    }

    @MainActor
    func testMemoryCacheBatchInvalidation() {
        let cache = MemoryCache()
        cache.set(.fileStatus, value: 1)
        cache.set(.currentBranch, value: "main")
        cache.set(.branchList, value: ["main", "dev"])
        cache.invalidate([.fileStatus, .currentBranch])
        XCTAssertNil(cache.get(.fileStatus, as: Int.self))
        XCTAssertNil(cache.get(.currentBranch, as: String.self))
        XCTAssertNotNil(cache.get(.branchList, as: [String].self))
    }

    func testCacheKeyDiskFileNames() {
        XCTAssertEqual(CacheKey.fileStatus.diskFileName, "file_status.json")
        XCTAssertEqual(CacheKey.log(refs: "main").diskFileName, "log_main.json")
        XCTAssertEqual(
            CacheKey.diff(file: "src/app/main.swift", mode: .headVsIndex, compact: true).diskFileName,
            "diff_headVsIndex_c_src_app_main.swift.json"
        )
        XCTAssertEqual(
            CacheKey.diff(file: "src/x.swift", mode: .indexVsWorkingTree, compact: false).diskFileName,
            "diff_indexVsWorkingTree_full_src_x.swift.json"
        )
    }

    func testInvalidationFromHEADChange() {
        let keys = InvalidationEngine.keysToInvalidate(
            changedPath: "/repo/.git/HEAD",
            repoRoot: "/repo"
        )
        XCTAssertTrue(keys.contains(.currentBranch))
        XCTAssertTrue(keys.contains(.log(refs: CacheKey.currentBranchSentinel)))
    }

    func testInvalidationFromIndexChange() {
        let keys = InvalidationEngine.keysToInvalidate(
            changedPath: "/repo/.git/index",
            repoRoot: "/repo"
        )
        // The index is also the tracked-file list the Files filter
        // searches and the home of the assume-unchanged bits, so an add,
        // an rm or an `update-index` retires all three.
        XCTAssertEqual(keys, [.fileStatus, .trackedFiles, .assumeUnchangedFiles])
    }

    func testInvalidationFromBranchRef() {
        let keys = InvalidationEngine.keysToInvalidate(
            changedPath: "/repo/.git/refs/heads/feature/login",
            repoRoot: "/repo"
        )
        XCTAssertTrue(keys.contains(.branchList))
    }

    func testInvalidationFromUnrelatedGitFile() {
        let keys = InvalidationEngine.keysToInvalidate(
            changedPath: "/repo/.git/COMMIT_EDITMSG",
            repoRoot: "/repo"
        )
        XCTAssertTrue(keys.isEmpty)
    }

    func testInvalidationFromWorkingTreeFile() {
        let keys = InvalidationEngine.keysToInvalidate(
            changedPath: "/repo/src/app/main.swift",
            repoRoot: "/repo"
        )
        XCTAssertTrue(keys.contains(.fileStatus))
        XCTAssertTrue(keys.contains(.diff(file: "src/app/main.swift", mode: .indexVsWorkingTree, compact: true)))
        XCTAssertTrue(keys.contains(.diff(file: "src/app/main.swift", mode: .indexVsWorkingTree, compact: false)))
    }

    func testActionInvalidationCommit() {
        let keys = InvalidationEngine.keysAfter(.commit)
        XCTAssertTrue(keys.contains(.fileStatus))
        XCTAssertTrue(keys.contains(.log(refs: CacheKey.currentBranchSentinel)))
        // A commit advances the branch tip, so its ahead/behind vs. upstream
        // changes — the branch list must be re-fetched, not served stale.
        XCTAssertTrue(keys.contains(.branchList))
    }

    /// Every action that moves the branch tip changes its ahead/behind vs.
    /// upstream, so all of them must drop the cached branch list. Missing
    /// this left the Branches panel showing a pre-operation count.
    func testTipMovingActionsInvalidateBranchList() {
        for action: GitAction in [.commit, .merge, .pull, .rebase, .reset] {
            XCTAssertTrue(
                InvalidationEngine.keysAfter(action).contains(.branchList),
                "expected \(action) to invalidate .branchList"
            )
        }
    }

    /// A push moves no commit, but it does move the `origin/<branch>` chip
    /// the journal draws — that decoration is `%D` baked into the cached log
    /// rows, so a log cached before the push keeps drawing the chip on the
    /// commit the remote used to be at. Missing this left the graph showing
    /// origin behind HEAD on a branch that was fully pushed.
    func testRemoteMovingActionsInvalidateTheLog() {
        for action: GitAction in [.push, .fetch, .pull] {
            XCTAssertTrue(
                InvalidationEngine.keysAfter(action)
                    .contains(.log(refs: CacheKey.currentBranchSentinel)),
                "expected \(action) to invalidate the log"
            )
        }
        XCTAssertTrue(InvalidationEngine.keysAfter(.push).contains(.remoteBranches))
        XCTAssertTrue(InvalidationEngine.keysAfter(.fetch).contains(.tagList))
    }

    /// The same move seen from outside SmallGit — a push or fetch run in a
    /// terminal, which reaches the app only as a `.git/refs/remotes/` write.
    func testInvalidationFromRemoteRef() {
        let keys = InvalidationEngine.keysToInvalidate(
            changedPath: "/repo/.git/refs/remotes/origin/feature/login",
            repoRoot: "/repo"
        )
        XCTAssertTrue(keys.contains(.remoteBranches))
        XCTAssertTrue(keys.contains(.log(refs: CacheKey.currentBranchSentinel)))
    }

    /// `DiskCache.removeLogs` finds its files by prefix, so the prefix has to
    /// stay the one `diskFileName` actually writes.
    func testEveryLogFileNameCarriesTheLogPrefix() {
        for refs in [CacheKey.currentBranchSentinel, "main", "a1b2c3"] {
            XCTAssertTrue(
                CacheKey.log(refs: refs).diskFileName
                    .hasPrefix(CacheKey.logDiskFilePrefix),
                "expected log_ prefix for refs=\(refs)"
            )
        }
        XCTAssertFalse(
            CacheKey.branchList.diskFileName.hasPrefix(CacheKey.logDiskFilePrefix)
        )
    }

    /// Retiring logs must take every ref selection with it — including the
    /// ones not on screen, which are exactly the entries a later `get` would
    /// serve from disk.
    func testRemoveLogsDropsEverySelectionAndNothingElse() async {
        let disk = DiskCache()
        let repo = "/tmp/smallgit-tests/\(UUID().uuidString)"
        defer { Task { await disk.removeAll(repoPath: repo) } }

        let onScreen = CacheKey.log(refs: CacheKey.currentBranchSentinel)
        let other = CacheKey.log(refs: "a1b2c3")
        await disk.save(key: onScreen, repoPath: repo, entry: CacheEntry(value: ["v.03"]))
        await disk.save(key: other, repoPath: repo, entry: CacheEntry(value: ["v.03"]))
        await disk.save(key: .branchList, repoPath: repo, entry: CacheEntry(value: ["main"]))

        await disk.removeLogs(repoPath: repo)

        let onScreenAfter = await disk.load(key: onScreen, repoPath: repo, as: [String].self)
        let otherAfter = await disk.load(key: other, repoPath: repo, as: [String].self)
        let branchesAfter = await disk.load(key: .branchList, repoPath: repo, as: [String].self)
        XCTAssertNil(onScreenAfter)
        XCTAssertNil(otherAfter)
        XCTAssertNotNil(branchesAfter, "only logs were retired")
    }

    func testActionInvalidationStageWithFiles() {
        let keys = InvalidationEngine.keysAfter(.stage(files: ["a.swift", "b.swift"]))
        XCTAssertTrue(keys.contains(.fileStatus))
        // Stage moves content between Index and Working Tree — every
        // compare mode for each touched file is now stale.
        for f in ["a.swift", "b.swift"] {
            for mode in DiffCompareMode.allCases {
                for compact in [true, false] {
                    XCTAssertTrue(
                        keys.contains(.diff(file: f, mode: mode, compact: compact)),
                        "expected \(f) / \(mode) / compact=\(compact) to be invalidated"
                    )
                }
            }
        }
    }
}
