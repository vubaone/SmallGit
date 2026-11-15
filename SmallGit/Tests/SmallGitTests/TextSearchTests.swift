import XCTest
@testable import SmallGit

/// Covers ⌘F in the compare and conflict windows.
@MainActor
final class TextSearchTests: XCTestCase {

    private let lines = [
        "func addItem(_ item: Item) {",
        "    items.append(item)",
        "    // item added",
        "}"
    ]

    // MARK: - Finding

    func testFindsEveryOccurrenceInDocumentOrder() {
        let matches = TextSearch.matches(in: lines, query: "item")
        XCTAssertEqual(matches.map(\.line), [0, 0, 0, 1, 1, 2])
        XCTAssertTrue(zip(matches, matches.dropFirst()).allSatisfy {
            $0.line < $1.line || $0.start < $1.start
        }, "matches must come back in reading order")
    }

    /// Case-insensitive by default — `addItem` and `item` both match "item".
    func testCaseInsensitiveByDefaultAndExactWhenAsked() {
        XCTAssertEqual(TextSearch.matches(in: ["Item item ITEM"], query: "item").count, 3)
        XCTAssertEqual(
            TextSearch.matches(in: ["Item item ITEM"], query: "item", caseSensitive: true).count, 1
        )
    }

    /// Offsets are in `Character`s, like the syntax tokens they compose with,
    /// so a wide character earlier in the line must not shift them.
    func testOffsetsAreCharacterBased() throws {
        let line = #"let flag = "🇻🇳" // target"#
        let match = try XCTUnwrap(TextSearch.matches(in: [line], query: "target").first)
        let characters = Array(line)
        XCTAssertEqual(String(characters[match.start..<match.end]), "target")
    }

    /// Overlapping hits would make Next barely advance; find bars report the
    /// non-overlapping ones.
    func testMatchesDoNotOverlap() {
        let matches = TextSearch.matches(in: ["aaaa"], query: "aa")
        XCTAssertEqual(matches.map(\.start), [0, 2])
    }

    func testAnEmptyQueryFindsNothing() {
        XCTAssertTrue(TextSearch.matches(in: lines, query: "").isEmpty)
    }

    func testAQueryThatIsNotThereFindsNothing() {
        XCTAssertTrue(TextSearch.matches(in: lines, query: "zzz").isEmpty)
    }

    /// The literal-not-regex decision: source is full of regex metacharacters,
    /// and a search for `item)` should find `item)`.
    func testQueriesAreLiteralNotRegularExpressions() {
        XCTAssertEqual(TextSearch.matches(in: ["a.b", "axb"], query: "a.b").map(\.line), [0])
        XCTAssertEqual(TextSearch.matches(in: ["items[0]"], query: "[0]").count, 1)
    }

    // MARK: - Columns

    /// The compare view's two panes share a row numbering, and stepping
    /// through hits must walk *down the file* rather than through one whole
    /// pane and then the other.
    func testColumnsAreInterleavedByLineNotConcatenated() {
        let left = ["alpha", "plain", "alpha"]
        let right = ["alpha", "alpha", "plain"]
        let matches = TextSearch.matches(in: [left, right], query: "alpha")

        XCTAssertEqual(matches.map { [$0.line, $0.column] },
                       [[0, 0], [0, 1], [1, 1], [2, 0]])
    }

    // MARK: - Find state

    private func makeState(_ documents: [[String]]) -> TextFindState {
        let state = TextFindState()
        state.configure(columns: { documents })
        return state
    }

    func testSteppingWrapsInBothDirections() {
        let state = makeState([["a", "a", "a"]])
        state.query = "a"
        XCTAssertEqual(state.currentIndex, 0)

        state.next(); state.next()
        XCTAssertEqual(state.currentIndex, 2)
        state.next()
        XCTAssertEqual(state.currentIndex, 0, "next wraps to the top")
        state.previous()
        XCTAssertEqual(state.currentIndex, 2, "previous wraps to the bottom")
    }

    func testSummaryReportsPositionAndTotal() {
        let state = makeState([["a", "a"]])
        state.query = "a"
        XCTAssertEqual(state.summary, "1 of 2")
        state.next()
        XCTAssertEqual(state.summary, "2 of 2")
    }

    func testSummaryReportsWhenThereAreNoResults() {
        let state = makeState([["a"]])
        state.query = "zzz"
        XCTAssertEqual(state.summary, "No results")
        XCTAssertNil(state.current)
    }

    func testNoSummaryBeforeAnythingIsTyped() {
        XCTAssertNil(makeState([["a"]]).summary)
    }

    /// Typing another character must not throw the reader back to the top of
    /// the file when they were already partway down.
    func testRefiningAQueryStaysNearTheCurrentPosition() {
        let state = makeState([["alpha", "beta", "alphabet"]])
        state.query = "alpha"
        state.next()
        XCTAssertEqual(state.current?.line, 2)

        state.query = "alphabet"

        XCTAssertEqual(state.current?.line, 2, "still on the line the reader was reading")
    }

    /// The document can change under a live search — the compare view rebuilds
    /// its rows on every keystroke in the inspector.
    func testRecomputeAfterTheDocumentChanges() {
        var documents = [["alpha"]]
        let state = TextFindState()
        state.configure(columns: { documents })
        state.query = "alpha"
        XCTAssertEqual(state.matches.count, 1)

        documents = [["alpha", "alpha"]]
        state.recompute()

        XCTAssertEqual(state.matches.count, 2)
    }

    func testDismissClearsTheQuery() {
        let state = makeState([["a"]])
        state.isPresented = true
        state.query = "a"
        state.dismiss()
        XCTAssertFalse(state.isPresented)
        XCTAssertTrue(state.query.isEmpty)
        XCTAssertTrue(state.matches.isEmpty)
    }

    func testPerLineLookupIsScopedToItsColumn() {
        let state = makeState([["hit"], ["hit"]])
        state.query = "hit"
        XCTAssertEqual(state.matches(onLine: 0, column: 0).count, 1)
        XCTAssertEqual(state.matches(onLine: 0, column: 1).count, 1)
        XCTAssertTrue(state.matches(onLine: 1, column: 0).isEmpty)
    }
}

/// Covers search as a third layer over syntax colouring and the word diff.
final class CompareTextLayoutSearchTests: XCTestCase {

    private func runs(
        _ text: String,
        syntax: [SyntaxToken] = [],
        matches: [TextSearchMatch] = [],
        current: TextSearchMatch? = nil,
        changed: Bool = false
    ) -> [CompareTextRun] {
        CompareTextLayout.runs(
            spans: [DiffSpan(text: text, kind: changed ? .changed : .same)],
            syntax: syntax,
            searchMatches: matches,
            currentMatch: current
        )
    }

    func testRunsStillReassembleIntoTheLine() {
        let text = "let value = compute()"
        let output = runs(text,
                          syntax: SyntaxHighlighter.highlight(line: text, language: .swift),
                          matches: TextSearch.matches(in: [text], query: "value"))
        XCTAssertEqual(output.map(\.text).joined(), text)
    }

    func testTheMatchIsMarkedAndNothingElseIs() throws {
        let text = "alpha beta"
        let output = runs(text, matches: TextSearch.matches(in: [text], query: "beta"))

        let marked = output.filter { $0.search != nil }
        XCTAssertEqual(marked.map(\.text).joined(), "beta")
        XCTAssertEqual(output.filter { $0.search == nil }.map(\.text).joined(), "alpha ")
    }

    /// The current hit is drawn differently from the rest, or Next is
    /// unfollowable on a screen with a dozen hits.
    func testTheCurrentMatchIsDistinguished() {
        let text = "aa aa"
        let matches = TextSearch.matches(in: [text], query: "aa")
        let output = runs(text, matches: matches, current: matches.last)

        XCTAssertEqual(output.filter { $0.search == .current }.map(\.text).joined(), "aa")
        XCTAssertEqual(output.filter { $0.search == .match }.map(\.text).joined(), "aa")
    }

    /// A query routinely starts inside one syntax token and ends inside
    /// another, so the run boundaries have to come from both layers.
    func testAMatchStraddlingTwoSyntaxTokensIsCutAtBoth() {
        let text = #"let s = "x""#
        let output = runs(text,
                          syntax: SyntaxHighlighter.highlight(line: text, language: .swift),
                          matches: TextSearch.matches(in: [text], query: "s = \""))

        XCTAssertEqual(output.map(\.text).joined(), text)
        let marked = output.filter { $0.search != nil }
        XCTAssertEqual(marked.map(\.text).joined(), "s = \"")
        XCTAssertGreaterThan(marked.count, 1, "the hit spans more than one syntax kind")
    }

    /// While searching, a hit has to be visible on a changed line too — so the
    /// search background takes precedence over the word diff's.
    func testASearchHitOverridesTheWordDiffBackground() {
        let text = "renamed"
        let output = runs(text, matches: TextSearch.matches(in: [text], query: "renamed"),
                          changed: true)
        XCTAssertTrue(output.allSatisfy { $0.search == .match })
        XCTAssertTrue(output.allSatisfy(\.isChanged), "still reported as changed for the renderer")
    }

    func testNoMatchesLeavesTheLineExactlyAsBefore() {
        let text = "let value = 1"
        let syntax = SyntaxHighlighter.highlight(line: text, language: .swift)
        XCTAssertEqual(
            runs(text, syntax: syntax),
            CompareTextLayout.runs(spans: [DiffSpan(text: text, kind: .same)], syntax: syntax)
        )
    }

    /// Offsets can outlive the text they were found in, since the query and
    /// the document change independently.
    func testStaleOffsetsClampInsteadOfCrashing() {
        let output = runs("ab", matches: [TextSearchMatch(line: 0, start: 1, length: 99)])
        XCTAssertEqual(output.map(\.text).joined(), "ab")
    }
}
