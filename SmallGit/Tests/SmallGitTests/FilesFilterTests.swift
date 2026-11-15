import XCTest
@testable import SmallGit

/// Verifies the per-file-type filter toggles on FilesViewModel —
/// conflicts always pass through, ignored is off by default, etc.
@MainActor
final class FilesFilterTests: XCTestCase {

    // MARK: - Fixtures

    private func makeViewModel(with files: [GitFileStatus]) -> FilesViewModel {
        let vm = FilesViewModel(coordinator: CacheCoordinator())
        vm.files = files
        return vm
    }

    private func staged(_ path: String, letter: String = "M") -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: letter, workTreeStatus: ".")
    }

    private func unstaged(_ path: String, letter: String = "M") -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: ".", workTreeStatus: letter)
    }

    private func untracked(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: "?", workTreeStatus: "?")
    }

    private func ignored(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: "!", workTreeStatus: "!")
    }

    private func conflict(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: "U", workTreeStatus: "U", isConflict: true)
    }

    // MARK: - Tests

    func testDefaultFlagsHideIgnoredButShowEverythingElse() {
        // Sanity-check the out-of-the-box defaults so future changes
        // don't silently flip what a fresh user sees.
        let vm = FilesViewModel(coordinator: CacheCoordinator())
        XCTAssertTrue(vm.showStaged)
        XCTAssertTrue(vm.showUnstaged)
        XCTAssertTrue(vm.showUntracked)
        XCTAssertFalse(vm.showIgnored,
            "ignored files are noisy and should be off by default")
    }

    func testHidingUntrackedRemovesOnlyUntrackedRows() {
        let vm = makeViewModel(with: [
            staged("a.swift"),
            unstaged("b.swift"),
            untracked("temp.log"),
            untracked("draft.txt"),
        ])
        vm.showUntracked = false
        let visible = vm.filteredFiles.map(\.path)
        XCTAssertEqual(Set(visible), Set(["a.swift", "b.swift"]))
    }

    func testIgnoredHiddenByDefaultEvenWhenInList() {
        // The view model may temporarily hold ignored entries after
        // toggling `showIgnored` off without a re-fetch — they must
        // still be filtered out.
        let vm = makeViewModel(with: [
            staged("a.swift"),
            ignored(".DS_Store"),
            ignored("build/output"),
        ])
        XCTAssertFalse(vm.showIgnored)
        let visible = vm.filteredFiles.map(\.path)
        XCTAssertEqual(visible, ["a.swift"])
    }

    func testEnablingShowIgnoredSurfacesIgnoredRows() {
        let vm = makeViewModel(with: [
            staged("a.swift"),
            ignored(".DS_Store"),
        ])
        vm.showIgnored = true
        let visible = Set(vm.filteredFiles.map(\.path))
        XCTAssertEqual(visible, Set(["a.swift", ".DS_Store"]))
    }

    func testHidingStagedKeepsUnstagedAndUntracked() {
        let vm = makeViewModel(with: [
            staged("a.swift"),
            unstaged("b.swift"),
            untracked("c.swift"),
        ])
        vm.showStaged = false
        let visible = Set(vm.filteredFiles.map(\.path))
        XCTAssertEqual(visible, Set(["b.swift", "c.swift"]))
    }

    func testConflictsAlwaysVisibleRegardlessOfTypeToggles() {
        // A conflicted file MUST surface no matter which toggles are
        // off — there's no useful workflow for hiding a file the
        // user has to resolve before they can commit.
        let vm = makeViewModel(with: [
            staged("a.swift"),
            unstaged("b.swift"),
            conflict("c.swift"),
        ])
        vm.showStaged = false
        vm.showUnstaged = false
        vm.showUntracked = false
        let visible = vm.filteredFiles.map(\.path)
        XCTAssertEqual(visible, ["c.swift"],
            "conflicts must always be visible, got \(visible)")
    }

    func testTextFilterCombinesWithTypeFilter() {
        // Both filters apply — type toggle removes ignored, then the
        // text query narrows what's left.
        let vm = makeViewModel(with: [
            staged("src/foo.swift"),
            staged("src/bar.swift"),
            ignored("build/foo.o"),
            untracked("draft/foo.txt"),
        ])
        vm.filterText = "foo"
        // showIgnored false → only the .o is dropped at the type
        // step; text filter then keeps src/foo.swift and draft/foo.txt.
        let visible = Set(vm.filteredFiles.map(\.path))
        XCTAssertEqual(visible, Set(["src/foo.swift", "draft/foo.txt"]))
    }
}
