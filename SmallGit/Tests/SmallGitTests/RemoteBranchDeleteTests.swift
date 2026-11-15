import XCTest
@testable import SmallGit

/// Deleting a branch from a remote — a push, not a `git branch -d`, and the
/// one delete in this app other people see.
///
/// The two pieces worth pinning are the ones that build or explain the
/// command: which remote a ref is on, and what the far end meant by no.
final class RemoteBranchDeleteTests: XCTestCase {

    private func remote(_ name: String) -> GitBranch {
        GitBranch(name: name, isRemote: true)
    }

    // MARK: - Splitting the ref

    func testSplitsARemoteRefIntoItsTwoHalves() {
        let ref = remote("origin/main").remoteRef(knownRemotes: ["origin"])
        XCTAssertEqual(ref?.remote, "origin")
        XCTAssertEqual(ref?.branch, "main")
    }

    /// The everyday case the first slash gets wrong.
    func testABranchNameMayContainSlashes() {
        let ref = remote("origin/social/ZSOC-1325/emoji")
            .remoteRef(knownRemotes: ["origin"])
        XCTAssertEqual(ref?.remote, "origin")
        XCTAssertEqual(ref?.branch, "social/ZSOC-1325/emoji")
    }

    /// And so may a remote name, which is why the longest one wins: cutting
    /// at the first slash here would push to `origin` and delete a branch
    /// called `fork/main` that nobody named.
    func testTheLongestMatchingRemoteWins() {
        let ref = remote("origin/fork/main")
            .remoteRef(knownRemotes: ["origin", "origin/fork"])
        XCTAssertEqual(ref?.remote, "origin/fork")
        XCTAssertEqual(ref?.branch, "main")
    }

    /// A ref whose remote this repository does not have is not one to build
    /// a push out of.
    func testAnUnknownRemoteGivesNothing() {
        XCTAssertNil(remote("upstream/main").remoteRef(knownRemotes: ["origin"]))
        XCTAssertNil(remote("origin/").remoteRef(knownRemotes: ["origin"]))
        XCTAssertNil(remote("origin").remoteRef(knownRemotes: ["origin"]))
    }

    /// Local branches never go down this path, whatever they are called.
    func testALocalBranchIsNotARemoteRef() {
        XCTAssertNil(
            GitBranch(name: "origin/main", isRemote: false)
                .remoteRef(knownRemotes: ["origin"])
        )
    }

    // MARK: - What the far end said

    /// git's wording for a hosted repository's default branch. It names a
    /// setting on the host, which has no git command, so the message has to
    /// say where to go.
    func testTheDefaultBranchRefusalSaysWhereToChangeIt() {
        let output = """
        To https://github.com/example/repo.git
         ! [remote rejected] main (refusing to delete the current branch: refs/heads/main)
        error: failed to push some refs
        """
        XCTAssertEqual(
            AppState.remoteDeleteRefusal(output, remote: "origin", branch: "main"),
            "main is the default branch on origin — change that first, then delete it"
        )
    }

    /// Someone else got there first. Not a failure worth alarming about.
    func testAnAlreadyDeletedBranchSaysSo() {
        let output = "error: unable to delete 'gone': remote ref does not exist"
        XCTAssertEqual(
            AppState.remoteDeleteRefusal(output, remote: "origin", branch: "gone"),
            "gone is already gone from origin"
        )
    }

    /// Anything else falls back to git's own first useful line rather than a
    /// bare "failed".
    func testAnythingElseKeepsGitsOwnWords() {
        let output = """
        hint: Updates were rejected
        remote: Permission to example/repo.git denied
        """
        XCTAssertEqual(
            AppState.remoteDeleteRefusal(output, remote: "origin", branch: "x"),
            "remote: Permission to example/repo.git denied"
        )
    }
}
