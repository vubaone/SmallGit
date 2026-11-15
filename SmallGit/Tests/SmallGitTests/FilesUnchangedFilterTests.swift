import XCTest
@testable import SmallGit

/// The Files filter as a find-file: typing searches unchanged tracked
/// files too, the way SmartGit's does, instead of only narrowing the
/// handful of rows that happen to have changed.
@MainActor
final class FilesUnchangedFilterTests: XCTestCase {

    private let changed: [GitFileStatus] = [
        GitFileStatus(path: "Sources/App.swift", indexStatus: ".", workTreeStatus: "M"),
        GitFileStatus(path: "package.yml", indexStatus: "M", workTreeStatus: ".")
    ]

    private let tracked = [
        "Sources/App.swift",
        "package.yml",
        "zdeps.yml",
        ".gitlab/ci/job.orderFile.yml",
        "README.md"
    ]

    private func makeVM() -> FilesViewModel {
        let vm = FilesViewModel(coordinator: CacheCoordinator())
        vm.files = changed
        return vm
    }

    func testUnfilteredListStaysTheChangedFilesOnly() {
        let vm = makeVM()
        XCTAssertEqual(vm.filteredFiles.map(\.path), changed.map(\.path),
            "the panel's own question is still 'what changed'")
    }

    func testMatchingUnchangedFilesAreAppended() {
        let matches = FilesViewModel.unchangedMatches(
            in: tracked, query: "yml", excluding: changed
        )
        XCTAssertEqual(matches.map(\.path), ["zdeps.yml", ".gitlab/ci/job.orderFile.yml"],
            "package.yml is already listed as a changed file")
    }

    func testUnchangedRowsReportThemselvesAsUnchanged() {
        let matches = FilesViewModel.unchangedMatches(
            in: tracked, query: "zdeps", excluding: changed
        )
        XCTAssertEqual(matches.first?.state, .unmodified)
        XCTAssertEqual(matches.first?.stateDisplay, "Unchanged")
        XCTAssertFalse(matches.first?.isStaged ?? true)
        XCTAssertFalse(matches.first?.isUnstaged ?? true)
    }

    func testAFileIsNeverListedTwice() {
        let matches = FilesViewModel.unchangedMatches(
            in: tracked, query: "app", excluding: changed
        )
        XCTAssertTrue(matches.isEmpty, "App.swift is already in the changed set")
    }

    func testMatchingIsCaseInsensitiveAndSearchesTheWholePath() {
        let matches = FilesViewModel.unchangedMatches(
            in: tracked, query: "GITLAB/CI", excluding: []
        )
        XCTAssertEqual(matches.map(\.path), [".gitlab/ci/job.orderFile.yml"])
    }

    func testAnEmptyQueryPullsInNothing() {
        XCTAssertTrue(FilesViewModel.unchangedMatches(
            in: tracked, query: "", excluding: []
        ).isEmpty)
    }

    func testFilteredListMergesChangedAndUnchanged() {
        let vm = makeVM()
        vm.filterText = "yml"
        XCTAssertEqual(vm.filteredFiles.map(\.path), ["package.yml"],
            "without the tracked list loaded the filter behaves as before")

        vm.setTrackedPathsForTesting(tracked)
        XCTAssertEqual(vm.filteredFiles.map(\.path),
                       ["package.yml", "zdeps.yml", ".gitlab/ci/job.orderFile.yml"],
            "changed first, then the rest of the working tree")
    }

    /// Type toggles are about staged/unstaged/untracked/ignored; an
    /// unchanged file is none of those and must not be filtered out by
    /// them.
    func testTypeTogglesDoNotHideUnchangedMatches() {
        let vm = makeVM()
        vm.setTrackedPathsForTesting(tracked)
        vm.filterText = "yml"
        vm.showStaged = false
        vm.showUnstaged = false
        vm.showUntracked = false
        XCTAssertEqual(vm.filteredFiles.map(\.path),
                       ["zdeps.yml", ".gitlab/ci/job.orderFile.yml"])
    }

    func testHiddenCountCoversTheWholeWorkingTree() {
        let vm = makeVM()
        vm.setTrackedPathsForTesting(tracked)
        vm.filterText = "zdeps"
        // 5 tracked files, one shown.
        XCTAssertEqual(vm.hiddenCount, 4)
    }

    func testSortAppliesAcrossBothSets() {
        let vm = makeVM()
        vm.setTrackedPathsForTesting(tracked)
        vm.filterText = "yml"
        vm.sortOrder = [FileSortComparator(field: .name, order: .forward)]
        XCTAssertEqual(vm.filteredFiles.map(\.name),
                       ["job.orderFile.yml", "package.yml", "zdeps.yml"])
    }
}
