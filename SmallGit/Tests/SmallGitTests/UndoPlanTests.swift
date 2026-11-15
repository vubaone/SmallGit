import XCTest
@testable import SmallGit

/// Exercises `GitReflogEntry.undoPlan` — the pure decision behind the
/// Repository menu's "Undo Last Operation" (which inverse is safe for
/// which reflog entry) — and the checkout-subject parsing it relies on.
final class UndoPlanTests: XCTestCase {

    private func entry(_ subject: String) -> GitReflogEntry {
        GitReflogEntry(
            index: 0,
            selector: "HEAD@{0}",
            hash: "abc1234deadbeef",
            shortHash: "abc1234",
            subject: subject,
            action: ReflogAction(subject: subject),
            date: nil
        )
    }

    // MARK: - Single-step ops rewind one reflog entry

    func testCommitUndoesToPreviousReflogEntry() {
        XCTAssertEqual(entry("commit: add feature").undoPlan,
                       .resetKeep(ref: "HEAD@{1}"))
    }

    func testAmendUndoesToPreviousReflogEntry() {
        XCTAssertEqual(entry("commit (amend): fix typo").undoPlan,
                       .resetKeep(ref: "HEAD@{1}"))
    }

    func testCherryPickAndRevertUndoToPreviousReflogEntry() {
        XCTAssertEqual(entry("cherry-pick: pick thing").undoPlan,
                       .resetKeep(ref: "HEAD@{1}"))
        XCTAssertEqual(entry("revert: Revert \"thing\"").undoPlan,
                       .resetKeep(ref: "HEAD@{1}"))
    }

    // MARK: - Multi-step ops go back to ORIG_HEAD

    func testRebaseUndoesToOrigHead() {
        // A finished rebase leaves many reflog entries; HEAD@{1} would
        // only unwind the last pick. ORIG_HEAD spans the whole rebase.
        XCTAssertEqual(entry("rebase (finish): returning to refs/heads/main").undoPlan,
                       .resetKeep(ref: "ORIG_HEAD"))
    }

    func testMergePullAndResetUndoToOrigHead() {
        XCTAssertEqual(entry("merge feature: Merge made by the 'ort' strategy.").undoPlan,
                       .resetKeep(ref: "ORIG_HEAD"))
        XCTAssertEqual(entry("pull: Fast-forward").undoPlan,
                       .resetKeep(ref: "ORIG_HEAD"))
        XCTAssertEqual(entry("reset: moving to HEAD~3").undoPlan,
                       .resetKeep(ref: "ORIG_HEAD"))
    }

    // MARK: - Checkout undoes by checking the previous ref back out

    func testCheckoutUndoesByCheckingOutSource() {
        XCTAssertEqual(entry("checkout: moving from main to feature/x").undoPlan,
                       .checkout(ref: "main"))
    }

    func testCheckoutSourceSplitsOnLastTo() {
        // Branch names may contain " to " — git's subject always ends
        // with the destination, so the split must be on the *last* " to ".
        XCTAssertEqual(
            entry("checkout: moving from how to win to main").checkoutSource,
            "how to win"
        )
    }

    func testMalformedCheckoutSubjectIsUnsupported() {
        XCTAssertEqual(entry("checkout: something unexpected").undoPlan,
                       .unsupported)
    }

    // MARK: - No safe inverse

    func testBranchAndUnknownVerbsAreUnsupported() {
        XCTAssertEqual(entry("branch: Created from HEAD").undoPlan, .unsupported)
        XCTAssertEqual(entry("gc: something").undoPlan, .unsupported)
    }
}
