import XCTest
@testable import SmallGit

/// Covers the bridge between the scanner's offsets and AppKit's.
///
/// The conflict resolver's merged pane is an `NSTextView`, so its colouring
/// goes through `NSTextStorage`, which indexes in UTF-16 — while every token
/// the scanner produces counts in `Character`s. For ASCII the two agree, which
/// is exactly why getting this wrong survives casual testing and then shifts
/// every colour on the one line containing an emoji.
final class SyntaxTextRangesTests: XCTestCase {

    private func ranges(_ line: String, _ tokens: [SyntaxToken], start: Int = 0) -> [NSRange] {
        SyntaxTextRanges.utf16Ranges(line: line, tokens: tokens, lineStart: start).map(\.range)
    }

    /// The baseline: with ASCII the two coordinate systems coincide.
    func testASCIIOffsetsPassStraightThrough() {
        let line = "let x = 1"
        let tokens = [SyntaxToken(start: 0, length: 3, kind: .keyword)]
        XCTAssertEqual(ranges(line, tokens), [NSRange(location: 0, length: 3)])
    }

    /// The case that motivates the whole file. A flag emoji is one `Character`
    /// and four UTF-16 units, so a token after it sits four units further
    /// along than its character offset suggests.
    func testAMultiScalarCharacterShiftsLaterTokens() {
        let line = #"let flag = "🇻🇳" // tail"#
        let characters = Array(line)
        let commentStart = characters.firstIndex(of: "/") ?? 0
        let tokens = [SyntaxToken(
            start: commentStart,
            length: characters.count - commentStart,
            kind: .comment
        )]

        let range = try? XCTUnwrap(ranges(line, tokens).first)
        let nsLine = line as NSString
        XCTAssertEqual(
            nsLine.substring(with: range ?? NSRange(location: 0, length: 0)),
            "// tail",
            "the range must land on the comment, not four units to its left"
        )
    }

    /// Every produced range must be a valid index into the same string.
    func testRangesAlwaysLieInsideTheLine() {
        let line = "let 🇻🇳 = \"héllo\" // ünïcode"
        let characters = Array(line)
        let tokens = (0..<characters.count).map {
            SyntaxToken(start: $0, length: 1, kind: .plain)
        }
        let nsLine = line as NSString
        for range in ranges(line, tokens) {
            XCTAssertLessThanOrEqual(NSMaxRange(range), nsLine.length)
            XCTAssertGreaterThan(range.length, 0)
        }
    }

    /// Reassembling every token's substring must give the line back — the
    /// strongest statement that nothing shifted.
    func testPerCharacterRangesReassembleTheLine() {
        let line = "if 🇻🇳 { return \"é\" }"
        let characters = Array(line)
        let tokens = (0..<characters.count).map {
            SyntaxToken(start: $0, length: 1, kind: .plain)
        }
        let nsLine = line as NSString
        let rebuilt = ranges(line, tokens).map { nsLine.substring(with: $0) }.joined()
        XCTAssertEqual(rebuilt, line)
    }

    func testLineStartIsAddedToEveryRange() {
        let tokens = [SyntaxToken(start: 0, length: 2, kind: .keyword)]
        XCTAssertEqual(ranges("if x", tokens, start: 100), [NSRange(location: 100, length: 2)])
    }

    /// Line starts must account for the newline that splitting removed, or
    /// every line after the first is coloured one unit early.
    func testLineStartsAccountForTheNewline() {
        XCTAssertEqual(SyntaxTextRanges.lineStarts(of: ["ab", "cde", ""]), [0, 3, 7])
    }

    func testLineStartsCountUTF16NotCharacters() {
        // A flag is one Character and two surrogate pairs — 4 UTF-16 units —
        // so the following line starts at 5, not at 2.
        XCTAssertEqual(("🇻🇳" as NSString).length, 4)
        XCTAssertEqual("🇻🇳".count, 1)
        XCTAssertEqual(SyntaxTextRanges.lineStarts(of: ["🇻🇳", "x"]), [0, 5])
    }

    /// A token pointing past the end must clamp, not trap: this runs inside a
    /// text view the user is typing into, where the text and the last scan can
    /// briefly disagree.
    func testOutOfRangeTokensClampInsteadOfCrashing() {
        let line = "abc"
        let tokens = [
            SyntaxToken(start: 1, length: 999, kind: .string),
            SyntaxToken(start: -4, length: 2, kind: .comment),
            SyntaxToken(start: 50, length: 3, kind: .keyword)
        ]
        for range in ranges(line, tokens) {
            XCTAssertLessThanOrEqual(NSMaxRange(range), (line as NSString).length)
        }
    }

    func testEmptyInputProducesNoRanges() {
        XCTAssertTrue(ranges("", []).isEmpty)
        XCTAssertTrue(ranges("abc", []).isEmpty)
        XCTAssertTrue(SyntaxTextRanges.lineStarts(of: []).isEmpty)
    }

    /// End to end on a real line, through the real scanner.
    func testRealScannerOutputMapsOntoTheRightSubstrings() {
        let line = #"static CGFloat const kSize = 64.0f; // note"#
        let tokens = SyntaxHighlighter.highlight(line: line, language: .objectiveC)
        let styled = SyntaxTextRanges.utf16Ranges(line: line, tokens: tokens, lineStart: 0)
        let nsLine = line as NSString

        let comment = styled.first { $0.kind == .comment }
        XCTAssertEqual(comment.map { nsLine.substring(with: $0.range) }, "// note")

        let number = styled.first { $0.kind == .number }
        XCTAssertEqual(number.map { nsLine.substring(with: $0.range) }, "64.0f")
    }
}
