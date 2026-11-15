import Foundation

/// Why a run is highlighted by the find bar.
enum SearchHighlight: Hashable, Sendable {
    /// One of the query's hits.
    case match
    /// The hit the find bar is currently sitting on — drawn stronger, so
    /// Next/Previous is followable in a screen with a dozen hits on it.
    case current
}

/// One run of characters that shares a syntax kind, a diff state and a search
/// state — the smallest piece of a compare line that can be drawn with a
/// single set of attributes.
struct CompareTextRun: Hashable, Sendable {
    let text: String
    let kind: SyntaxTokenKind
    /// True where the word-level diff marked these characters as changed.
    /// Drives the background; `kind` drives the foreground.
    let isChanged: Bool
    /// Set where the find bar has a hit. Takes the background over the word
    /// diff: while searching, "where is my query" is the question being asked,
    /// and a hit that renders identically to its surroundings is useless.
    let search: SearchHighlight?
    /// True for a run of revealed whitespace glyphs. Views draw these in a
    /// muted colour: the dots and arrows are there to be found when looked
    /// for, not to compete with the code they sit between.
    let isWhitespace: Bool

    init(
        text: String,
        kind: SyntaxTokenKind,
        isChanged: Bool,
        search: SearchHighlight? = nil,
        isWhitespace: Bool = false
    ) {
        self.text = text
        self.kind = kind
        self.isChanged = isChanged
        self.search = search
        self.isWhitespace = isWhitespace
    }
}

/// The glyphs "show whitespace" substitutes in, and the tab width it lays
/// them out on. Beyond Compare's set, which is also every editor's: a middle
/// dot per space, an arrow per tab, a pilcrow at the end of the line.
enum WhitespaceGlyph {
    static let space: Character = "\u{00B7}"    // ·
    static let tab: Character = "\u{2192}"      // →
    static let lineEnd: Character = "\u{00B6}"  // ¶
    static let tabWidth = 4
}

/// Where one whitespace marker is drawn, in UTF-16 offsets into the text
/// as it is rendered.
///
/// The markers are painted over the line rather than substituted into it
/// (see `CompareTextLayout.revealed`), because a `Text`'s selection copies
/// exactly the characters it holds — with the glyphs inline, copying a
/// line of prose out of a diff produced `wait·for·check·avatar`, which is
/// no longer the text the user was looking at.
struct WhitespaceMark: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case space
        /// The first cell of a tab; the rest of its run to the next stop
        /// is left blank, as an editor draws it.
        case tab
        /// End of line, drawn after the last character.
        case lineEnd
    }

    let utf16Offset: Int
    let kind: Kind
}

/// A line as it is drawn with whitespace revealed: the text (tabs
/// expanded so the 4-column stops hold) plus the markers to paint on top.
struct RevealedLine: Equatable, Sendable {
    let text: String
    let marks: [WhitespaceMark]

    static let empty = RevealedLine(text: "", marks: [])
}

/// Merges the two things a compare line knows about itself: what the word
/// diff changed, and what the syntax scanner made of it.
///
/// They are genuinely independent layers over the same characters, and their
/// boundaries have no reason to line up — a rename changes the middle of an
/// identifier, and a changed region routinely starts inside a string and ends
/// inside a keyword. So this re-cuts the line wherever *either* layer changes.
///
/// Lives outside the view because it is the one piece of the rendering with
/// arithmetic in it. Everything else in `SpanText` is layout.
enum CompareTextLayout {

    /// `spans` partition the line; `syntax` covers it in the same character
    /// coordinates. A line with no syntax information comes back as the spans
    /// themselves, every run `.plain` — which is exactly how the compare views
    /// rendered before highlighting existed.
    ///
    /// With `revealWhitespace` on, the returned runs carry glyphs in place of
    /// spaces and tabs and end with a pilcrow — so an empty line still comes
    /// back with something to draw.
    static func runs(
        spans: [DiffSpan],
        syntax: [SyntaxToken],
        searchMatches: [TextSearchMatch] = [],
        currentMatch: TextSearchMatch? = nil,
        revealWhitespace: Bool = false
    ) -> [CompareTextRun] {
        let length = spans.reduce(0) { $0 + $1.text.count }
        guard length > 0 else { return [] }
        let kinds = SyntaxHighlighter.kindsPerCharacter(length: length, tokens: syntax)
        let search = searchPerCharacter(
            length: length, matches: searchMatches, current: currentMatch
        )

        var out: [CompareTextRun] = []
        var offset = 0
        for span in spans {
            let characters = Array(span.text)
            var i = 0
            while i < characters.count {
                let kind = kindAt(offset + i, in: kinds)
                let hit = searchAt(offset + i, in: search)
                // Cut wherever *any* of the three layers changes. Their
                // boundaries are unrelated — a query routinely starts inside a
                // keyword and ends inside a string — so anything coarser would
                // paint a hit over characters that are not part of it.
                var j = i + 1
                while j < characters.count,
                      kindAt(offset + j, in: kinds) == kind,
                      searchAt(offset + j, in: search) == hit {
                    j += 1
                }
                out.append(CompareTextRun(
                    text: String(characters[i..<j]),
                    kind: kind,
                    isChanged: span.kind == .changed,
                    search: hit
                ))
                i = j
            }
            offset += characters.count
        }
        return revealWhitespace ? revealing(out) : out
    }

    /// Expands tabs to their column stops and splits whitespace into runs
    /// of its own, so a pure-whitespace edit keeps its changed background.
    ///
    /// It deliberately does *not* substitute · → ¶ into the text: those are
    /// painted over the line by `WhitespaceOverlay`, since anything in the
    /// string ends up in the clipboard when the user selects and copies.
    ///
    /// Tab expansion happens here rather than on the raw line because every
    /// offset the syntax, word-diff and search layers work in refers to the
    /// *original* characters. Expanding before those layers are applied
    /// would shift each of them along by one character per tab. By the time
    /// a line is cut into runs the offsets have done their job.
    private static func revealing(_ runs: [CompareTextRun]) -> [CompareTextRun] {
        var out: [CompareTextRun] = []
        // Tracked across runs, not within one: a tab advances to the next
        // stop measured from the start of the line, and runs are cut at
        // syntax boundaries that have nothing to do with tab stops.
        var column = 0

        for run in runs {
            var buffer = ""
            var bufferIsWhitespace = false

            func flush() {
                guard !buffer.isEmpty else { return }
                out.append(CompareTextRun(
                    text: buffer,
                    kind: run.kind,
                    isChanged: run.isChanged,
                    search: run.search,
                    isWhitespace: bufferIsWhitespace
                ))
                buffer = ""
            }

            for character in run.text {
                switch character {
                case " ":
                    if !bufferIsWhitespace { flush(); bufferIsWhitespace = true }
                    buffer.append(" ")
                    column += 1
                case "\t":
                    if !bufferIsWhitespace { flush(); bufferIsWhitespace = true }
                    // Blanks out to the next stop, so revealing whitespace
                    // never re-indents the code. The arrow that marks the
                    // tab is painted over the first of them.
                    let advance = WhitespaceGlyph.tabWidth - (column % WhitespaceGlyph.tabWidth)
                    buffer.append(String(repeating: " ", count: advance))
                    column += advance
                default:
                    if bufferIsWhitespace { flush(); bufferIsWhitespace = false }
                    buffer.append(character)
                    column += 1
                }
            }
            flush()
        }
        return out
    }

    /// The same line the runs spell out, as one string, plus where each
    /// whitespace marker belongs. Callers pass the text to `Text` and hand
    /// this to `WhitespaceOverlay` to paint on top.
    ///
    /// Shares its tab arithmetic with `revealing` — the overlay's offsets
    /// only line up if both produce the same string, which
    /// `CompareTextLayoutTests` pins.
    static func revealed(_ line: String) -> RevealedLine {
        var text = ""
        var marks: [WhitespaceMark] = []
        var column = 0
        var utf16 = 0

        for character in line {
            switch character {
            case " ":
                marks.append(WhitespaceMark(utf16Offset: utf16, kind: .space))
                text.append(" ")
                column += 1
                utf16 += 1
            case "\t":
                let advance = WhitespaceGlyph.tabWidth - (column % WhitespaceGlyph.tabWidth)
                marks.append(WhitespaceMark(utf16Offset: utf16, kind: .tab))
                text.append(String(repeating: " ", count: advance))
                column += advance
                utf16 += advance
            default:
                text.append(character)
                column += 1
                utf16 += String(character).utf16.count
            }
        }
        marks.append(WhitespaceMark(utf16Offset: utf16, kind: .lineEnd))
        return RevealedLine(text: text, marks: marks)
    }

    /// Expands match ranges to one entry per character, the same way syntax
    /// tokens are expanded, so the three layers can be compared position by
    /// position rather than range against range.
    private static func searchPerCharacter(
        length: Int,
        matches: [TextSearchMatch],
        current: TextSearchMatch?
    ) -> [SearchHighlight?] {
        guard !matches.isEmpty else { return [] }
        var out = [SearchHighlight?](repeating: nil, count: length)
        for match in matches {
            // Clamped rather than trusted: the query can change between the
            // scan and the draw, and a stale offset should mis-highlight
            // rather than trap.
            let start = max(0, min(match.start, length))
            let end = max(start, min(match.end, length))
            guard start < end else { continue }
            let highlight: SearchHighlight = (match == current) ? .current : .match
            for i in start..<end {
                // `.current` wins if two matches somehow overlap.
                if out[i] != .current { out[i] = highlight }
            }
        }
        return out
    }

    private static func searchAt(_ index: Int, in search: [SearchHighlight?]) -> SearchHighlight? {
        search.indices.contains(index) ? search[index] : nil
    }

    private static func kindAt(_ index: Int, in kinds: [SyntaxTokenKind]) -> SyntaxTokenKind {
        kinds.indices.contains(index) ? kinds[index] : .plain
    }
}
