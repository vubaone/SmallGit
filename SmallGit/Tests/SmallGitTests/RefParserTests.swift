import XCTest
@testable import SmallGit

final class RefParserTests: XCTestCase {

    func testEmptyReturnsEmpty() {
        XCTAssertTrue(RefParser.parse("").isEmpty)
        XCTAssertTrue(RefParser.parse("   ").isEmpty)
    }

    func testHeadArrowProducesHeadKind() {
        let r = RefParser.parse("HEAD -> main")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].kind, .head)
        XCTAssertEqual(r[0].name, "main")
    }

    func testDetachedHeadAlone() {
        let r = RefParser.parse("HEAD")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].kind, .head)
        XCTAssertEqual(r[0].name, "HEAD")
    }

    func testTagPrefix() {
        let r = RefParser.parse("tag: v1.0.0")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].kind, .tag)
        XCTAssertEqual(r[0].name, "v1.0.0")
    }

    func testSlashIsTreatedAsRemoteBranch() {
        let r = RefParser.parse("origin/main")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].kind, .remoteBranch)
        XCTAssertEqual(r[0].name, "origin/main")
    }

    func testLocalBranchWithoutSlash() {
        let r = RefParser.parse("trunk")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].kind, .localBranch)
    }

    func testMixedRealistic() {
        // The kind of thing %D actually outputs for a commit on main:
        let r = RefParser.parse("HEAD -> main, origin/main, tag: v2.0.0, origin/HEAD")
        XCTAssertEqual(r.map(\.kind), [.head, .remoteBranch, .tag, .remoteBranch])
        XCTAssertEqual(r.map(\.name), ["main", "origin/main", "v2.0.0", "origin/HEAD"])
    }
}
