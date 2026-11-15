import XCTest
@testable import SmallGit

/// Verifies the LCS-based line aligner emits well-formed side-by-side
/// rows: same lines stay paired with the right line numbers, removed
/// lines anchor to the left only, added lines to the right only.
final class LineDiffTests: XCTestCase {

    func testIdenticalFilesProduceAllSameRows() {
        let lines = ["alpha", "bravo", "charlie"]
        let rows = LineDiff.compute(left: lines, right: lines)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .same })
        XCTAssertEqual(rows.map(\.leftLine),  [1, 2, 3])
        XCTAssertEqual(rows.map(\.rightLine), [1, 2, 3])
    }

    func testInsertedLinesAppearAsAddedOnly() {
        let left  = ["alpha", "charlie"]
        let right = ["alpha", "bravo", "charlie"]
        let rows = LineDiff.compute(left: left, right: right)
        XCTAssertEqual(rows.map(\.kind), [.same, .added, .same])

        let added = rows[1]
        XCTAssertNil(added.leftLine)
        XCTAssertEqual(added.rightLine, 2)
        XCTAssertEqual(added.rightText, "bravo")
    }

    func testRemovedLinesAppearAsRemovedOnly() {
        let left  = ["alpha", "bravo", "charlie"]
        let right = ["alpha", "charlie"]
        let rows = LineDiff.compute(left: left, right: right)
        XCTAssertEqual(rows.map(\.kind), [.same, .removed, .same])

        let removed = rows[1]
        XCTAssertEqual(removed.leftLine, 2)
        XCTAssertEqual(removed.leftText, "bravo")
        XCTAssertNil(removed.rightLine)
    }

    func testReplacementShowsAsRemovedThenAdded() {
        // A swap (`bravo` → `bee`) reads as remove old + add new — the
        // simple LCS doesn't infer "modified" semantics, and that
        // matches Beyond-Compare's default rendering.
        let left  = ["alpha", "bravo", "charlie"]
        let right = ["alpha", "bee",   "charlie"]
        let rows = LineDiff.compute(left: left, right: right)
        let kinds = rows.map(\.kind)
        XCTAssertTrue(
            kinds == [.same, .removed, .added, .same]
                || kinds == [.same, .added, .removed, .same],
            "expected one remove + one add adjacent to the change, got \(kinds)"
        )
    }

    func testEmptyLeftProducesAllAdded() {
        let rows = LineDiff.compute(left: [], right: ["a", "b"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .added })
        XCTAssertEqual(rows.map(\.rightLine), [1, 2])
    }

    func testEmptyRightProducesAllRemoved() {
        let rows = LineDiff.compute(left: ["a", "b"], right: [])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .removed })
        XCTAssertEqual(rows.map(\.leftLine), [1, 2])
    }

    func testEmptyInputsProduceEmptyOutput() {
        XCTAssertTrue(LineDiff.compute(left: [], right: []).isEmpty)
    }

    func testRowIDsAreContiguousAndInOrder() {
        // SwiftUI's ForEach + ScrollViewReader rely on IDs being
        // stable and addressable — guard against any future
        // refactor that breaks the 0..n-1 sequencing.
        let rows = LineDiff.compute(
            left:  ["a", "x", "b"],
            right: ["a", "y", "b", "c"]
        )
        XCTAssertEqual(rows.map(\.id), Array(0..<rows.count))
    }

    func testChangeAnchorsCollapseAdjacentChangesIntoOneAnchor() {
        // Three consecutive changed rows = one anchor (the first of
        // the run). Same/Same/Change/Change/Same/Change → anchors at
        // indices 2 and 5.
        let rows: [CompareRow] = [
            .init(id: 0, leftLine: 1, leftText: "a", rightLine: 1, rightText: "a"),
            .init(id: 1, leftLine: 2, leftText: "b", rightLine: 2, rightText: "b"),
            .init(id: 2, leftLine: 3, leftText: "c", rightLine: nil, rightText: nil),
            .init(id: 3, leftLine: nil, leftText: nil, rightLine: 3, rightText: "x"),
            .init(id: 4, leftLine: 4, leftText: "d", rightLine: 4, rightText: "d"),
            .init(id: 5, leftLine: nil, leftText: nil, rightLine: 5, rightText: "y"),
        ]
        XCTAssertEqual(LineDiff.changeAnchors(in: rows), [2, 5])
    }

    func testChangeAnchorsEmptyWhenNoChanges() {
        let rows: [CompareRow] = [
            .init(id: 0, leftLine: 1, leftText: "a", rightLine: 1, rightText: "a"),
            .init(id: 1, leftLine: 2, leftText: "b", rightLine: 2, rightText: "b"),
        ]
        XCTAssertTrue(LineDiff.changeAnchors(in: rows).isEmpty)
    }

    // MARK: - Word-level (intra-line) diff

    func testWordDiffMarksOnlyTheChangedIdentifier() {
        let (l, r) = WordDiff.diff(
            left:  "let foo = avatar.bar()",
            right: "let foo = avatarView.bar()"
        )
        // Both sides keep "let foo = " and ".bar()" as `.same`; only
        // the differing identifier should be flagged.
        let leftChanged = l.filter { $0.kind == .changed }.map(\.text).joined()
        let rightChanged = r.filter { $0.kind == .changed }.map(\.text).joined()
        XCTAssertEqual(leftChanged, "avatar")
        XCTAssertEqual(rightChanged, "avatarView")

        // Concatenating spans must reconstruct the original line so we
        // never lose characters in the render.
        XCTAssertEqual(l.map(\.text).joined(), "let foo = avatar.bar()")
        XCTAssertEqual(r.map(\.text).joined(), "let foo = avatarView.bar()")
    }

    func testWordDiffOnIdenticalLineIsAllSame() {
        let line = "    return x + y"
        let (l, r) = WordDiff.diff(left: line, right: line)
        XCTAssertTrue(l.allSatisfy { $0.kind == .same })
        XCTAssertTrue(r.allSatisfy { $0.kind == .same })
        XCTAssertEqual(l.map(\.text).joined(), line)
    }

    func testWordDiffHandlesPureInsertOnRight() {
        let (l, r) = WordDiff.diff(left: "", right: "added stuff")
        XCTAssertTrue(l.isEmpty)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.kind, .changed)
        XCTAssertEqual(r.first?.text, "added stuff")
    }

    func testWordDiffMergesAdjacentSameSpans() {
        // Two adjacent same tokens (word + space) should merge into
        // one span so the renderer doesn't emit redundant runs.
        let (l, _) = WordDiff.diff(
            left:  "foo bar baz",
            right: "foo bar qux"
        )
        // Expect: ["foo bar ", "baz"] — 2 spans, not 5.
        XCTAssertEqual(l.count, 2)
        XCTAssertEqual(l[0].kind, .same)
        XCTAssertEqual(l[0].text, "foo bar ")
        XCTAssertEqual(l[1].kind, .changed)
        XCTAssertEqual(l[1].text, "baz")
    }

    // MARK: - Collapse unchanged

    /// Helper — build a row marked `.same` or as a removed/added line.
    private func sameRow(_ idx: Int) -> CompareRow {
        CompareRow(id: idx, leftLine: idx + 1, leftText: "L\(idx)",
                   rightLine: idx + 1, rightText: "L\(idx)")
    }
    private func changedRow(_ idx: Int) -> CompareRow {
        CompareRow(id: idx, leftLine: idx + 1, leftText: "old",
                   rightLine: nil, rightText: nil)
    }

    func testCollapseLeavesShortFilesAlone() {
        let rows = (0..<5).map(sameRow)
        let display = LineDiff.collapse(rows: rows, contextLines: 3)
        XCTAssertEqual(display.count, 5)
        XCTAssertTrue(display.allSatisfy { if case .row = $0 { return true } else { return false } })
    }

    func testCollapseHidesUnchangedFarFromChanges() {
        // 10 unchanged + 1 changed + 10 unchanged. With contextLines = 3:
        // keep indices 7..10 (3 above + change) and 11..13 (3 below).
        // The leading 0..6 (7 rows) and trailing 14..20 (7 rows)
        // become two fold markers.
        var rows: [CompareRow] = (0..<10).map(sameRow)
        rows.append(changedRow(10))
        rows.append(contentsOf: (11..<21).map(sameRow))

        let display = LineDiff.collapse(rows: rows, contextLines: 3)
        // Pattern: fold(0,7) + rows 7..13 (7 rows) + fold(14,7) = 9 entries.
        XCTAssertEqual(display.count, 9)
        guard case .fold(let s0, let c0) = display.first else {
            return XCTFail("expected leading fold, got \(display.first ?? .row(-1))")
        }
        XCTAssertEqual(s0, 0)
        XCTAssertEqual(c0, 7)
        guard case .fold(let s1, let c1) = display.last else {
            return XCTFail("expected trailing fold")
        }
        XCTAssertEqual(s1, 14)
        XCTAssertEqual(c1, 7)
    }

    func testCollapseKeepsAllRowsWhenNoChanges() {
        let rows = (0..<50).map(sameRow)
        let display = LineDiff.collapse(rows: rows, contextLines: 3)
        // Pure unchanged file: nothing to anchor a fold around, so we
        // show everything as-is.
        XCTAssertEqual(display.count, 50)
        XCTAssertTrue(display.allSatisfy { if case .row = $0 { return true } else { return false } })
    }

    func testRevealingEveryHiddenLineReplacesTheFold() {
        var rows: [CompareRow] = (0..<10).map(sameRow)
        rows.append(changedRow(10))
        rows.append(contentsOf: (11..<21).map(sameRow))

        let collapsed = LineDiff.collapse(rows: rows, contextLines: 3)
        guard case .fold(let start, let count) = collapsed.first else {
            return XCTFail("expected a leading fold")
        }

        let expanded = LineDiff.collapse(
            rows: rows,
            contextLines: 3,
            revealed: Set(start..<(start + count))
        )
        // The fold's 7 rows (indices 0..6) take its place: 7 + 7 + 1 fold.
        XCTAssertEqual(expanded.count, 15)
        guard case .row(let firstIdx) = expanded.first else {
            return XCTFail("expanded fold should start with row 0")
        }
        XCTAssertEqual(firstIdx, 0)
    }

    /// Expanding by degrees: what the two arrows on a fold marker do.
    ///
    /// A fold of four hundred lines opened in one press is a redraw of the
    /// whole file, which is a visible stall in a big one. Ten at a time
    /// leaves a smaller fold behind — so the shape to check is "some rows,
    /// then a fold that is shorter by exactly what was revealed".
    func testRevealingFromOneEndLeavesASmallerFold() {
        var rows: [CompareRow] = (0..<60).map(sameRow)
        rows.append(changedRow(60))

        let collapsed = LineDiff.collapse(rows: rows, contextLines: 3)
        guard case .fold(let start, let count) = collapsed.first else {
            return XCTFail("expected a leading fold")
        }
        XCTAssertEqual(start, 0)
        XCTAssertEqual(count, 57)

        // From the top — the block above carried further down.
        let fromTop = LineDiff.collapse(
            rows: rows, contextLines: 3, revealed: Set(0..<10)
        )
        guard case .row(let firstTop) = fromTop.first else {
            return XCTFail("the revealed lines come first")
        }
        XCTAssertEqual(firstTop, 0)
        guard case .fold(let topStart, let topCount) = fromTop[10] else {
            return XCTFail("and the rest is still folded")
        }
        XCTAssertEqual(topStart, 10)
        XCTAssertEqual(topCount, count - 10)

        // From the bottom — the block below carried further up.
        let fromBottom = LineDiff.collapse(
            rows: rows, contextLines: 3, revealed: Set(47..<57)
        )
        guard case .fold(let bottomStart, let bottomCount) = fromBottom.first else {
            return XCTFail("the fold now comes first")
        }
        XCTAssertEqual(bottomStart, 0)
        XCTAssertEqual(bottomCount, count - 10)
        guard case .row(let afterFold) = fromBottom[1] else {
            return XCTFail("followed by what was revealed")
        }
        XCTAssertEqual(afterFold, 47)
    }

    func testRevealingBothEndsLeavesAFoldInTheMiddle() {
        var rows: [CompareRow] = (0..<60).map(sameRow)
        rows.append(changedRow(60))

        let display = LineDiff.collapse(
            rows: rows,
            contextLines: 3,
            revealed: Set(0..<10).union(47..<57)
        )
        let folds = display.compactMap { entry -> (Int, Int)? in
            if case .fold(let start, let count) = entry { return (start, count) }
            return nil
        }
        XCTAssertEqual(folds.count, 1, "one gap left, between the two revealed ends")
        XCTAssertEqual(folds[0].0, 10)
        XCTAssertEqual(folds[0].1, 37)
    }

    func testRevealedIndicesOutsideTheFileAreIgnored() {
        var rows: [CompareRow] = (0..<10).map(sameRow)
        rows.append(changedRow(10))
        // A stale reveal from a previous, longer document must not crash
        // or bend the mask around a row that does not exist.
        let display = LineDiff.collapse(
            rows: rows, contextLines: 3, revealed: [999, -1]
        )
        XCTAssertFalse(display.isEmpty)
    }

    func testCollapseMergesOverlappingContextWindows() {
        // Two changes 4 lines apart with contextLines = 3 → the
        // contexts overlap so we shouldn't fold the gap.
        var rows: [CompareRow] = (0..<5).map(sameRow)
        rows.append(changedRow(5))
        rows.append(contentsOf: (6..<10).map(sameRow)) // 4 unchanged
        rows.append(changedRow(10))
        rows.append(contentsOf: (11..<16).map(sameRow))

        let display = LineDiff.collapse(rows: rows, contextLines: 3)
        // Between the two changes (indices 5 and 10), every row is
        // within 3 of one or the other — no fold should appear in
        // that middle stretch.
        let foldsInMiddle = display.dropFirst().dropLast().filter {
            if case .fold = $0 { return true } else { return false }
        }
        XCTAssertTrue(foldsInMiddle.isEmpty,
            "overlapping context windows should not produce a middle fold, got \(display)")
    }

    // MARK: - Whitespace-insensitive alignment

    /// The case this alignment exists for, taken from a real file.
    ///
    /// Three lines are inserted just above a blank line that also lost its
    /// trailing spaces. On byte equality the blank line has nothing to pair
    /// with, so it is deleted at the *top* of the insertion and ends up
    /// side by side with `#if DEBUG` — two lines with nothing to do with
    /// each other. Matching on the whitespace-free key pairs blank with
    /// blank, which puts the insertion above it as one clean block.
    func testABlankLineThatLostItsSpacesPairsWithTheBlankLineNotTheInsertion() {
        let left = [
            "self._addZinstantEmojiStatusDecor()",
            "        ",
            "self.size = CGSize()"
        ]
        let right = [
            "self._addZinstantEmojiStatusDecor()",
            "#if DEBUG",
            "self._addAnimatedDecorForTesting()",
            "#endif // DEBUG",
            "",
            "self.size = CGSize()"
        ]
        let rows = LineDiff.compute(left: left, right: right)

        XCTAssertEqual(rows.map(\.kind), [.same, .added, .added, .added, .modified, .same])
        // The pair sits at the bottom of the block, holding both blank lines.
        let pair = rows[4]
        XCTAssertEqual(pair.leftText, "        ")
        XCTAssertEqual(pair.rightText, "")
        XCTAssertEqual(pair.leftLine, 2)
        XCTAssertEqual(pair.rightLine, 5)
    }

    func testAReindentedLineIsMatchedRatherThanRewritten() {
        // Wrapping a block in an `if` re-indents every line inside it. Those
        // are the same lines of code, and pairing them keeps the diff to the
        // indentation instead of reprinting the block twice.
        let rows = LineDiff.compute(
            left: ["func f() {", "return 1", "}"],
            right: ["func f() {", "    return 1", "}"]
        )
        XCTAssertEqual(rows.map(\.kind), [.same, .modified, .same])
    }

    func testAReindentedLineThatAlsoChangedIsNotTreatedAsMinor() {
        // The key ignores whitespace, not edits: re-indenting *and* changing
        // the value leaves two different lines, and they align as a deletion
        // and an insertion the way any other rewrite does.
        let rows = LineDiff.compute(
            left: ["func f() {", "return 1", "}"],
            right: ["func f() {", "    return 2", "}"]
        )
        XCTAssertEqual(rows.map(\.kind), [.same, .removed, .added, .same])
    }

    func testIdenticalLinesAreStillPlainSame() {
        let rows = LineDiff.compute(left: ["a", "b"], right: ["a", "b"])
        XCTAssertEqual(rows.map(\.kind), [.same, .same])
        XCTAssertFalse(rows.contains { $0.isChange })
    }

    func testAModifiedRowCountsAsAChange() {
        // It has to, or ⌘J / ⌘K would skip past it and Collapse would fold
        // it away — a whitespace difference you cannot navigate to is a
        // whitespace difference you will never find.
        let rows = LineDiff.compute(left: ["  x"], right: ["\tx"])
        XCTAssertEqual(rows.map(\.kind), [.modified])
        XCTAssertTrue(rows[0].isChange)
        XCTAssertEqual(LineDiff.changeAnchors(in: rows), [0])
    }

    func testAlignmentKeyIgnoresOnlyWhitespace() {
        XCTAssertEqual(LineDiff.alignmentKey("    "), "")
        XCTAssertEqual(LineDiff.alignmentKey(""), "")
        XCTAssertEqual(LineDiff.alignmentKey("  let  x =  1  "), "let x = 1")
        XCTAssertEqual(LineDiff.alignmentKey("\tlet x = 1"), "let x = 1")
        // Not so loose that it equates different code: removing the spaces
        // around an operator is a real edit to the token stream.
        XCTAssertNotEqual(LineDiff.alignmentKey("let x = 1"), LineDiff.alignmentKey("let x=1"))
    }

    func testUnrelatedLinesAreStillAddedAndRemoved() {
        let rows = LineDiff.compute(left: ["alpha"], right: ["beta"])
        XCTAssertEqual(rows.map(\.kind), [.removed, .added])
    }

    // MARK: - Pairing a changed run

    /// Each replaced line sits immediately before its replacement — the pair
    /// the view draws as one row. Two declarations that each gained a
    /// parameter used to come out with the second old one beside the first
    /// new one.
    func testEachReplacedLineIsPairedWithItsOwnReplacement() {
        let rows = LineDiff.compute(
            left: ["// feed", "-(void)load:(id)u;", "-(void)refresh:(id)u;", "@end"],
            right: ["// feed", "-(void)load:(id)u source:(int)s;", "-(void)refresh:(id)u source:(int)s;", "@end"]
        )
        XCTAssertEqual(rows.map(\.kind), [.same, .removed, .added, .removed, .added, .same])
        XCTAssertEqual(rows[1].leftLine, 2)
        XCTAssertEqual(rows[2].rightLine, 2)
        XCTAssertEqual(rows[3].leftLine, 3)
        XCTAssertEqual(rows[4].rightLine, 3)
    }

    /// With more new lines than old, the old one goes beside the new line most
    /// like it — not whichever happens to be first.
    func testAReplacedLinePairsWithTheMostSimilarNewLine() {
        let rows = LineDiff.compute(
            left: ["a", "let total = price * count", "z"],
            right: ["a", "// added", "let total = price * count * tax", "z"]
        )
        XCTAssertEqual(rows.map(\.kind), [.same, .added, .removed, .added, .same])
        XCTAssertEqual(rows[1].rightText, "// added")
        XCTAssertEqual(rows[3].rightText, "let total = price * count * tax")
    }

    /// Align With: a pin puts its two lines on one row, whatever the aligner
    /// would have done with them.
    func testAPinPutsItsTwoLinesSideBySide() {
        let left = ["one", "two"]
        let right = ["uno", "dos"]
        let rows = LineDiff.compute(left: left, right: right, pins: [LineAlignment(left: 0, right: 1)])
        XCTAssertEqual(rows.map(\.kind), [.added, .removed, .added, .removed])
        XCTAssertEqual(rows[1].leftText, "one")
        XCTAssertEqual(rows[2].rightText, "dos")
    }


    // MARK: - Context

    /// A 20-line file with line 10 rewritten. The rewrite is two rows — the
    /// old line removed and the new one added — which is what the context
    /// window is measured around.
    private var oneChangeInTheMiddle: [CompareRow] {
        let left = (1...20).map { "line \($0)" }
        var right = left
        right[9] = "CHANGED"
        return LineDiff.compute(left: left, right: right)
    }

    private func shownRows(_ display: [DiffDisplayRow]) -> [Int] {
        display.compactMap { entry in
            if case .row(let i) = entry { return i }
            return nil
        }
    }

    private func foldCount(_ display: [DiffDisplayRow]) -> Int {
        display.filter { if case .fold = $0 { return true } else { return false } }.count
    }

    func testContextKeepsThreeLinesEitherSideOfAChange() {
        let rows = oneChangeInTheMiddle
        let changed = rows.indices.filter { rows[$0].isChange }
        XCTAssertEqual(changed, [9, 10])

        let display = LineDiff.collapse(rows: rows, contextLines: 3)
        XCTAssertEqual(shownRows(display), Array(6...13))
        // One fold above, one below.
        XCTAssertEqual(foldCount(display), 2)
    }

    func testNoContextShowsTheChangedLinesAlone() {
        let display = LineDiff.collapse(rows: oneChangeInTheMiddle, contextLines: 0)
        XCTAssertEqual(shownRows(display), [9, 10])
        XCTAssertEqual(foldCount(display), 2)
    }

    func testAFoldIsNeverUsedToHideASingleLine() {
        // Two changes with one unchanged line between them, and no context.
        // A marker there would take up the row it saves and ask for a click
        // to undo itself, so the line is simply shown.
        let display = LineDiff.collapse(
            rows: LineDiff.compute(left: ["a", "b", "c"], right: ["A", "b", "C"]),
            contextLines: 0
        )
        XCTAssertEqual(foldCount(display), 0)
        XCTAssertEqual(shownRows(display).count, 5)
    }


    /// A change far past the LCS table's cell limit — the size that used to
    /// freeze the compare window — still lines up the lines both sides keep.
    func testHugeChangeAlignsWithoutTheFullTable() {
        let kept = (0..<20_000).map { "line \($0)" }
        let left = kept + (0..<5_000).map { "old \($0)" } + kept.map { $0 + " tail" }
        let right = kept + (0..<30_000).map { "new \($0)" } + kept.map { $0 + " tail" }
        XCTAssertGreaterThan(5_000 * 30_000, LineDiff.cellLimit)

        let start = Date()
        let rows = LineDiff.compute(left: left, right: right)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)

        XCTAssertEqual(rows.filter { $0.kind == .same }.count, 40_000)
        XCTAssertEqual(rows.filter { $0.kind == .removed }.count, 5_000)
        XCTAssertEqual(rows.filter { $0.kind == .added }.count, 30_000)
    }

    /// A cancelled compare gives up rather than finishing.
    func testCancelledComputeReturnsNothing() async {
        let left = (0..<3_000).map { "a\($0)" }
        let right = (0..<3_000).map { "b\($0)" }
        let task = Task { () -> [CompareRow] in
            withUnsafeCurrentTask { $0?.cancel() }
            return LineDiff.compute(left: left, right: right)
        }
        let rows = await task.value
        XCTAssertTrue(rows.isEmpty)
    }
}
