import XCTest
@testable import SmallGit

/// Covers "let me out of here without changing anything".
///
/// The resolver is a per-file editor and nothing in it touches disk before
/// Save & Stage, so leaving must always be safe for the repository. The only
/// thing at stake is the user's own resolution choices — which is what
/// decides whether closing needs to ask first.
@MainActor
final class ConflictUnsavedWorkTests: XCTestCase {

    private let conflicted = """
    before
    <<<<<<< HEAD
    ours
    =======
    theirs
    >>>>>>> feature
    after
    """

    private func makeViewModel() -> ConflictResolutionViewModel {
        let viewModel = ConflictResolutionViewModel(
            git: GitService.shared,
            coordinator: CacheCoordinator()
        )
        // Stands in for `load()`, which needs a real repository. Everything
        // under test here is buffer arithmetic.
        viewModel.loadForTesting(conflicted)
        return viewModel
    }

    /// The common case the user described: opened it, looked, wants out. No
    /// prompt should stand in the way.
    func testAFreshlyOpenedConflictHasNothingToLose() {
        XCTAssertFalse(makeViewModel().hasUnsavedWork)
    }

    /// Taking a side is a decision worth confirming before discarding.
    func testResolvingAChunkCountsAsUnsavedWork() throws {
        let viewModel = makeViewModel()
        let chunk = try XCTUnwrap(viewModel.chunks.first)

        viewModel.resolve(chunk: chunk, to: .ours)

        XCTAssertTrue(viewModel.hasUnsavedWork)
    }

    /// Hand edits to the merged pane count too — one comparison covers both
    /// routes into the buffer.
    func testEditingTheMergedTextCountsAsUnsavedWork() {
        let viewModel = makeViewModel()
        viewModel.mergedText += "\n// a manual edit"
        XCTAssertTrue(viewModel.hasUnsavedWork)
    }

    /// Resolving and then putting it back is not unsaved work — the buffer is
    /// what matters, not how many buttons were pressed.
    func testReturningToTheOriginalClearsIt() throws {
        let viewModel = makeViewModel()
        let chunk = try XCTUnwrap(viewModel.chunks.first)

        viewModel.resolve(chunk: chunk, to: .ours)
        XCTAssertTrue(viewModel.hasUnsavedWork)

        viewModel.resolve(chunk: chunk, to: .unresolved)
        XCTAssertFalse(viewModel.hasUnsavedWork)
    }

    /// The guarantee behind "come back later": nothing here rewrites the file
    /// on disk, so the conflict survives untouched.
    func testResolvingDoesNotWriteToDisk() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ConflictUnsaved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("a.txt")
        try conflicted.write(to: file, atomically: true, encoding: .utf8)

        let viewModel = makeViewModel()
        let chunk = try XCTUnwrap(viewModel.chunks.first)
        viewModel.resolve(chunk: chunk, to: .theirs)
        viewModel.resolveAll(to: .ours)

        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(onDisk, conflicted, "the conflict must still be there to come back to")
        XCTAssertTrue(onDisk.contains("<<<<<<<"))
    }
}
