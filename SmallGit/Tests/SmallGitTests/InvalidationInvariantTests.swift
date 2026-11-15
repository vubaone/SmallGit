import XCTest
@testable import SmallGit

/// The rules `InvalidationEngine` keeps getting wrong, asserted over every
/// action and every watched path instead of one bug at a time.
///
/// Each miss in this file shipped as the same symptom: a panel showing the
/// repository as it was before the click, because what the panel derives and
/// what the action retired were decided in different places. The tests exist
/// so the next action added to the enum has to answer both questions.
final class InvalidationInvariantTests: XCTestCase {

    // MARK: - Rule 1: a ref that moves retires the log

    /// `%D` bakes the branch, remote and tag chips into the cached commit
    /// rows, so any action that creates, deletes or moves a ref leaves a chip
    /// drawn on the commit that ref used to be at.
    func testEveryRefMovingActionRetiresTheLog() {
        let refMoving: [(GitAction, String)] = [
            (.commit,       "moves the current branch tip"),
            (.pull,         "moves the branch and its remote-tracking ref"),
            (.push,         "moves the remote-tracking ref"),
            (.fetch,        "moves remote-tracking refs and can add tags"),
            (.checkout,     "moves which ref HEAD names"),
            (.merge,        "moves the current branch tip"),
            (.rebase,       "rewrites the current branch"),
            (.reset,        "repoints the current branch"),
            (.branchCreate, "adds a branch chip"),
            (.branchDelete, "removes a branch chip"),
            (.branchRename, "does both"),
            (.tagChange,    "adds or removes a tag chip")
        ]

        for (action, why) in refMoving {
            XCTAssertTrue(
                InvalidationEngine.keysAfter(action).contains(where: \.isLog),
                "\(action) \(why), so the cached log rows are stale"
            )
        }
    }

    /// The other half of the rule: actions that touch no ref must not throw
    /// the graph away. Retiring the log costs a `git log` over the whole
    /// selection, and doing it on every staged file is how a cache stops
    /// being one.
    func testActionsThatMoveNoRefLeaveTheLogAlone() {
        let refNeutral: [GitAction] = [
            .stage(files: ["a.swift"]),
            .unstage(files: ["a.swift"]),
            .discard(files: ["a.swift"]),
            .assumeUnchanged(files: ["a.swift"]),
            .stashSave,
            .stashApply,
            .stashDrop
        ]

        for action in refNeutral {
            XCTAssertFalse(
                InvalidationEngine.keysAfter(action).contains(where: \.isLog),
                "\(action) moves no ref, so the graph is still accurate"
            )
        }
    }

    // MARK: - Rule 2: upstream distance is measured, not stored

    /// Ahead/behind and `[gone]` come from `%(upstream:track)` at the moment
    /// the branch list was read. Moving either side of that comparison — the
    /// branch or the remote it tracks — makes the cached list wrong.
    func testEveryActionThatChangesUpstreamDistanceRetiresTheBranchList() {
        let moves: [(GitAction, String)] = [
            (.commit,       "the branch pulls ahead of its upstream"),
            (.push,         "the branch stops being ahead, and a first push gives it an upstream"),
            (.pull,         "both sides move"),
            (.fetch,        "the upstream moves, or turns out to be gone"),
            (.merge,        "the branch tip moves"),
            (.rebase,       "the branch is rewritten"),
            (.reset,        "the branch is repointed"),
            (.checkout,     "a different branch becomes the one marked HEAD"),
            (.branchCreate, "there is a new branch to list"),
            (.branchDelete, "one fewer"),
            (.branchRename, "under a different name")
        ]

        for (action, why) in moves {
            XCTAssertTrue(
                InvalidationEngine.keysAfter(action).contains(.branchList),
                "after \(action) \(why), so the Branches panel is stale"
            )
        }
    }

    // MARK: - Tripwire

    /// `GitAction` carries associated values, so there is no `CaseIterable` to
    /// enumerate. This count is the stand-in: adding an action without adding
    /// it to `everyKind` — and so without either rule above being checked for
    /// it — fails here.
    func testEveryActionKindIsListedForTheRulesToBeCheckedAgainst() {
        XCTAssertEqual(
            GitAction.everyKind.count, 19,
            "a new GitAction: add it to GitAction.everyKind and to the rule tables above"
        )
    }

    /// Every action has to invalidate *something*. An action whose key set is
    /// empty is an action after which nothing on screen is re-read.
    func testNoActionInvalidatesNothing() {
        for action in GitAction.everyKind {
            XCTAssertFalse(
                InvalidationEngine.keysAfter(action).isEmpty,
                "\(action) retires no cache, so nothing it changed will be re-read"
            )
        }
    }

    // MARK: - Watched paths

    /// The filesystem half of rule 1: whatever writes a ref, wherever git
    /// chooses to put it, retires the log.
    func testEveryRefPathRetiresTheLog() {
        let refPaths = [
            ".git/HEAD",
            ".git/refs/heads/main",
            ".git/refs/remotes/origin/main",
            ".git/refs/tags/v1.0",
            ".git/packed-refs"
        ]

        for path in refPaths {
            let keys = InvalidationEngine.keysToInvalidate(
                changedPath: "/repo/\(path)",
                repoRoot: "/repo"
            )
            XCTAssertTrue(
                keys.contains(where: \.isLog),
                "\(path) is where a ref lands, so the graph's chips are stale"
            )
        }
    }

    /// Each ref namespace also retires the list that shows it — the symptom
    /// otherwise is a Branches panel disagreeing with the graph beside it.
    func testEachRefNamespaceRetiresItsOwnList() {
        func keys(_ path: String) -> Set<CacheKey> {
            InvalidationEngine.keysToInvalidate(changedPath: "/repo/\(path)", repoRoot: "/repo")
        }

        XCTAssertTrue(keys(".git/refs/heads/main").contains(.branchList))
        XCTAssertTrue(keys(".git/refs/remotes/origin/main").contains(.remoteBranches))
        XCTAssertTrue(
            keys(".git/refs/remotes/origin/main").contains(.branchList),
            "the local branch's ahead/behind is measured against this ref"
        )
        XCTAssertTrue(keys(".git/refs/tags/v1.0").contains(.tagList))
        XCTAssertTrue(keys(".git/refs/stash").contains(.stashList))
        XCTAssertTrue(keys(".git/HEAD").contains(.currentBranch))
        XCTAssertTrue(keys(".git/index").contains(.fileStatus))
    }

    /// And the inverse, which is what keeps the app from refreshing on its own
    /// writes: git's internal bookkeeping maps to nothing.
    func testGitInternalsThatNoPanelReadsInvalidateNothing() {
        for name in ["COMMIT_EDITMSG", "config", "ORIG_HEAD", "FETCH_HEAD", "index.lock"] {
            XCTAssertTrue(
                InvalidationEngine.keysToInvalidate(
                    changedPath: "/repo/.git/\(name)",
                    repoRoot: "/repo"
                ).isEmpty,
                "\(name) is git talking to itself"
            )
        }
    }
}
