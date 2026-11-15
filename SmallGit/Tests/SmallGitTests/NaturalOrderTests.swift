import XCTest
@testable import SmallGit

final class NaturalOrderTests: XCTestCase {

    private func sorted(_ names: [String]) -> [String] {
        names.sorted { $0.naturallyPrecedes($1) }
    }

    func testTicketNumbersSortByValue() {
        XCTAssertTrue("ZSOC-153".naturallyPrecedes("ZSOC-1056"))
        XCTAssertFalse("ZSOC-1056".naturallyPrecedes("ZSOC-153"))
        // The behaviour being fixed: plain string order gets this backwards.
        XCTAssertTrue("ZSOC-1056" < "ZSOC-153")
    }

    /// The branch list from the repository this came up in, in the order
    /// SmartGit shows it.
    func testMatchesTheOrderSmartGitShows() {
        let scrambled = [
            "ZSOC-1183-profile-name-2-lines",
            "ZSOC-1227-animated-image-test",
            "ZSOC-1237-refactor-zstyle-sub-flags",
            "ZSOC-1256-bug-1825927-missmp3button",
            "ZSOC-1256-revamp-ep-music-profile-2",
            "ZSOC-1257-bug-dominant-color-hardcode",
            "ZSOC-1324-viewfull-avatar-limitfeed",
            "ZSOC-153-improve_zstyle",
            "ZSOC-306-image-tool",
            "ZSOC-345-recheck-scrolling-perf",
            "ZSOC-534-debug-media-domain",
            "ZSOC-693-social-image-cache-improve",
            "ZSOC-712-preload-video-p2",
            "ZSOC-868-update-profile-log-v2",
            "ZSOC-870-log-zbiz-x-zstyle-by-flag",
            "ZSOC-1056-switch-profile-bio-hardcode",
            "main",
            "main_merge_review",
            "release-10.02.683",
        ]

        XCTAssertEqual(sorted(scrambled), [
            "ZSOC-153-improve_zstyle",
            "ZSOC-306-image-tool",
            "ZSOC-345-recheck-scrolling-perf",
            "ZSOC-534-debug-media-domain",
            "ZSOC-693-social-image-cache-improve",
            "ZSOC-712-preload-video-p2",
            "ZSOC-868-update-profile-log-v2",
            "ZSOC-870-log-zbiz-x-zstyle-by-flag",
            "ZSOC-1056-switch-profile-bio-hardcode",
            "ZSOC-1183-profile-name-2-lines",
            "ZSOC-1227-animated-image-test",
            "ZSOC-1237-refactor-zstyle-sub-flags",
            // Same ticket: the text after it decides.
            "ZSOC-1256-bug-1825927-missmp3button",
            "ZSOC-1256-revamp-ep-music-profile-2",
            "ZSOC-1257-bug-dominant-color-hardcode",
            "ZSOC-1324-viewfull-avatar-limitfeed",
            "main",
            "main_merge_review",
            "release-10.02.683",
        ])
    }

    func testMultipleNumberRunsEachCompareByValue() {
        XCTAssertEqual(
            sorted(["release-10.2.9", "release-9.10.1", "release-10.10.1", "release-10.2.10"]),
            ["release-9.10.1", "release-10.2.9", "release-10.2.10", "release-10.10.1"]
        )
    }

    func testLeadingZerosCompareByValueThenLength() {
        XCTAssertEqual(sorted(["v010", "v9", "v10", "v0010"]), ["v9", "v10", "v010", "v0010"])
        XCTAssertEqual("v01".naturalCompare("v1"), .orderedDescending)
        XCTAssertEqual("v1".naturalCompare("v1"), .orderedSame)
    }

    func testDigitsSortBeforeLetters() {
        XCTAssertTrue("feature-2".naturallyPrecedes("feature-a"))
        XCTAssertTrue("feature".naturallyPrecedes("feature-1"))
    }

    func testCaseOrderingIsUnchanged() {
        // Uppercase still sorts ahead of lowercase, as it did before and as
        // SmartGit shows it — only the digit handling changes.
        XCTAssertTrue("ZSOC-1".naturallyPrecedes("main"))
        XCTAssertTrue("A".naturallyPrecedes("a"))
    }

    func testPureNumericAndEmptyNames() {
        XCTAssertEqual(sorted(["10", "9", "100", "1"]), ["1", "9", "10", "100"])
        XCTAssertEqual("".naturalCompare(""), .orderedSame)
        XCTAssertTrue("".naturallyPrecedes("a"))
    }

    func testTreeSortsEachFolderLevel() {
        let branches = [
            "social/ZSOC-1056-a",
            "social/ZSOC-153-b",
            "social/nested/ZSOC-90-c",
            "social/nested/ZSOC-1000-d",
            "ZSOC-2-top",
            "ZSOC-10-top",
        ].map { GitBranch(name: $0) }

        let tree = BranchTreeNode.build(from: branches, root: "Local Branches")
        XCTAssertEqual(tree.children.map(\.name), ["ZSOC-2-top", "ZSOC-10-top", "social"])

        let social = try? XCTUnwrap(tree.children.first { $0.name == "social" })
        XCTAssertEqual(social?.children.map(\.name), ["ZSOC-153-b", "ZSOC-1056-a", "nested"])

        let nested = social?.children.first { $0.name == "nested" }
        XCTAssertEqual(nested?.children.map(\.name), ["ZSOC-90-c", "ZSOC-1000-d"])
    }
}
