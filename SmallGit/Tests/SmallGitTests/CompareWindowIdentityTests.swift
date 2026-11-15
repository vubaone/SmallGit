import XCTest
@testable import SmallGit

/// Covers which compare requests share a window and which get their own.
///
/// The presenter keys open windows by id, so these strings *are* the dedup
/// rule. Getting one wrong doesn't fail loudly — it either opens a second
/// window for something already on screen, or refuses to open a genuinely
/// different comparison because it thinks that window exists.
@MainActor
final class CompareWindowIdentityTests: XCTestCase {

    func testTheSameFileReusesItsWindow() {
        XCTAssertEqual(
            CompareWindowPresenter.fileCompareID(path: "src/main.swift"),
            CompareWindowPresenter.fileCompareID(path: "src/main.swift")
        )
    }

    func testMultiFileRequestPreservesDisplayOrderAndDropsDuplicates() {
        let target = AppState.CompareTarget(paths: [
            "web/index.html",
            "web/SampleContent.ts",
            "web/index.html",
            "web/index.ts"
        ])

        XCTAssertEqual(target.paths, [
            "web/index.html",
            "web/SampleContent.ts",
            "web/index.ts"
        ])
    }

    func testSingleFileRequestUsesTheBatchShape() {
        XCTAssertEqual(
            AppState.CompareTarget(path: "src/main.swift").paths,
            ["src/main.swift"]
        )
    }

    func testDifferentFilesGetDifferentWindows() {
        XCTAssertNotEqual(
            CompareWindowPresenter.fileCompareID(path: "src/a.swift"),
            CompareWindowPresenter.fileCompareID(path: "src/b.swift")
        )
    }

    /// The same file at two revisions is two different comparisons, and
    /// looking at them side by side is the point of opening both.
    func testTheSameFileAtDifferentCommitsGetsSeparateWindows() {
        XCTAssertNotEqual(
            CompareWindowPresenter.commitCompareID(commitHash: "aaa111", path: "src/main.swift"),
            CompareWindowPresenter.commitCompareID(commitHash: "bbb222", path: "src/main.swift")
        )
    }

    func testTheSameCommitAndFileReusesItsWindow() {
        XCTAssertEqual(
            CompareWindowPresenter.commitCompareID(commitHash: "aaa111", path: "src/main.swift"),
            CompareWindowPresenter.commitCompareID(commitHash: "aaa111", path: "src/main.swift")
        )
    }

    /// A working-tree compare and a historical one for the same path are
    /// different windows — opening one must not raise the other.
    func testWorkingAndHistoricalComparesDoNotCollide() {
        XCTAssertNotEqual(
            CompareWindowPresenter.fileCompareID(path: "src/main.swift"),
            CompareWindowPresenter.commitCompareID(commitHash: "aaa111", path: "src/main.swift")
        )
    }

    /// The commit dialog's HEAD-vs-index preview is a different comparison
    /// from the working-tree compare of the same file, and from the same
    /// path in another repository.
    func testStagedCompareHasItsOwnWindow() {
        XCTAssertNotEqual(
            CompareWindowPresenter.stagedCompareID(path: "src/main.swift", repoPath: "/r"),
            CompareWindowPresenter.fileCompareID(path: "src/main.swift", repoPath: "/r")
        )
        XCTAssertNotEqual(
            CompareWindowPresenter.stagedCompareID(path: "src/main.swift", repoPath: "/r"),
            CompareWindowPresenter.stagedCompareID(path: "src/main.swift", repoPath: "/other")
        )
    }

    /// The id has to keep agreeing with `AppState.CommitCompareTarget.id`,
    /// which the Log window's opener still routes through, for the
    /// one-file request a double-click makes.
    func testIdMatchesTheRequestTargetItIsBuiltFrom() {
        let commit = GitCommit(
            hash: "aaa111", shortHash: "aaa111", subject: "s",
            authorName: "a", authorEmail: "a@a", date: Date(),
            refs: "", parentHashes: []
        )
        let target = AppState.CommitCompareTarget(commit: commit, paths: ["src/main.swift"])
        XCTAssertEqual(
            CompareWindowPresenter.commitCompareID(commitHash: commit.hash, path: "src/main.swift"),
            "commit-compare:" + target.id
        )
    }
}
