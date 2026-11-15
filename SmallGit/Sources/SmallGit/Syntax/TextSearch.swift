import Foundation
import Observation

/// One occurrence of a search query.
///
/// Offsets are counted in `Character`s, matching `SyntaxToken` and
/// `CompareTextLayout`, so a match can be composed with syntax colouring and
/// the word diff without translating between units. Any other choice drifts
/// on the first emoji in a string literal.
struct TextSearchMatch: Hashable, Sendable {
    /// Index into the array of lines that was searched.
    let line: Int
    /// Which parallel document the hit is in — 0 for a single-column view, and
    /// left / right for a side-by-side compare, whose two panes are two
    /// documents sharing a row index. Defaulted so single-column callers can
    /// ignore it entirely.
    let column: Int
    let start: Int
    let length: Int

    init(line: Int, column: Int = 0, start: Int, length: Int) {
        self.line = line
        self.column = column
        self.start = start
        self.length = length
    }

    var end: Int { start + length }
    var range: Range<Int> { start..<end }
}

/// Finds a literal query in a document, line by line.
///
/// Literal, not regular expressions: this backs ⌘F in a diff viewer, where the
/// thing being hunted for is a symbol name or a bit of code. Source is full of
/// characters a regex engine would treat as syntax — `[`, `(`, `.`, `$` — so a
/// regex-by-default search turns "find `array[0]`" into a puzzle.
enum TextSearch {

    /// Every non-overlapping occurrence, in document order.
    ///
    /// Case-insensitive by default, and additionally diacritic-insensitive,
    /// which is what a plain search field is expected to do.
    static func matches(
        in lines: [String],
        query: String,
        caseSensitive: Bool = false
    ) -> [TextSearchMatch] {
        matches(in: [lines], query: query, caseSensitive: caseSensitive)
    }

    /// Searches several parallel documents that share a line numbering — the
    /// two panes of a side-by-side compare.
    ///
    /// Ordered by line, then column, then position, so stepping through hits
    /// walks *down the file* taking the left pane before the right on any row
    /// they share. Concatenating one whole pane after the other would instead
    /// walk all of HEAD and then all of WORKING, which is not how anyone reads
    /// a diff.
    static func matches(
        in columns: [[String]],
        query: String,
        caseSensitive: Bool = false
    ) -> [TextSearchMatch] {
        guard !query.isEmpty else { return [] }
        var out: [TextSearchMatch] = []
        for (columnIndex, lines) in columns.enumerated() {
            for (lineIndex, line) in lines.enumerated() {
                out.append(contentsOf: matches(
                    in: line, line: lineIndex, column: columnIndex,
                    query: query, caseSensitive: caseSensitive
                ))
            }
        }
        return out.sorted {
            if $0.line != $1.line { return $0.line < $1.line }
            if $0.column != $1.column { return $0.column < $1.column }
            return $0.start < $1.start
        }
    }

    static func matches(
        in line: String,
        line index: Int,
        column: Int = 0,
        query: String,
        caseSensitive: Bool = false
    ) -> [TextSearchMatch] {
        guard !query.isEmpty, !line.isEmpty else { return [] }

        let options: String.CompareOptions = caseSensitive
            ? [.literal]
            : [.caseInsensitive, .diacriticInsensitive]

        var out: [TextSearchMatch] = []
        var searchStart = line.startIndex

        while searchStart < line.endIndex,
              let found = line.range(of: query, options: options, range: searchStart..<line.endIndex) {
            let start = line.distance(from: line.startIndex, to: found.lowerBound)
            let length = line.distance(from: found.lowerBound, to: found.upperBound)
            // A zero-width match cannot happen with a non-empty literal query,
            // but guarding it keeps the loop from spinning if that ever
            // changes — the advance below relies on forward progress.
            guard length > 0 else { break }
            out.append(TextSearchMatch(line: index, column: column, start: start, length: length))
            // Resume *after* the match: overlapping hits ("aa" in "aaa"
            // reported twice from offsets 0 and 1) would make Next appear to
            // barely move, which is not what a find bar is expected to do.
            searchStart = found.upperBound
        }
        return out
    }

    /// The index of the first match at or after `line`, for resuming a search
    /// from wherever the reader currently is rather than from the top.
    static func indexOfFirstMatch(from line: Int, in matches: [TextSearchMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        return matches.firstIndex { $0.line >= line } ?? 0
    }
}

/// Search state for one window: the query, the hits, and which one is current.
///
/// Wrapping is deliberate in both directions — a find bar that stops dead at
/// the last match makes you scroll back to the top by hand, and every editor
/// wraps instead.
@MainActor
@Observable
final class TextFindState {
    var isPresented = false
    var query = "" { didSet { if query != oldValue { recompute() } } }
    var caseSensitive = false { didSet { if caseSensitive != oldValue { recompute() } } }

    private(set) var matches: [TextSearchMatch] = []
    /// Index into `matches`, or `nil` when there are none.
    private(set) var currentIndex: Int?

    /// Supplies the text to search. Held as a closure so the state can refresh
    /// itself when the query changes without the view having to re-push the
    /// document on every keystroke.
    private var columnsProvider: () -> [[String]] = { [] }

    func configure(lines: @escaping () -> [String]) {
        columnsProvider = { [lines()] }
    }

    /// For a side-by-side view, whose panes share a row numbering.
    func configure(columns: @escaping () -> [[String]]) {
        columnsProvider = columns
    }

    var current: TextSearchMatch? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    /// "3 of 17", or nil when there is nothing to report.
    var summary: String? {
        guard !query.isEmpty else { return nil }
        guard !matches.isEmpty else { return "No results" }
        let position = (currentIndex ?? 0) + 1
        return "\(position) of \(matches.count)"
    }

    /// Recomputes against the current document — call when the text changes
    /// under a live search, so stale offsets can't point into a line that has
    /// since been edited.
    func recompute() {
        let previousLine = current?.line
        matches = TextSearch.matches(
            in: columnsProvider(),
            query: query,
            caseSensitive: caseSensitive
        )
        guard !matches.isEmpty else {
            currentIndex = nil
            return
        }
        // Stay as close as possible to where the reader was, rather than
        // snapping back to the top on every keystroke.
        currentIndex = previousLine.flatMap { TextSearch.indexOfFirstMatch(from: $0, in: matches) } ?? 0
    }

    func next() {
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? -1) + 1) % matches.count
    }

    func previous() {
        guard !matches.isEmpty else { return }
        let index = currentIndex ?? 0
        currentIndex = (index - 1 + matches.count) % matches.count
    }

    /// Matches on one line of one column, for a renderer that draws a row at
    /// a time.
    func matches(onLine line: Int, column: Int = 0) -> [TextSearchMatch] {
        guard !matches.isEmpty else { return [] }
        return matches.filter { $0.line == line && $0.column == column }
    }

    func dismiss() {
        isPresented = false
        query = ""
    }
}
