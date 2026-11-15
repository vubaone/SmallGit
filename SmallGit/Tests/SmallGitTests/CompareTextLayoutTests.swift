import XCTest
@testable import SmallGit

/// Covers the point where syntax colouring meets the word-level diff.
///
/// These are two layers over the same characters with unrelated boundaries,
/// and the failure mode when they are merged wrongly is not a crash — it is a
/// line where every colour is shifted a few characters along, which looks
/// plausible enough to be believed.
final class CompareTextLayoutTests: XCTestCase {

    private func runs(_ spans: [DiffSpan], _ syntax: [SyntaxToken]) -> [CompareTextRun] {
        CompareTextLayout.runs(spans: spans, syntax: syntax)
    }

    private func same(_ text: String) -> DiffSpan { DiffSpan(text: text, kind: .same) }
    private func changed(_ text: String) -> DiffSpan { DiffSpan(text: text, kind: .changed) }

    /// The invariant everything else rests on: whatever the cutting, the
    /// characters come back in order and unchanged.
    func testRunsReassembleIntoTheOriginalLine() {
        let spans = [same("let x = "), changed("42"), same(" // note")]
        let line = spans.map(\.text).joined()
        let output = runs(spans, SyntaxHighlighter.highlight(line: line, language: .swift))
        XCTAssertEqual(output.map(\.text).joined(), line)
    }

    /// With no language, the diff layer is all there is — and that is exactly
    /// how the compare views rendered before highlighting existed.
    func testWithoutSyntaxTheSpansSurviveUntouched() {
        let output = runs([same("abc"), changed("def")], [])
        XCTAssertEqual(output.map(\.text), ["abc", "def"])
        XCTAssertEqual(output.map(\.kind), [.plain, .plain])
        XCTAssertEqual(output.map(\.isChanged), [false, true])
    }

    /// A syntax run that straddles a span boundary has to be split, or the
    /// changed background would bleed over the unchanged half of the token.
    func testASyntaxRunIsCutAtTheDiffBoundary() {
        // "kSize" is one identifier; the diff says only "Size" changed.
        let spans = [same("k"), changed("Size")]
        let syntax = [SyntaxToken(start: 0, length: 5, kind: .type)]
        let output = runs(spans, syntax)

        XCTAssertEqual(output.map(\.text), ["k", "Size"])
        XCTAssertEqual(output.map(\.kind), [.type, .type], "both halves keep the syntax colour")
        XCTAssertEqual(output.map(\.isChanged), [false, true], "only the changed half is marked")
    }

    /// And the mirror image: a diff span covering several syntax runs is cut
    /// once per run, so each keeps its own colour.
    func testADiffSpanIsCutAtEverySyntaxBoundary() {
        let spans = [changed(#"let n = "s""#)]
        let output = runs(spans, SyntaxHighlighter.highlight(line: #"let n = "s""#, language: .swift))

        XCTAssertTrue(output.allSatisfy(\.isChanged), "the whole span is still changed")
        XCTAssertEqual(output.first?.kind, .keyword)
        XCTAssertEqual(output.last?.kind, .string)
        XCTAssertGreaterThan(output.count, 1, "the span must not stay one undivided run")
    }

    /// Adjacent characters of the same kind and the same diff state belong to
    /// one run: the renderer makes an `AttributedString` piece per run, and
    /// one per character would be needless work on every visible line.
    func testEqualNeighboursAreNotSplit() {
        let output = runs([same("keyword")], [SyntaxToken(start: 0, length: 7, kind: .keyword)])
        XCTAssertEqual(output.count, 1)
    }

    /// The renderer pairs a line with tokens by line number. If that ever
    /// slips, the result must be wrong colours, not a crash in a window the
    /// user cannot get out of.
    func testTokensLongerThanTheLineDoNotOverrun() {
        let output = runs([same("ab")], [SyntaxToken(start: 0, length: 500, kind: .string)])
        XCTAssertEqual(output.map(\.text).joined(), "ab")
        XCTAssertEqual(output.map(\.kind), [.string])
    }

    func testEmptyInputProducesNoRuns() {
        XCTAssertTrue(runs([], []).isEmpty)
        XCTAssertTrue(runs([same("")], []).isEmpty)
    }

    /// Offsets are character-based end to end. A multi-scalar grapheme in the
    /// line must not shift the colours that follow it.
    func testMultiScalarCharactersDoNotShiftLaterRuns() {
        let line = #"// 🇻🇳 done"#
        let output = runs([same(line)], SyntaxHighlighter.highlight(line: line, language: .swift))
        XCTAssertEqual(output.map(\.text).joined(), line)
        XCTAssertEqual(Set(output.map(\.kind)), [.comment], "the whole line is one comment")
    }

    /// The shape the compare view actually produces for a replaced line, end
    /// to end: word diff plus a real scan, checked at the character level.
    func testReplacedObjectiveCLineLayersBothSignals() {
        let before = "make.width.mas_equalTo(kSongThumbSize);"
        let after = "make.width.mas_equalTo(ceilf(kSongThumbSize * self->_uiScale));"
        let (_, rightSpans) = WordDiff.diff(left: before, right: after)
        let output = runs(rightSpans, SyntaxHighlighter.highlight(line: after, language: .objectiveC))

        XCTAssertEqual(output.map(\.text).joined(), after)
        XCTAssertTrue(
            output.contains { $0.text == "ceilf" && $0.kind == .function },
            "the inserted call is coloured as a function"
        )
        XCTAssertTrue(
            output.contains { $0.text == "ceilf" && $0.isChanged },
            "and is still marked as the part that changed"
        )
        XCTAssertTrue(
            output.contains { $0.text.contains("make") && !$0.isChanged },
            "the untouched head of the line stays unmarked"
        )
    }

    // MARK: - Revealed whitespace

    private func revealed(_ text: String, syntax: [SyntaxToken] = []) -> [CompareTextRun] {
        CompareTextLayout.runs(
            spans: [same(text)], syntax: syntax, revealWhitespace: true
        )
    }

    func testWhitespaceIsOffByDefault() {
        let output = runs([same("a b\tc")], [])
        XCTAssertEqual(output.map(\.text).joined(), "a b\tc")
        XCTAssertFalse(output.contains { $0.isWhitespace })
    }

    /// The bug this contract exists to prevent: the glyphs used to be
    /// substituted into the text, so selecting a line and copying it
    /// produced `wait·for·check·avatar·can·like·or·not`.
    func testRevealedTextKeepsTheRealCharacters() {
        let output = revealed("a b")
        XCTAssertEqual(output.map(\.text).joined(), "a b",
            "what's on screen is what lands in the clipboard")
        XCTAssertEqual(output.map(\.isWhitespace), [false, true, false])
    }

    func testMarkersDescribeWhereTheGlyphsArePainted() {
        let line = CompareTextLayout.revealed("a b")
        XCTAssertEqual(line.text, "a b")
        XCTAssertEqual(line.marks, [
            WhitespaceMark(utf16Offset: 1, kind: .space),
            WhitespaceMark(utf16Offset: 3, kind: .lineEnd)
        ])
    }

    func testAnEmptyLineStillMarksItsLineEnd() {
        // The whole point of the pilcrow: an empty line is invisible without
        // it, and "is there a blank line here" is exactly the question this
        // mode is turned on to answer. It's painted at offset 0 now rather
        // than spelled into the text.
        XCTAssertTrue(revealed("").isEmpty, "no characters, nothing to render")
        XCTAssertEqual(CompareTextLayout.revealed(""),
                       RevealedLine(text: "", marks: [
                           WhitespaceMark(utf16Offset: 0, kind: .lineEnd)
                       ]))
    }

    func testATabRunsOutToTheNextStopSoNothingIsReIndented() {
        // Column 0, so the tab spans the full four columns of blanks.
        XCTAssertEqual(revealed("\tx").map(\.text).joined(), "    x")
        // Two characters in, the same tab only has two columns left to fill.
        XCTAssertEqual(revealed("ab\tx").map(\.text).joined(), "ab  x")
        // And a stop lands exactly on the boundary rather than collapsing.
        XCTAssertEqual(revealed("abcd\tx").map(\.text).joined(), "abcd    x")
    }

    func testTheTabMarkerSitsOnTheFirstOfItsColumns() {
        let line = CompareTextLayout.revealed("ab\tx")
        XCTAssertEqual(line.text, "ab  x")
        XCTAssertEqual(line.marks.first, WhitespaceMark(utf16Offset: 2, kind: .tab),
            "one arrow at the tab's start, not a dot per blank it filled")
        XCTAssertEqual(line.marks.count, 2, "the tab and the line end")
    }

    /// The overlay measures its offsets against the text the runs spell
    /// out. If the two disagreed by a single character every marker after
    /// it would be drawn in the wrong place.
    func testTheOverlayAndTheRunsAgreeOnTheText() {
        for line in ["a b", "\tx", "ab\tx", "abcd\tlet x = 1", "   ", "", "→ literal"] {
            XCTAssertEqual(
                revealed(line).map(\.text).joined(),
                CompareTextLayout.revealed(line).text,
                "disagreement on \(line.debugDescription) would offset every marker"
            )
        }
    }

    func testTabStopsAreMeasuredFromTheStartOfTheLineNotTheRun() {
        // Syntax cuts this line into several runs; the tab still has to know
        // it sits at column 2, not at column 0 of whatever run holds it.
        let line = "ab\tlet"
        let output = CompareTextLayout.runs(
            spans: [same("ab"), changed("\tlet")],
            syntax: SyntaxHighlighter.highlight(line: line, language: .swift),
            revealWhitespace: true
        )
        XCTAssertEqual(output.map(\.text).joined(), "ab  let")
    }

    func testWhitespaceRunsInheritTheirRunsDiffStateButSplitOutOfIt() {
        // Indentation that the word diff called changed keeps the changed
        // background — losing it would hide a pure-whitespace edit, which is
        // the one this mode exists to make visible.
        let output = CompareTextLayout.runs(
            spans: [changed("  "), same("x")], syntax: [], revealWhitespace: true
        )
        XCTAssertEqual(output.map(\.text), ["  ", "x"])
        XCTAssertEqual(output.map(\.isChanged), [true, false])
        XCTAssertEqual(output.map(\.isWhitespace), [true, false])
    }

    func testSyntaxColoursSurviveTheSubstitution() {
        // The offsets every layer works in refer to the original characters,
        // so the substitution has to happen after the cutting. If it did not,
        // one tab would shift every colour after it along the line.
        let line = "let x = 1"
        let output = revealed(line, syntax: SyntaxHighlighter.highlight(line: line, language: .swift))
        let code = output.filter { !$0.isWhitespace }
        XCTAssertEqual(code.first?.text, "let")
        XCTAssertEqual(code.first?.kind, .keyword)
        XCTAssertEqual(code.last?.kind, .number)
        XCTAssertEqual(code.last?.text, "1")
    }

}
