import XCTest
@testable import SmallGit

/// Exercises `GitOutputParser.parseWorktrees` against the porcelain
/// block format of `git worktree list --porcelain`.
final class WorktreeParserTests: XCTestCase {

    func testParsesMainAndLinkedWorktrees() {
        let output = """
        worktree /Users/dev/proj
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /Users/dev/proj-fix
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/fix/crash
        """
        let wts = GitOutputParser.parseWorktrees(output)
        XCTAssertEqual(wts.count, 2)

        XCTAssertEqual(wts[0].path, "/Users/dev/proj")
        XCTAssertTrue(wts[0].isMain)
        XCTAssertEqual(wts[0].branch, "main")
        XCTAssertEqual(wts[0].shortSHA, "1111111")

        XCTAssertEqual(wts[1].path, "/Users/dev/proj-fix")
        XCTAssertFalse(wts[1].isMain)
        XCTAssertEqual(wts[1].branch, "fix/crash")
        XCTAssertEqual(wts[1].name, "proj-fix")
    }

    func testParsesDetachedHead() {
        let output = """
        worktree /Users/dev/proj
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /Users/dev/proj-detached
        HEAD 3333333333333333333333333333333333333333
        detached
        """
        let wts = GitOutputParser.parseWorktrees(output)
        XCTAssertEqual(wts.count, 2)
        XCTAssertNil(wts[1].branch)
        XCTAssertFalse(wts[1].isBare)
    }

    func testParsesLockedWithAndWithoutReason() {
        let output = """
        worktree /a
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /b
        HEAD 2222222222222222222222222222222222222222
        detached
        locked

        worktree /c
        HEAD 3333333333333333333333333333333333333333
        detached
        locked on a USB drive
        """
        let wts = GitOutputParser.parseWorktrees(output)
        XCTAssertEqual(wts.count, 3)
        XCTAssertTrue(wts[1].isLocked)
        XCTAssertNil(wts[1].lockReason)
        XCTAssertTrue(wts[2].isLocked)
        XCTAssertEqual(wts[2].lockReason, "on a USB drive")
    }

    func testParsesPrunableAndBare(){
        let output = """
        worktree /bare
        bare

        worktree /gone
        HEAD 4444444444444444444444444444444444444444
        detached
        prunable gitdir file points to non-existent location
        """
        let wts = GitOutputParser.parseWorktrees(output)
        XCTAssertEqual(wts.count, 2)
        XCTAssertTrue(wts[0].isBare)
        XCTAssertTrue(wts[0].isMain)
        XCTAssertTrue(wts[1].isPrunable)
    }

    func testEmptyOutputYieldsNothing() {
        XCTAssertTrue(GitOutputParser.parseWorktrees("").isEmpty)
        XCTAssertTrue(GitOutputParser.parseWorktrees("\n\n").isEmpty)
    }

    func testPathsWithSpacesSurvive() {
        let output = """
        worktree /Users/dev/My Projects/proj
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main
        """
        let wts = GitOutputParser.parseWorktrees(output)
        XCTAssertEqual(wts.first?.path, "/Users/dev/My Projects/proj")
    }
}

/// Exercises `GitOutputParser.parseObjectDatabaseSizeKiB` — the
/// `git count-objects -v` reading behind Clean Up's before → after
/// size report.
final class ObjectDatabaseSizeParserTests: XCTestCase {

    func testSumsLooseAndPackedKiB() {
        let output = """
        count: 12
        size: 48
        in-pack: 3510
        packs: 1
        size-pack: 4820
        prune-packable: 0
        garbage: 0
        size-garbage: 0
        """
        XCTAssertEqual(GitOutputParser.parseObjectDatabaseSizeKiB(output), 4868)
    }

    func testIgnoresUnrelatedKeysAndJunk() {
        // `size-garbage` must not match the `size` key; malformed lines
        // are skipped.
        let output = """
        size-garbage: 999
        size: 10
        nonsense line
        size-pack: 20
        """
        XCTAssertEqual(GitOutputParser.parseObjectDatabaseSizeKiB(output), 30)
    }

    func testEmptyOutputIsZero() {
        XCTAssertEqual(GitOutputParser.parseObjectDatabaseSizeKiB(""), 0)
    }
}
