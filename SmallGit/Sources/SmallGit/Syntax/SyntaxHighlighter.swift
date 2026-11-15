import Foundation

/// What a run of characters is, for colouring purposes.
///
/// Coarse on purpose. A diff is read for *what changed*, so syntax colour is
/// there to give the eye structure — string here, comment there — not to
/// out-resolve an IDE. Finer categories would compete with the red/green that
/// carries the diff's actual meaning.
enum SyntaxTokenKind: String, Sendable, Hashable, CaseIterable {
    case keyword
    case type
    case string
    case number
    case comment
    /// `#import`, `#if`, `@interface`, `@objc`, `@media`, a Python decorator.
    case directive
    case function
    case plain
}

/// A run of `length` characters starting at character offset `start` in its
/// line.
///
/// Offsets are counted in `Character`s, not UTF-8 bytes or UTF-16 units,
/// because the renderer walks the same line as `Character`s when it slices the
/// word-diff spans. Any other unit would drift apart on the first emoji in a
/// string literal and mis-colour the rest of the line.
struct SyntaxToken: Hashable, Sendable {
    let start: Int
    let length: Int
    let kind: SyntaxTokenKind

    var end: Int { start + length }
}

/// What the scanner was in the middle of when a line ended.
///
/// This is the whole reason `highlight(document:)` exists alongside
/// `highlight(line:)`: a block comment or a docstring is invisible from inside
/// any single one of its lines.
enum SyntaxScanState: Sendable, Hashable {
    case normal
    case blockComment(depth: Int)
    case multilineString(delimiter: [Character])
}

/// A hand-written scanner that turns source text into coloured runs.
///
/// It is a lexer, not a parser: it knows comments from strings from numbers
/// from keywords, and guesses at types and function names from shape. That
/// ceiling is deliberate — a real parse would need a grammar per language and
/// would still be wrong on the half-edited, mid-conflict files a diff viewer
/// spends its time showing.
enum SyntaxHighlighter {

    // MARK: - Entry points

    /// Colour a whole document, returning one token list per line.
    ///
    /// Prefer this wherever the full text is at hand. It threads the scanner's
    /// state from line to line, so a block comment or a Python docstring is
    /// coloured across every line it spans rather than only the one that opens
    /// it.
    static func highlight(document: String, language: SyntaxLanguage) -> [[SyntaxToken]] {
        let spec = language.spec
        var state = SyntaxScanState.normal
        var out: [[SyntaxToken]] = []

        for line in document.split(separator: "\n", omittingEmptySubsequences: false) {
            let result = scan(line: Array(line), spec: spec, state: state)
            out.append(result.tokens)
            state = result.next
        }
        return out
    }

    /// Colour a single line with no knowledge of the ones around it.
    ///
    /// For callers that only ever hold a diff hunk — the lines either side of
    /// a `+` are not the file, and fetching the file to colour three lines of
    /// context is not worth a `git show`. The cost is that a `/* … */` opened
    /// on an earlier line reads as ordinary code here, which is the usual
    /// trade every hunk-based viewer makes.
    static func highlight(line: String, language: SyntaxLanguage) -> [SyntaxToken] {
        scan(line: Array(line), spec: language.spec, state: .normal).tokens
    }

    /// Expand tokens into one kind per character, `.plain` where no token
    /// covers the position.
    ///
    /// The renderer needs to intersect syntax runs with word-diff spans, which
    /// have entirely unrelated boundaries. Comparing two run-length encodings
    /// is fiddly and easy to get subtly wrong; comparing per-character kinds is
    /// obvious, and a line is short enough that the array costs nothing.
    static func kindsPerCharacter(length: Int, tokens: [SyntaxToken]) -> [SyntaxTokenKind] {
        guard length > 0 else { return [] }
        var kinds = [SyntaxTokenKind](repeating: .plain, count: length)
        for token in tokens {
            // Clamped rather than trusted: the length here comes from the
            // renderer's own reassembly of the line, and a caller that pairs a
            // line with the wrong line's tokens should mis-colour, not crash.
            let start = max(0, token.start)
            let end = min(length, token.end)
            guard start < end else { continue }
            for i in start..<end { kinds[i] = token.kind }
        }
        return kinds
    }

    // MARK: - The scanner

    static func scan(
        line chars: [Character],
        spec: SyntaxLanguage.Spec,
        state initial: SyntaxScanState
    ) -> (tokens: [SyntaxToken], next: SyntaxScanState) {
        var tokens: [SyntaxToken] = []
        var state = initial
        let n = chars.count
        var i = 0
        /// Set by `#import` / `#include` so the `<stdio.h>` that follows reads
        /// as a path rather than as two comparison operators.
        var expectingAngleInclude = false
        /// Set by `class`, `@interface` and friends: the very next identifier
        /// is a name being declared, so it is a type even if it is immediately
        /// followed by `(` — which is how an Objective-C class extension is
        /// written. Cleared by anything other than the identifier itself, so
        /// `@selector(foo)` doesn't pick it up.
        var expectingDeclaredType = false

        // Finish whatever the previous line left open before scanning anything
        // new — the opening delimiter is not on this line to be found.
        switch initial {
        case .blockComment(let depth):
            let run = consumeBlockComment(chars, from: 0, spec: spec, depth: depth)
            if run.end > 0 {
                tokens.append(SyntaxToken(start: 0, length: run.end, kind: .comment))
            }
            i = run.end
            state = run.depth > 0 ? .blockComment(depth: run.depth) : .normal

        case .multilineString(let delimiter):
            let run = consumeMultilineString(chars, from: 0, delimiter: delimiter, spec: spec)
            if run.end > 0 {
                tokens.append(SyntaxToken(start: 0, length: run.end, kind: .string))
            }
            i = run.end
            state = run.closed ? .normal : .multilineString(delimiter: delimiter)

        case .normal:
            break
        }
        // Still open means it swallowed the whole line; nothing left to scan.
        if state != .normal { return (tokens, state) }

        while i < n {
            let c = chars[i]

            if c.isWhitespace {
                i += 1
                continue
            }

            // Comments first, always. `#` is a comment in Python and a
            // directive sigil in C, and `--` is a comment in SQL and an
            // operator everywhere else — whichever the language says wins here,
            // before anything can claim the character for another meaning.
            if matchesAny(spec.lineComments, chars, at: i) != nil {
                tokens.append(SyntaxToken(start: i, length: n - i, kind: .comment))
                i = n
                continue
            }

            if let open = spec.blockCommentOpen, matches(open, chars, at: i) {
                let run = consumeBlockComment(chars, from: i + open.count, spec: spec, depth: 1)
                tokens.append(SyntaxToken(start: i, length: run.end - i, kind: .comment))
                i = run.end
                if run.depth > 0 {
                    state = .blockComment(depth: run.depth)
                    break
                }
                continue
            }

            // Longest delimiter first: `"""` has to be tested before `"`, or
            // every docstring would open and close on its own first quote.
            if let delimiter = matchesAny(spec.multilineStringDelimiters, chars, at: i) {
                let run = consumeMultilineString(
                    chars, from: i + delimiter.count, delimiter: delimiter, spec: spec
                )
                tokens.append(SyntaxToken(start: i, length: run.end - i, kind: .string))
                i = run.end
                if !run.closed {
                    state = .multilineString(delimiter: delimiter)
                    break
                }
                continue
            }

            // `@"text"` in Objective-C: the sigil belongs to the literal. Has
            // to be tested before the directive sigil below, which would
            // otherwise take the `@` and leave a bare string behind it.
            if spec.stringSigils.contains(c),
               i + 1 < n,
               spec.stringDelimiters.contains(chars[i + 1])
            {
                let end = consumeString(chars, from: i + 2, delimiter: chars[i + 1], spec: spec)
                tokens.append(SyntaxToken(start: i, length: end - i, kind: .string))
                i = end
                continue
            }

            if spec.stringDelimiters.contains(c) {
                let end = consumeString(chars, from: i + 1, delimiter: c, spec: spec)
                tokens.append(SyntaxToken(start: i, length: end - i, kind: .string))
                i = end
                continue
            }

            if expectingAngleInclude, c == "<",
               let close = index(of: ">", in: chars, from: i + 1)
            {
                tokens.append(SyntaxToken(start: i, length: close + 1 - i, kind: .string))
                i = close + 1
                expectingAngleInclude = false
                continue
            }

            // A leading `.` counts so `.5f` reads as one number rather than a
            // member access on a stray digit.
            if c.isNumber || (c == "." && i + 1 < n && chars[i + 1].isNumber) {
                let end = consumeNumber(chars, from: i)
                tokens.append(SyntaxToken(start: i, length: end - i, kind: .number))
                i = end
                continue
            }

            if spec.directiveSigils.contains(c),
               i + 1 < n,
               isIdentifierStart(chars[i + 1])
            {
                let end = consumeIdentifier(chars, from: i + 1, spec: spec)
                let word = String(chars[(i + 1)..<end])
                tokens.append(SyntaxToken(start: i, length: end - i, kind: .directive))
                if spec.angleBracketIncludes, word == "import" || word == "include" {
                    expectingAngleInclude = true
                }
                expectingDeclaredType = spec.declarationKeywords.contains(String(chars[i..<end]))
                i = end
                continue
            }

            if isIdentifierStart(c) {
                let end = consumeIdentifier(chars, from: i, spec: spec)
                let word = String(chars[i..<end])
                let kind: SyntaxTokenKind? = expectingDeclaredType
                    ? SyntaxTokenKind.type
                    : classify(word, chars: chars, after: end, spec: spec)
                if let kind {
                    tokens.append(SyntaxToken(start: i, length: end - i, kind: kind))
                }
                expectingDeclaredType = spec.declarationKeywords.contains(word)
                i = end
                continue
            }

            // Punctuation and operators stay plain. Emitting no token at all
            // rather than a `.plain` one keeps the arrays short — punctuation
            // is most of what a line is made of.
            expectingDeclaredType = false
            i += 1
        }

        return (tokens, state)
    }

    // MARK: - Identifier classification

    /// What an identifier means, or `nil` to leave it uncoloured.
    ///
    /// The last two rules are heuristics standing in for a symbol table:
    /// "followed by `(`" for functions, and "starts with a capital" for types.
    /// They earn their place on Cocoa and Swift code, where `CGRectMake(` and
    /// `MASConstraintMaker` are exactly what the eye is looking for — and they
    /// are checked last so a real keyword or built-in type never loses to a
    /// guess.
    private static func classify(
        _ word: String,
        chars: [Character],
        after end: Int,
        spec: SyntaxLanguage.Spec
    ) -> SyntaxTokenKind? {
        let lookup = spec.caseInsensitiveKeywords ? word.lowercased() : word

        if spec.keywords.contains(lookup) { return .keyword }
        if spec.constants.contains(lookup) { return .keyword }
        if spec.types.contains(lookup) { return .type }
        if isFollowedByCall(chars, from: end) { return .function }
        if spec.capitalisedIsType, let first = word.first, first.isUppercase { return .type }
        return nil
    }

    /// True when the next non-space character opens an argument list.
    private static func isFollowedByCall(_ chars: [Character], from index: Int) -> Bool {
        var i = index
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        return i < chars.count && chars[i] == "("
    }

    // MARK: - Consumers

    /// Runs to the closing delimiter, or to the end of the line.
    ///
    /// An unterminated single-line string does not carry into the next line:
    /// it is a syntax error, and assuming otherwise would paint the entire
    /// rest of the file as a string over one stray quote in a diff.
    private static func consumeString(
        _ chars: [Character],
        from index: Int,
        delimiter: Character,
        spec: SyntaxLanguage.Spec
    ) -> Int {
        var i = index
        while i < chars.count {
            if let escape = spec.escape, chars[i] == escape {
                i = min(i + 2, chars.count)
                continue
            }
            if chars[i] == delimiter { return i + 1 }
            i += 1
        }
        return chars.count
    }

    private static func consumeMultilineString(
        _ chars: [Character],
        from index: Int,
        delimiter: [Character],
        spec: SyntaxLanguage.Spec
    ) -> (end: Int, closed: Bool) {
        var i = index
        while i < chars.count {
            if let escape = spec.escape, chars[i] == escape {
                i = min(i + 2, chars.count)
                continue
            }
            if matches(delimiter, chars, at: i) { return (i + delimiter.count, true) }
            i += 1
        }
        return (chars.count, false)
    }

    /// Returns where the comment ends on this line and how deep it still is.
    /// A non-zero depth means it continues on the next line.
    private static func consumeBlockComment(
        _ chars: [Character],
        from index: Int,
        spec: SyntaxLanguage.Spec,
        depth startDepth: Int
    ) -> (end: Int, depth: Int) {
        guard let open = spec.blockCommentOpen, let close = spec.blockCommentClose else {
            return (chars.count, 0)
        }
        var i = index
        var depth = startDepth
        while i < chars.count {
            if spec.nestedBlockComments, matches(open, chars, at: i) {
                depth += 1
                i += open.count
                continue
            }
            if matches(close, chars, at: i) {
                depth -= 1
                i += close.count
                if depth <= 0 { return (i, 0) }
                continue
            }
            i += 1
        }
        return (chars.count, depth)
    }

    /// Covers `42`, `0xFF`, `0b1010`, `1_000_000`, `3.14`, `1e-9`, and the
    /// trailing `f` / `UL` / `LL` suffixes C-family code is full of.
    private static func consumeNumber(_ chars: [Character], from index: Int) -> Int {
        var i = index
        if chars[i] == "0", i + 1 < chars.count,
           let marker = chars[i + 1].lowercased().first,
           marker == "x" || marker == "b" || marker == "o"
        {
            i += 2
            while i < chars.count, chars[i].isHexDigit || chars[i] == "_" { i += 1 }
        } else {
            var seenDot = false
            var seenExponent = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber || c == "_" {
                    i += 1
                } else if c == ".", !seenDot, !seenExponent,
                          i + 1 < chars.count, chars[i + 1].isNumber {
                    seenDot = true
                    i += 1
                } else if (c == "e" || c == "E"), !seenExponent, i + 1 < chars.count,
                          chars[i + 1].isNumber || chars[i + 1] == "-" || chars[i + 1] == "+" {
                    seenExponent = true
                    i += 2
                } else {
                    break
                }
            }
        }
        // Numeric suffixes: f, F, u, U, l, L, and Rust/Swift's i32 / UInt8.
        while i < chars.count, chars[i].isLetter { i += 1 }
        return i
    }

    private static func consumeIdentifier(
        _ chars: [Character],
        from index: Int,
        spec: SyntaxLanguage.Spec
    ) -> Int {
        var i = index
        while i < chars.count, isIdentifierBody(chars[i], spec: spec) { i += 1 }
        return i
    }

    /// `$` is in here for JavaScript and shell; `_` for everything.
    private static func isIdentifierStart(_ c: Character) -> Bool {
        c.isLetter || c == "_" || c == "$"
    }

    /// `extraIdentifierCharacters` is what makes Ruby's `empty?` and `save!`
    /// one word. It is per-language rather than universal because the same two
    /// characters are operators elsewhere: allowing them everywhere would read
    /// C's `cond?a:b` as an identifier called `cond?a`.
    private static func isIdentifierBody(_ c: Character, spec: SyntaxLanguage.Spec) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "$"
            || spec.extraIdentifierCharacters.contains(c)
    }

    // MARK: - Matching

    private static func matches(_ needle: [Character], _ chars: [Character], at index: Int) -> Bool {
        guard !needle.isEmpty, index + needle.count <= chars.count else { return false }
        for offset in 0..<needle.count where chars[index + offset] != needle[offset] {
            return false
        }
        return true
    }

    private static func matchesAny(
        _ needles: [[Character]],
        _ chars: [Character],
        at index: Int
    ) -> [Character]? {
        needles.first { matches($0, chars, at: index) }
    }

    private static func index(of needle: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == needle { return i }
            i += 1
        }
        return nil
    }
}
