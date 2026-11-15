import XCTest
@testable import SmallGit

/// Unit tests for `GitOutputParser.parseReflog` and the `ReflogAction`
/// keyword bucketing. The integration round-trip lives in
/// `ReflogIntegrationTests` (needs a real git binary).
final class ReflogTests: XCTestCase {

    func testParserSingleCommitEntry() {
        let raw = "abc1234\tabc1234\tHEAD@{0}\tcommit: Add feature\t2026-05-24T10:00:00+07:00"
        let entries = GitOutputParser.parseReflog(raw)
        XCTAssertEqual(entries.count, 1)
        let e = entries[0]
        XCTAssertEqual(e.index, 0)
        XCTAssertEqual(e.selector, "HEAD@{0}")
        XCTAssertEqual(e.hash, "abc1234")
        XCTAssertEqual(e.shortHash, "abc1234")
        XCTAssertEqual(e.action, .commit)
        XCTAssertEqual(e.message, "Add feature")
        XCTAssertNotNil(e.date)
    }

    func testParserMultipleEntriesAssignSequentialIndices() {
        let raw = """
        h0\th0\tHEAD@{0}\tcommit: top\t2026-05-24T10:00:00+07:00
        h1\th1\tHEAD@{1}\tcheckout: moving from main to feature\t2026-05-24T09:30:00+07:00
        h2\th2\tHEAD@{2}\treset: moving to HEAD~3\t2026-05-24T09:00:00+07:00
        """
        let entries = GitOutputParser.parseReflog(raw)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.index), [0, 1, 2])
        XCTAssertEqual(entries.map(\.action), [.commit, .checkout, .reset])
    }

    func testParserSkipsBlankLines() {
        let raw = "\nabc\tabc\tHEAD@{0}\tcommit: x\t2026-05-24T10:00:00+07:00\n\n"
        let entries = GitOutputParser.parseReflog(raw)
        XCTAssertEqual(entries.count, 1)
    }

    func testParserMissingDateStillProducesEntry() {
        // Older git versions or unusual reflog rows can omit the trailing
        // ISO date column. Parser should still return a row with date=nil.
        let raw = "abc\tabc\tHEAD@{0}\tcommit: x\t"
        let entries = GitOutputParser.parseReflog(raw)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].date)
    }

    func testActionKeywordBucketing() {
        XCTAssertEqual(ReflogAction(subject: "commit: foo"), .commit)
        XCTAssertEqual(ReflogAction(subject: "commit (initial): foo"), .commit)
        XCTAssertEqual(ReflogAction(subject: "commit (amend): foo"), .amend)
        XCTAssertEqual(ReflogAction(subject: "commit (merge): foo"), .merge)
        XCTAssertEqual(ReflogAction(subject: "checkout: moving from a to b"), .checkout)
        XCTAssertEqual(ReflogAction(subject: "reset: moving to HEAD~1"), .reset)
        XCTAssertEqual(ReflogAction(subject: "merge other-branch: Fast-forward"), .merge)
        XCTAssertEqual(ReflogAction(subject: "rebase (start): checkout main"), .rebase)
        XCTAssertEqual(ReflogAction(subject: "rebase (finish): returning to HEAD"), .rebase)
        XCTAssertEqual(ReflogAction(subject: "cherry-pick: abc"), .cherryPick)
        XCTAssertEqual(ReflogAction(subject: "revert: abc"), .revert)
        XCTAssertEqual(ReflogAction(subject: "pull: Fast-forward"), .pull)
        XCTAssertEqual(ReflogAction(subject: "clone: from git@example"), .clone)
        XCTAssertEqual(ReflogAction(subject: "branch: Created from main"), .branch)
        XCTAssertEqual(ReflogAction(subject: "something we don't know"), .other)
    }

    func testReflogEntryMessageStripsActionPrefix() {
        let entry = GitReflogEntry(
            index: 0,
            selector: "HEAD@{0}",
            hash: "a", shortHash: "a",
            subject: "checkout: moving from main to feature",
            action: .checkout,
            date: nil
        )
        XCTAssertEqual(entry.message, "moving from main to feature")
    }

    func testReflogEntryMessageWithoutColonReturnsSubject() {
        let entry = GitReflogEntry(
            index: 0,
            selector: "HEAD@{0}",
            hash: "a", shortHash: "a",
            subject: "amend",
            action: .amend,
            date: nil
        )
        XCTAssertEqual(entry.message, "amend")
    }
}
