import XCTest
@testable import SmallGit

/// Covers the FINAL line of the resolver's line inspector — what the merged
/// file ends up holding at one aligned row.
///
/// The three panes answer "what does each side have here". This answers "and
/// what will the file have", which is the question being asked when a
/// conflict is read line by line, and the one the resolver could not answer
/// without going and reading the merged pane.
final class ConflictRowOutcomeTests: XCTestCase {

    private func row(
        id: Int = 0,
        ours: String?,
        base: String?,
        theirs: String?,
        isChange: Bool = true
    ) -> ConflictLineRow {
        ConflictLineRow(
            id: id,
            ours: ours.map { ConflictLineCell(lineNumber: 1, text: $0) },
            base: base.map { ConflictLineCell(lineNumber: 1, text: $0) },
            theirs: theirs.map { ConflictLineCell(lineNumber: 1, text: $0) },
            isChange: isChange
        )
    }

    private let chunk = UUID()

    func testARowOutsideEveryConflictIsUnchanged() {
        let outcome = ConflictRowOutcome.compute(
            row: row(ours: "same", base: "same", theirs: "same", isChange: false),
            chunkID: nil,
            resolution: .unresolved
        )
        XCTAssertEqual(outcome, .unchanged("same"), "context survives whatever is decided elsewhere")
    }

    func testAnUndecidedChunkSaysSoRatherThanGuessing() {
        let outcome = ConflictRowOutcome.compute(
            row: row(ours: "mine", base: "was", theirs: "yours"),
            chunkID: chunk,
            resolution: .unresolved
        )
        XCTAssertEqual(outcome, .undecided, "the markers are still in the file; there is no final line yet")
    }

    func testEachSideProducesItsOwnLine() {
        let r = row(ours: "mine", base: "was", theirs: "yours")
        XCTAssertEqual(ConflictRowOutcome.compute(row: r, chunkID: chunk, resolution: .ours), .resolved(["mine"]))
        XCTAssertEqual(ConflictRowOutcome.compute(row: r, chunkID: chunk, resolution: .base), .resolved(["was"]))
        XCTAssertEqual(ConflictRowOutcome.compute(row: r, chunkID: chunk, resolution: .theirs), .resolved(["yours"]))
    }

    func testKeepingBothSidesKeepsTheOrderThatWasChosen() {
        let r = row(ours: "mine", base: "was", theirs: "yours")
        XCTAssertEqual(
            ConflictRowOutcome.compute(row: r, chunkID: chunk, resolution: .bothOursFirst),
            .resolved(["mine", "yours"])
        )
        XCTAssertEqual(
            ConflictRowOutcome.compute(row: r, chunkID: chunk, resolution: .bothTheirsFirst),
            .resolved(["yours", "mine"])
        )
    }

    func testNeitherLeavesNothingBehind() {
        let outcome = ConflictRowOutcome.compute(
            row: row(ours: "mine", base: "was", theirs: "yours"),
            chunkID: chunk,
            resolution: .neither
        )
        XCTAssertEqual(outcome, .removed, "distinct from base, which puts the ancestor back")
    }

    func testTakingASideThatHasNoLineHereContributesNothing() {
        // Ours added a line theirs never had. Taking theirs means this row
        // contributes nothing at all — which is a real answer, and not the
        // same as the chunk being deleted.
        let outcome = ConflictRowOutcome.compute(
            row: row(ours: "line only we have", base: nil, theirs: nil),
            chunkID: chunk,
            resolution: .theirs
        )
        XCTAssertEqual(outcome, .resolved([]))
        XCTAssertNotEqual(outcome, .removed)
    }

    func testAnAbsentAncestorStillReadsAsContextOutsideAConflict() {
        // add/add conflicts have no base at all; a context row there is
        // whatever the sides agree on.
        let outcome = ConflictRowOutcome.compute(
            row: row(ours: "agreed", base: nil, theirs: "agreed", isChange: false),
            chunkID: nil,
            resolution: .unresolved
        )
        XCTAssertEqual(outcome, .unchanged("agreed"))
    }
}

/// The same FINAL line, but read out of the live merged buffer.
///
/// The merged pane is editable, and the moment someone types in it the
/// button that was pressed and the file's actual contents are two different
/// answers. The inspector showed the first, so a hand edit left it stating
/// something that was no longer in the file.
@MainActor
final class ConflictFinalLineTests: XCTestCase {

    private let conflicted = """
    before
    <<<<<<< HEAD
    ours line 1
    ours line 2
    ||||||| merged common ancestors
    base line
    =======
    theirs line 1
    theirs line 2
    >>>>>>> feature
    after
    """

    private func makeViewModel() -> ConflictResolutionViewModel {
        let viewModel = ConflictResolutionViewModel(
            git: GitService.shared,
            coordinator: CacheCoordinator()
        )
        viewModel.loadForTesting(conflicted)
        // The three blobs the panes show, which is where the highlight ranges
        // that anchor a row to its chunk come from.
        viewModel.oursText = "before\nours line 1\nours line 2\nafter\n"
        viewModel.baseText = "before\nbase line\nafter\n"
        viewModel.theirsText = "before\ntheirs line 1\ntheirs line 2\nafter\n"
        viewModel.hasBase = true
        return viewModel
    }

    /// The chunk's first line, as the panes would hand it over: line 2 of
    /// each side's blob.
    private func firstConflictRow() -> ConflictLineRow {
        ConflictLineRow(
            id: 0,
            ours: ConflictLineCell(lineNumber: 2, text: "ours line 1"),
            base: ConflictLineCell(lineNumber: 2, text: "base line"),
            theirs: ConflictLineCell(lineNumber: 2, text: "theirs line 1"),
            isChange: true
        )
    }

    func testFinalIsTheLineTheResolutionPutInTheFile() throws {
        let vm = makeViewModel()
        let chunk = try XCTUnwrap(vm.chunks.first)
        vm.resolve(chunk: chunk, to: .theirs)

        XCTAssertEqual(
            vm.outcome(forRow: firstConflictRow(), chunkID: chunk.id),
            .resolved(["theirs line 1"])
        )
    }

    func testEditingThatLineByHandIsWhatFinalShows() throws {
        let vm = makeViewModel()
        let chunk = try XCTUnwrap(vm.chunks.first)
        vm.resolve(chunk: chunk, to: .theirs)

        // The polish pass: typing on the end of a line the buttons produced.
        vm.mergedText = vm.mergedText.replacingOccurrences(
            of: "theirs line 1", with: "theirs line 1 with a hand edit"
        )

        XCTAssertEqual(
            vm.outcome(forRow: firstConflictRow(), chunkID: chunk.id),
            .edited(["theirs line 1 with a hand edit"]),
            "the file's answer, not the button's"
        )
    }

    func testAddingALineSaysSoRatherThanPointingAtTheWrongOne() throws {
        let vm = makeViewModel()
        let chunk = try XCTUnwrap(vm.chunks.first)
        vm.resolve(chunk: chunk, to: .theirs)

        // Every line index past this one has moved, so any answer would be a
        // guess about which line the row became.
        vm.mergedText = "a new first line\n" + vm.mergedText

        XCTAssertEqual(
            vm.outcome(forRow: firstConflictRow(), chunkID: chunk.id),
            .unmappable
        )
    }

    func testTakingBothSidesReadsBothLinesBack() throws {
        let vm = makeViewModel()
        let chunk = try XCTUnwrap(vm.chunks.first)
        vm.resolve(chunk: chunk, to: .bothOursFirst)

        XCTAssertEqual(
            vm.outcome(forRow: firstConflictRow(), chunkID: chunk.id),
            .resolved(["ours line 1", "theirs line 1"]),
            "the row contributes a line to each half of the block"
        )
    }

    func testAnUndecidedChunkHasNothingToReadYet() throws {
        let vm = makeViewModel()
        let chunk = try XCTUnwrap(vm.chunks.first)

        XCTAssertEqual(vm.outcome(forRow: firstConflictRow(), chunkID: chunk.id), .undecided)
    }

    func testARowOutsideTheChunkIsStillContext() throws {
        let vm = makeViewModel()
        let row = ConflictLineRow(
            id: 9,
            ours: ConflictLineCell(lineNumber: 1, text: "before"),
            base: ConflictLineCell(lineNumber: 1, text: "before"),
            theirs: ConflictLineCell(lineNumber: 1, text: "before"),
            isChange: false
        )
        XCTAssertEqual(vm.outcome(forRow: row, chunkID: nil), .unchanged("before"))
    }
}
