import Foundation

/// Translates the scanner's offsets into the ones AppKit's text storage uses.
///
/// `SyntaxToken` counts in `Character`s, because that is what the SwiftUI
/// renderers count when they slice a line. `NSTextStorage` indexes in UTF-16.
/// The two agree for ASCII and diverge at the first emoji, flag or combining
/// mark — after which every colour on the line lands a few characters to the
/// left, which looks like a highlighter bug rather than an encoding one.
enum SyntaxTextRanges {

    struct Styled: Hashable, Sendable {
        let range: NSRange
        let kind: SyntaxTokenKind
    }

    /// UTF-16 ranges for `tokens` within `line`, offset by `lineStart`.
    ///
    /// `lineStart` is the line's own UTF-16 offset inside the document, so the
    /// result can be applied to the whole text storage directly. Tokens
    /// reaching past the end of the line are clamped rather than dropped —
    /// mismatched input should mis-colour, never crash an editor the user is
    /// typing into.
    static func utf16Ranges(
        line: String,
        tokens: [SyntaxToken],
        lineStart: Int
    ) -> [Styled] {
        guard !tokens.isEmpty else { return [] }

        let characters = Array(line)
        // offsets[i] is the UTF-16 distance from the start of the line to the
        // start of character i; offsets[count] is the line's UTF-16 length.
        var offsets = [Int](repeating: 0, count: characters.count + 1)
        var running = 0
        for (index, character) in characters.enumerated() {
            offsets[index] = running
            running += String(character).utf16.count
        }
        offsets[characters.count] = running

        return tokens.compactMap { token in
            let start = max(0, min(token.start, characters.count))
            let end = max(start, min(token.end, characters.count))
            guard start < end else { return nil }
            return Styled(
                range: NSRange(
                    location: lineStart + offsets[start],
                    length: offsets[end] - offsets[start]
                ),
                kind: token.kind
            )
        }
    }

    /// UTF-16 offset of each line's first character, for a document split on
    /// `\n`. The `+ 1` is the newline that `components(separatedBy:)` removed.
    static func lineStarts(of lines: [String]) -> [Int] {
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var running = 0
        for line in lines {
            starts.append(running)
            running += (line as NSString).length + 1
        }
        return starts
    }
}
