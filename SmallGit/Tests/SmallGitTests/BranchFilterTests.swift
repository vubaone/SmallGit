import XCTest
@testable import SmallGit

final class BranchFilterTests: XCTestCase {

    private let branches: [GitBranch] = [
        GitBranch(name: "main", upstream: "origin/main", isHead: true),
        GitBranch(name: "feature/login", upstream: "origin/feature/login"),
        GitBranch(name: "feature/profile-rework", upstream: nil),
        GitBranch(name: "release/2024.10", upstream: "origin/release/2024.10"),
        GitBranch(name: "hotfix/crash-on-launch", upstream: nil)
    ]

    func testEmptyQueryReturnsAll() {
        XCTAssertEqual(BranchesViewModel.filterBranches(branches, query: "").count, 5)
        XCTAssertEqual(BranchesViewModel.filterBranches(branches, query: "   ").count, 5)
    }

    func testFilterByName() {
        let r = BranchesViewModel.filterBranches(branches, query: "feature/")
        XCTAssertEqual(r.map(\.name), ["feature/login", "feature/profile-rework"])
    }

    func testFilterByUpstream() {
        // "origin/feature/login" is the upstream of "feature/login" only.
        let r = BranchesViewModel.filterBranches(branches, query: "origin/feature")
        XCTAssertEqual(r.map(\.name), ["feature/login"])
    }

    func testFilterCaseInsensitive() {
        let r = BranchesViewModel.filterBranches(branches, query: "RELEASE")
        XCTAssertEqual(r.map(\.name), ["release/2024.10"])
    }

    func testFilterTags() {
        let tags = ["v1.0.0", "v1.1.0", "v2.0.0-beta", "internal-build-42"]
        XCTAssertEqual(BranchesViewModel.filterTags(tags, query: "v2"), ["v2.0.0-beta"])
        XCTAssertEqual(BranchesViewModel.filterTags(tags, query: "build"), ["internal-build-42"])
        XCTAssertEqual(BranchesViewModel.filterTags(tags, query: "").count, 4)
    }

    func testNoMatch() {
        XCTAssertTrue(BranchesViewModel.filterBranches(branches, query: "nope-not-here").isEmpty)
    }
}
