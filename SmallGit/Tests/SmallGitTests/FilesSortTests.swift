import XCTest
@testable import SmallGit

/// Covers the click-to-sort headers on the Files table: the comparator
/// itself, and how `filteredFiles` layers sorting on top of the filters.
@MainActor
final class FilesSortTests: XCTestCase {

    // MARK: - Fixtures

    private func staged(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: "M", workTreeStatus: ".")
    }

    private func unstaged(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: ".", workTreeStatus: "M")
    }

    private func untracked(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: "?", workTreeStatus: "?")
    }

    private func makeViewModel(_ files: [GitFileStatus]) -> FilesViewModel {
        let vm = FilesViewModel(coordinator: CacheCoordinator())
        vm.files = files
        return vm
    }

    // MARK: - Default

    func testUnsortedKeepsGitOrder() {
        // No header clicked yet: the rows stay in the order git reported
        // them, which is what the panel showed before sorting existed.
        let vm = makeViewModel([staged("src/b.swift"), staged("src/a.swift")])
        XCTAssertEqual(vm.filteredFiles.map(\.name), ["b.swift", "a.swift"])
    }

    // MARK: - Name

    func testSortByNameForwardAndReverse() {
        let vm = makeViewModel([
            staged("src/Charlie.swift"),
            staged("deep/nested/alpha.swift"),
            staged("bravo.swift")
        ])
        vm.sortOrder = [FileSortComparator(field: .name)]
        XCTAssertEqual(vm.filteredFiles.map(\.name),
                       ["alpha.swift", "bravo.swift", "Charlie.swift"])

        vm.sortOrder = [FileSortComparator(field: .name, order: .reverse)]
        XCTAssertEqual(vm.filteredFiles.map(\.name),
                       ["Charlie.swift", "bravo.swift", "alpha.swift"])
    }

    func testNameSortIsCaseInsensitiveAndNumeric() {
        // Sorting by raw `<` would put every capitalised name in its own
        // block and file10 ahead of file2. Neither is what a file list is
        // expected to do.
        let vm = makeViewModel([
            staged("file10.swift"), staged("File2.swift"), staged("file1.swift")
        ])
        vm.sortOrder = [FileSortComparator(field: .name)]
        XCTAssertEqual(vm.filteredFiles.map(\.name),
                       ["file1.swift", "File2.swift", "file10.swift"])
    }

    // MARK: - State

    func testSortByStateGroupsIdenticalStatesTogether() {
        let vm = makeViewModel([
            unstaged("a.swift"), untracked("b.swift"),
            staged("c.swift"), untracked("d.swift"), staged("e.swift")
        ])
        vm.sortOrder = [FileSortComparator(field: .state)]
        // Alphabetical by what the State column actually shows:
        // Modified, Staged, Untracked.
        XCTAssertEqual(vm.filteredFiles.map(\.stateDisplay),
                       ["Modified", "Staged", "Staged", "Untracked", "Untracked"])
    }

    /// The Log window's Files column shows the short code rather than the
    /// full word, and its header sorts by the same thing. It has to: a
    /// commit's files all arrive staged, so `stateDisplay` reads "Staged"
    /// for every one of them and sorting by that would order nothing.
    func testSortByStateCodeSeparatesCommitFilesThatAllReadStaged() {
        // Built the way `commitFiles` builds them: the letter from
        // `--name-status` in the index column, nothing in the work tree one.
        func commitFile(_ path: String, _ letter: String) -> GitFileStatus {
            GitFileStatus(path: path, indexStatus: letter, workTreeStatus: ".")
        }
        let files = [
            commitFile("m.swift", "M"), commitFile("d.swift", "D"), commitFile("a.swift", "A")
        ]
        XCTAssertEqual(Set(files.map(\.stateDisplay)), ["Staged"])

        XCTAssertEqual(
            files.sorted(using: [FileSortComparator(field: .stateCode)]).map(\.state.rawValue),
            ["Add", "Del", "Mod"]
        )
        XCTAssertEqual(
            files.sorted(using: [FileSortComparator(field: .stateCode, order: .reverse)])
                .map(\.state.rawValue),
            ["Mod", "Del", "Add"]
        )
    }

    // MARK: - Directory

    func testSortByRelativeDirectory() {
        let vm = makeViewModel([
            staged("zeta/one.swift"), staged("alpha/two.swift"), staged("root.swift")
        ])
        vm.sortOrder = [FileSortComparator(field: .directory)]
        XCTAssertEqual(vm.filteredFiles.map(\.relativeDirectory), [".", "alpha", "zeta"])
    }

    // MARK: - Interaction with the filters

    func testSortAppliesAfterTextAndTypeFilters() {
        let vm = makeViewModel([
            staged("src/zulu.swift"), untracked("src/alpha.swift"),
            staged("src/mike.swift"), staged("other/kilo.txt")
        ])
        vm.showUntracked = false
        vm.filterText = "src/"
        vm.sortOrder = [FileSortComparator(field: .name)]

        // The untracked file is filtered out, the .txt outside src/ is
        // filtered out, and what's left comes back sorted.
        XCTAssertEqual(vm.filteredFiles.map(\.name), ["mike.swift", "zulu.swift"])
    }

    func testSortDoesNotDisturbSelectionOrTheUnderlyingFiles() {
        let files = [staged("b.swift"), staged("a.swift")]
        let vm = makeViewModel(files)
        vm.selectedFileIDs = ["b.swift"]
        vm.sortOrder = [FileSortComparator(field: .name)]

        XCTAssertEqual(vm.filteredFiles.map(\.name), ["a.swift", "b.swift"])
        // `files` is the source of truth for staging and selection; only
        // the presentation order changes.
        XCTAssertEqual(vm.files.map(\.name), ["b.swift", "a.swift"])
        XCTAssertEqual(vm.selectedPaths, ["b.swift"])
    }

    // MARK: - Comparator

    func testComparatorReversesEveryOutcome() {
        let forward = FileSortComparator(field: .name)
        let reverse = FileSortComparator(field: .name, order: .reverse)
        let a = staged("a.swift"), b = staged("b.swift"), a2 = staged("dir/a.swift")

        XCTAssertEqual(forward.compare(a, b), .orderedAscending)
        XCTAssertEqual(reverse.compare(a, b), .orderedDescending)
        // Equal keys stay equal in both directions, so a re-sort never
        // shuffles rows that tie.
        XCTAssertEqual(forward.compare(a, a2), .orderedSame)
        XCTAssertEqual(reverse.compare(a, a2), .orderedSame)
    }
}
