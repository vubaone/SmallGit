import XCTest
@testable import SmallGit

final class JournalFilterTests: XCTestCase {

    private let commits: [GitCommit] = [
        GitCommit(
            hash: "abc1234deadbeef", shortHash: "abc1234",
            subject: "[PROJ-989] Fix profile bio spacing",
            authorName: "Alice", authorEmail: "alice@example.com",
            date: Date(), refs: "HEAD -> main"
        ),
        GitCommit(
            hash: "def5678cafebabe", shortHash: "def5678",
            subject: "Refactor avatar gesture handling",
            authorName: "Bob", authorEmail: "bob@example.com",
            date: Date(), refs: ""
        ),
        GitCommit(
            hash: "9999abcd00001111", shortHash: "9999abc",
            subject: "Bump build number",
            authorName: "CI Bot", authorEmail: "ci@build.local",
            date: Date(), refs: ""
        )
    ]

    func testEmptyQueryReturnsAll() {
        XCTAssertEqual(JournalViewModel.filter(commits, query: "").count, 3)
        XCTAssertEqual(JournalViewModel.filter(commits, query: "   ").count, 3)
    }

    func testFilterBySubject() {
        let r = JournalViewModel.filter(commits, query: "avatar")
        XCTAssertEqual(r.map(\.shortHash), ["def5678"])
    }

    func testFilterByTicketIDCaseInsensitive() {
        let r = JournalViewModel.filter(commits, query: "proj-989")
        XCTAssertEqual(r.map(\.shortHash), ["abc1234"])
    }

    func testFilterByAuthorName() {
        let r = JournalViewModel.filter(commits, query: "Bob")
        XCTAssertEqual(r.map(\.shortHash), ["def5678"])
    }

    func testFilterByAuthorEmail() {
        let r = JournalViewModel.filter(commits, query: "ci@build")
        XCTAssertEqual(r.map(\.shortHash), ["9999abc"])
    }

    func testFilterByShortHash() {
        let r = JournalViewModel.filter(commits, query: "9999abc")
        XCTAssertEqual(r.map(\.shortHash), ["9999abc"])
    }

    func testFilterByFullHashPrefix() {
        let r = JournalViewModel.filter(commits, query: "def5678cafe")
        XCTAssertEqual(r.map(\.shortHash), ["def5678"])
    }

    func testFilterNoMatch() {
        XCTAssertTrue(JournalViewModel.filter(commits, query: "xyz-nothing").isEmpty)
    }
}
