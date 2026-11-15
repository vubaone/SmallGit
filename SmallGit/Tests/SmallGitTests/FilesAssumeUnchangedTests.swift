import XCTest
@testable import SmallGit

/// The assume-unchanged view: a file git has been told to stop checking is
/// absent from `git status` by design, so the Files panel reads the flags
/// out of the index separately and lists them behind their own toggle.
@MainActor
final class FilesAssumeUnchangedTests: XCTestCase {

    private let changed: [GitFileStatus] = [
        GitFileStatus(path: "Sources/App.swift", indexStatus: ".", workTreeStatus: "M"),
        GitFileStatus(path: "package.yml", indexStatus: "M", workTreeStatus: ".")
    ]

    private let flagged = ["config/local.yml", "Sources/Secrets.swift"]

    private func makeVM() -> FilesViewModel {
        let vm = FilesViewModel(coordinator: CacheCoordinator())
        vm.files = changed
        vm.setAssumeUnchangedPathsForTesting(flagged)
        return vm
    }

    // MARK: - Parsing `ls-files -v`

    /// git encodes the flag as *case*, not as one particular tag letter:
    /// the entry's usual tag is lowercased when it is assume-unchanged.
    func testLowercaseTagsAreTheFlaggedFiles() {
        let raw = "H kept.txt\0h flagged.txt\0S skipped.txt\0s skipped-and-flagged.txt\0"
        XCTAssertEqual(
            GitOutputParser.parseAssumeUnchanged(raw),
            ["flagged.txt", "skipped-and-flagged.txt"]
        )
    }

    func testUppercaseTagsAreNotFlagged() {
        let raw = "H a.txt\0S b.txt\0M c.txt\0R d.txt\0"
        XCTAssertTrue(GitOutputParser.parseAssumeUnchanged(raw).isEmpty)
    }

    func testPathsWithSpacesSurvive() {
        let raw = "h d/with space.txt\0H other.txt\0"
        XCTAssertEqual(GitOutputParser.parseAssumeUnchanged(raw), ["d/with space.txt"])
    }

    /// The service asks for `-z`, but the parser accepts newline records so
    /// fixtures can be written readably.
    func testNewlineDelimitedOutputParsesToo() {
        let raw = "h one.txt\nH two.txt\nh three.txt\n"
        XCTAssertEqual(GitOutputParser.parseAssumeUnchanged(raw), ["one.txt", "three.txt"])
    }

    func testEmptyAndMalformedRecordsAreSkipped() {
        XCTAssertTrue(GitOutputParser.parseAssumeUnchanged("").isEmpty)
        // No path after the tag, and a tag with no separating space.
        XCTAssertTrue(GitOutputParser.parseAssumeUnchanged("h \0hnospace.txt\0").isEmpty)
    }

    // MARK: - The view

    func testFlaggedFilesStayHiddenUntilTheViewIsOn() {
        let vm = makeVM()
        XCTAssertEqual(vm.filteredFiles.map(\.path), changed.map(\.path))
    }

    func testFlaggedFilesAreAppendedAfterTheChangedOnes() {
        let vm = makeVM()
        vm.showAssumeUnchanged = true
        XCTAssertEqual(
            vm.filteredFiles.map(\.path),
            ["Sources/App.swift", "package.yml", "config/local.yml", "Sources/Secrets.swift"]
        )
    }

    func testFlaggedRowsSayWhyTheyAreThere() {
        let vm = makeVM()
        vm.showAssumeUnchanged = true
        let row = vm.filteredFiles.first { $0.path == "config/local.yml" }
        XCTAssertEqual(row?.isAssumeUnchanged, true)
        XCTAssertEqual(row?.stateDisplay, "Assume unchanged")
        XCTAssertEqual(row?.state, .unmodified)
    }

    /// Flagging a file after staging it leaves the staged entry in status.
    /// That row is already on screen with its real state and must not be
    /// listed a second time as an unchanged one.
    func testAFlaggedFileAlreadyInStatusIsNotListedTwice() {
        let vm = makeVM()
        vm.setAssumeUnchangedPathsForTesting(["package.yml", "config/local.yml"])
        vm.showAssumeUnchanged = true
        XCTAssertEqual(
            vm.filteredFiles.map(\.path),
            ["Sources/App.swift", "package.yml", "config/local.yml"]
        )
        XCTAssertEqual(vm.filteredFiles.first { $0.path == "package.yml" }?.stateDisplay,
                       "Staged",
                       "the changed row wins — its state is the fact that matters")
    }

    func testTheFilterNarrowsTheFlaggedListToo() {
        let vm = makeVM()
        vm.showAssumeUnchanged = true
        vm.filterText = "local"
        XCTAssertEqual(vm.filteredFiles.map(\.path), ["config/local.yml"])
    }

    /// A flagged file is a tracked file, so it is also in the find-file
    /// list the filter searches. Whichever list puts it on screen, it
    /// appears once — and as the flagged row, which says more.
    func testAFlaggedFileMatchingTheFilterIsNotDuplicatedByFindFile() {
        let vm = makeVM()
        vm.setTrackedPathsForTesting(
            ["Sources/App.swift", "package.yml", "config/local.yml", "config/other.yml"]
        )
        vm.showAssumeUnchanged = true
        vm.filterText = "config"
        XCTAssertEqual(vm.filteredFiles.map(\.path), ["config/local.yml", "config/other.yml"])
        XCTAssertEqual(vm.filteredFiles.first?.isAssumeUnchanged, true)
        XCTAssertEqual(vm.filteredFiles.last?.isAssumeUnchanged, false)
    }

    /// The four type toggles filter what `git status` reported; a flagged
    /// file was never in that report, so they have no say over it.
    func testTypeTogglesDoNotHideFlaggedFiles() {
        let vm = makeVM()
        vm.showAssumeUnchanged = true
        vm.showStaged = false
        vm.showUnstaged = false
        vm.showUntracked = false
        XCTAssertEqual(vm.filteredFiles.map(\.path), flagged)
    }

    func testSortAppliesAcrossChangedAndFlagged() {
        let vm = makeVM()
        vm.showAssumeUnchanged = true
        vm.sortOrder = [FileSortComparator(field: .name, order: .forward)]
        XCTAssertEqual(vm.filteredFiles.map(\.name),
                       ["App.swift", "local.yml", "package.yml", "Secrets.swift"])
    }

    func testSwitchingRepositoryDropsTheFlagList() {
        let vm = makeVM()
        vm.showAssumeUnchanged = true
        vm.clearAssumeUnchangedPaths()
        XCTAssertTrue(vm.filteredFiles.allSatisfy { !$0.isAssumeUnchanged },
                      "another repository's flags must not survive the switch")
    }

    // MARK: - Invalidation

    /// The flags live in `.git/index`, so a `git update-index` run in a
    /// terminal has to show up in the panel.
    func testAnIndexWriteRetiresTheFlagList() {
        let keys = InvalidationEngine.keysToInvalidate(
            changedPath: "/repo/.git/index",
            repoRoot: "/repo"
        )
        XCTAssertTrue(keys.contains(.assumeUnchangedFiles))
    }

    /// Setting the flag empties the file's diff whatever is in it, so a
    /// cached diff for that path is now wrong.
    func testSettingTheFlagRetiresTheFlagListAndThePathsDiffs() {
        let keys = InvalidationEngine.keysAfter(.assumeUnchanged(files: ["a.txt"]))
        XCTAssertTrue(keys.contains(.assumeUnchangedFiles))
        XCTAssertTrue(keys.contains(.fileStatus))
        for mode in DiffCompareMode.allCases {
            XCTAssertTrue(keys.contains(.diff(file: "a.txt", mode: mode, compact: true)))
            XCTAssertTrue(keys.contains(.diff(file: "a.txt", mode: mode, compact: false)))
        }
    }
}
