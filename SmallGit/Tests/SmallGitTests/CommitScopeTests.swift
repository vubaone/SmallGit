import XCTest
@testable import SmallGit

/// Covers what the commit dialog opens on — which tab, and which rows
/// start ticked — for the combinations of index and Files-panel selection.
final class CommitScopeTests: XCTestCase {

    // MARK: - Fixtures

    private func staged(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: "M", workTreeStatus: ".")
    }

    private func stagedThenEdited(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: "M", workTreeStatus: "M")
    }

    private func unstaged(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: ".", workTreeStatus: "M")
    }

    private func untracked(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: "?", workTreeStatus: "?")
    }

    private func unchanged(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: ".", workTreeStatus: ".")
    }

    private func ignored(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: "!", workTreeStatus: "!")
    }

    private func conflicted(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: "U", workTreeStatus: "U", isConflict: true)
    }

    // MARK: - No selection

    func testNoSelectionOpensOnTheIndex() {
        let scope = CommitScope.opening(
            files: [staged("a.swift"), unstaged("b.swift"), untracked("c.swift")],
            selectedPaths: []
        )
        XCTAssertEqual(scope.mode, .staged)
        XCTAssertEqual(scope.includedPaths, ["a.swift"])
    }

    func testNoSelectionWithEmptyIndexFallsBackToLocalChanges() {
        // Nothing staged: opening on the "Nothing staged" empty state would
        // make the user find the radio before they can do anything.
        let scope = CommitScope.opening(
            files: [unstaged("b.swift"), untracked("c.swift")],
            selectedPaths: []
        )
        XCTAssertEqual(scope.mode, .local)
        XCTAssertEqual(scope.includedPaths, ["b.swift", "c.swift"])
    }

    func testCleanTreeOpensEmpty() {
        let scope = CommitScope.opening(files: [], selectedPaths: [])
        XCTAssertEqual(scope.mode, .staged)
        XCTAssertTrue(scope.includedPaths.isEmpty)
    }

    // MARK: - Selection reaching outside the index

    func testSelectAllCombinesTheIndexWithTheSelection() {
        // The reported case: one file staged, select-all in the Files
        // panel, Commit. All four should be offered, not the staged one.
        let files = [
            unstaged("ZInstantBundleUtils.swift"),
            unstaged("ZMediaTransitioningParameters.m"),
            staged("UXStoryMediaPage.m"),
            untracked("ZInstantTemplateView.swift"),
        ]
        let scope = CommitScope.opening(files: files, selectedPaths: files.map(\.path))
        XCTAssertEqual(scope.mode, .local)
        XCTAssertEqual(scope.includedPaths, Set(files.map(\.path)))
    }

    func testUnstagedSelectionKeepsTheStagedSetTicked() {
        // Adding to what's already staged, not replacing it.
        let scope = CommitScope.opening(
            files: [staged("a.swift"), unstaged("b.swift"), unstaged("c.swift")],
            selectedPaths: ["b.swift"]
        )
        XCTAssertEqual(scope.mode, .local)
        XCTAssertEqual(scope.includedPaths, ["a.swift", "b.swift"])
        XCTAssertFalse(scope.includedPaths.contains("c.swift"))
    }

    // MARK: - Selection inside the index

    func testSelectingPartOfTheIndexCommitsOnlyThatPart() {
        let scope = CommitScope.opening(
            files: [staged("a.swift"), staged("b.swift"), staged("c.swift")],
            selectedPaths: ["a.swift", "c.swift"]
        )
        XCTAssertEqual(scope.mode, .staged)
        XCTAssertEqual(scope.includedPaths, ["a.swift", "c.swift"])
    }

    func testOneClickedStagedRowDoesNotCarveUpTheIndex() {
        // Clicking a single row is how the Files panel is asked for a
        // diff. If that narrowed the scope, looking at a staged file and
        // then committing would unstage everything else in the index.
        let scope = CommitScope.opening(
            files: [staged("a.swift"), staged("b.swift"), staged("c.swift")],
            selectedPaths: ["a.swift"]
        )
        XCTAssertEqual(scope.mode, .staged)
        XCTAssertEqual(scope.includedPaths, ["a.swift", "b.swift", "c.swift"])
    }

    func testOneClickedStagedRowStillDoesNotNarrowWithLocalChangesAround() {
        let scope = CommitScope.opening(
            files: [staged("a.swift"), staged("b.swift"), unstaged("c.swift")],
            selectedPaths: ["b.swift"]
        )
        XCTAssertEqual(scope.mode, .staged)
        XCTAssertEqual(scope.includedPaths, ["a.swift", "b.swift"])
    }

    func testConflictedRowsNeverCarveUpTheIndex() {
        // A conflict is `U` in the index column, which reads as staged.
        // Narrowing to one would unstage the resolutions either side of
        // it — and the commit would fail on the unmerged path anyway.
        let files = [
            staged("resolved-a.swift"),
            staged("resolved-b.swift"),
            conflicted("still-conflicted.swift"),
            conflicted("also-conflicted.swift"),
        ]
        let scope = CommitScope.opening(
            files: files,
            selectedPaths: ["still-conflicted.swift", "also-conflicted.swift"]
        )
        XCTAssertEqual(scope.mode, .staged)
        XCTAssertEqual(scope.includedPaths, Set(files.map(\.path)))
    }

    func testSelectingTheWholeIndexIsTheSameAsSelectingNothing() {
        let files = [staged("a.swift"), staged("b.swift")]
        let scope = CommitScope.opening(files: files, selectedPaths: files.map(\.path))
        XCTAssertEqual(scope.mode, .staged)
        XCTAssertEqual(scope.includedPaths, ["a.swift", "b.swift"])
    }

    func testStagedThenEditedFileCountsAsPartOfTheIndex() {
        // "Staged + Modified" — the staged half is what the Staged tab
        // commits, so selecting it alone shouldn't drag in local changes.
        let scope = CommitScope.opening(
            files: [stagedThenEdited("a.swift"), unstaged("b.swift")],
            selectedPaths: ["a.swift"]
        )
        XCTAssertEqual(scope.mode, .staged)
        XCTAssertEqual(scope.includedPaths, ["a.swift"])
    }

    // MARK: - Rows that can't be committed

    func testSelectionOfUncommittableRowsIsIgnored() {
        // The Files filter doubles as a find-file and turns up unchanged
        // tracked paths; selecting one is not a statement about a commit.
        let scope = CommitScope.opening(
            files: [staged("a.swift"), unchanged("docs/README.md")],
            selectedPaths: ["docs/README.md"]
        )
        XCTAssertEqual(scope.mode, .staged)
        XCTAssertEqual(scope.includedPaths, ["a.swift"])
    }

    func testIgnoredRowsAreNeverPartOfACommit() {
        // `!` in the index column passes `isStaged`, so an ignored file
        // reads as part of the index unless it's excluded by name.
        let scope = CommitScope.opening(
            files: [staged("a.swift"), ignored("build.log")],
            selectedPaths: []
        )
        XCTAssertEqual(scope.mode, .staged)
        XCTAssertEqual(scope.includedPaths, ["a.swift"])
    }

    func testSelectingIgnoredRowsLeavesTheIndexAlone() {
        let scope = CommitScope.opening(
            files: [staged("a.swift"), staged("b.swift"), ignored("build.log"), ignored("tmp.o")],
            selectedPaths: ["build.log", "tmp.o"]
        )
        XCTAssertEqual(scope.mode, .staged)
        XCTAssertEqual(scope.includedPaths, ["a.swift", "b.swift"])
    }

    func testUncommittableRowsDropOutOfAMixedSelection() {
        let scope = CommitScope.opening(
            files: [staged("a.swift"), unstaged("b.swift"), unchanged("docs/README.md")],
            selectedPaths: ["b.swift", "docs/README.md"]
        )
        XCTAssertEqual(scope.mode, .local)
        XCTAssertEqual(scope.includedPaths, ["a.swift", "b.swift"])
    }
}
