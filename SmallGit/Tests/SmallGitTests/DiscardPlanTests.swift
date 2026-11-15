import XCTest
@testable import SmallGit

/// The reported bug: a Files-panel selection holding an untracked file made
/// Discard do nothing at all — not even to the files it could have discarded.
///
/// Cause: one `git checkout -- <every selected path>`. Git validates every
/// pathspec before it touches the working tree, so an untracked path ("did
/// not match any file(s) known to git") or a conflicted one ("path ... is
/// unmerged") aborts the command whole. Splitting the selection by what git
/// can actually do to each file is the fix.
@MainActor
final class DiscardPlanTests: XCTestCase {

    private func makeViewModel(with files: [GitFileStatus]) -> FilesViewModel {
        let vm = FilesViewModel(coordinator: CacheCoordinator())
        vm.files = files
        vm.selectedFileIDs = Set(files.map(\.id))
        return vm
    }

    private func modified(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: ".", workTreeStatus: "M")
    }

    private func untracked(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: "?", workTreeStatus: "?")
    }

    private func conflicted(_ path: String) -> GitFileStatus {
        GitFileStatus(path: path, indexStatus: "U", workTreeStatus: "U", isConflict: true)
    }

    /// The exact shape from the report: staged and modified files, one
    /// conflict, two untracked. Each lands in the bucket whose git command
    /// can discard it.
    func testMixedSelectionSplitsThreeWays() {
        let vm = makeViewModel(with: [
            modified("a.ts"),
            conflicted("index.ts"),
            untracked("EmojiStatusRemoteConfig.ts"),
            untracked("GetRemoteConfigUseCase.ts"),
        ])
        let plan = vm.selectedDiscardPlan
        XCTAssertEqual(plan.tracked, ["a.ts"])
        XCTAssertEqual(plan.conflicted, ["index.ts"])
        XCTAssertEqual(plan.untracked, ["EmojiStatusRemoteConfig.ts", "GetRemoteConfigUseCase.ts"])
    }

    /// Ignored files are deleted like untracked ones: git isn't storing them
    /// either, so there is nothing to restore them from.
    func testIgnoredFilesAreTreatedAsUntracked() {
        let vm = makeViewModel(with: [GitFileStatus(path: "build.log", indexStatus: "!", workTreeStatus: "!")])
        XCTAssertEqual(vm.selectedDiscardPlan.untracked, ["build.log"])
    }

    func testUnselectedFilesAreLeftOut() {
        let vm = makeViewModel(with: [modified("a.ts"), untracked("b.ts")])
        vm.selectedFileIDs = [vm.files[0].id]
        let plan = vm.selectedDiscardPlan
        XCTAssertEqual(plan.tracked, ["a.ts"])
        XCTAssertTrue(plan.untracked.isEmpty)
    }

    /// The consequence git cannot undo has to be stated, not folded into a
    /// general "discard the selected files".
    func testConfirmationNamesTheIrreversiblePart() {
        let vm = makeViewModel(with: [modified("a.ts"), untracked("b.ts")])
        let message = vm.selectedDiscardPlan.confirmationMessage
        XCTAssertTrue(message.contains("Discards uncommitted changes in 1 file."))
        XCTAssertTrue(message.contains("Permanently deletes 1 file"))
        XCTAssertTrue(message.contains("cannot be undone"))
    }

    func testConfirmationMentionsOnlyWhatIsSelected() {
        let vm = makeViewModel(with: [modified("a.ts")])
        let message = vm.selectedDiscardPlan.confirmationMessage
        XCTAssertEqual(message, "Discards uncommitted changes in 1 file.")
    }
}
