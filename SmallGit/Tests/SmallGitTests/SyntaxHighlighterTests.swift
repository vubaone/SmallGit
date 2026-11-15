import XCTest
@testable import SmallGit

/// Covers the scanner behind the compare views' syntax colouring.
///
/// The cases worth writing down are the ones where two rules want the same
/// character: a `//` inside a string, a quote inside a comment, `#` as a
/// preprocessor sigil in C and a comment in Python. Getting those wrong
/// doesn't crash — it silently paints the rest of a line, or a file, the wrong
/// colour, which in a diff reads as meaning.
final class SyntaxHighlighterTests: XCTestCase {

    // MARK: - Helpers

    /// The kind covering the first occurrence of `substring` in `line`.
    private func kind(
        of substring: String,
        in line: String,
        _ language: SyntaxLanguage,
        file: StaticString = #filePath,
        line lineNumber: UInt = #line
    ) -> SyntaxTokenKind? {
        guard let range = line.range(of: substring) else {
            XCTFail("\(substring.debugDescription) is not in \(line.debugDescription)",
                    file: file, line: lineNumber)
            return nil
        }
        let offset = line.distance(from: line.startIndex, to: range.lowerBound)
        let kinds = SyntaxHighlighter.kindsPerCharacter(
            length: line.count,
            tokens: SyntaxHighlighter.highlight(line: line, language: language)
        )
        return offset < kinds.count ? kinds[offset] : nil
    }

    /// Per-character kinds for one line of a multi-line document, so
    /// carried-over state is exercised rather than assumed.
    private func kinds(
        line index: Int,
        of document: String,
        _ language: SyntaxLanguage
    ) -> [SyntaxTokenKind] {
        let perLine = SyntaxHighlighter.highlight(document: document, language: language)
        let text = document.components(separatedBy: "\n")
        guard index < perLine.count, index < text.count else { return [] }
        return SyntaxHighlighter.kindsPerCharacter(
            length: text[index].count,
            tokens: perLine[index]
        )
    }

    // MARK: - Language detection

    func testLanguageIsDetectedFromTheExtension() {
        XCTAssertEqual(SyntaxLanguage(path: "a/b/Thing.swift"), .swift)
        XCTAssertEqual(SyntaxLanguage(path: "ProfileMusicBannerV2.m"), .objectiveC)
        XCTAssertEqual(SyntaxLanguage(path: "src/main.py"), .python)
        XCTAssertEqual(SyntaxLanguage(path: "deploy.sh"), .shell)
    }

    /// `.h` cannot be resolved from the extension, so it is decided by policy:
    /// Objective-C, whose spec is a superset of C's.
    func testObjectiveCHeadersAreNotLeftUncoloured() {
        XCTAssertEqual(SyntaxLanguage(path: "View.h"), .objectiveC)
        XCTAssertEqual(kind(of: "@interface", in: "@interface Foo : NSObject", .objectiveC), .directive)
        XCTAssertEqual(kind(of: "static", in: "static int counter;", .objectiveC), .keyword)
    }

    func testFilesNamedRatherThanExtendedAreRecognised() {
        XCTAssertEqual(SyntaxLanguage(path: "ios/Podfile"), .ruby)
        XCTAssertEqual(SyntaxLanguage(path: "package.json"), .json)
    }

    /// `nil` is a deliberate answer. Colouring a language the scanner cannot
    /// actually parse puts keywords in the wrong places, which is worse in a
    /// diff than no colour at all.
    func testUnknownAndProseFilesAreLeftAlone() {
        XCTAssertNil(SyntaxLanguage(path: "README.md"))
        XCTAssertNil(SyntaxLanguage(path: "index.html"))
        XCTAssertNil(SyntaxLanguage(path: "LICENSE"))
        XCTAssertNil(SyntaxLanguage(path: "data.bin"))
    }

    // MARK: - The basics

    func testKeywordsTypesNumbersAndStrings() {
        let line = #"let count: Int = 42 + parse("seven")"#
        XCTAssertEqual(kind(of: "let", in: line, .swift), .keyword)
        XCTAssertEqual(kind(of: "Int", in: line, .swift), .type)
        XCTAssertEqual(kind(of: "42", in: line, .swift), .number)
        XCTAssertEqual(kind(of: "parse", in: line, .swift), .function)
        XCTAssertEqual(kind(of: #""seven""#, in: line, .swift), .string)
        XCTAssertEqual(kind(of: "count", in: line, .swift), .plain)
    }

    /// The heuristics standing in for a symbol table, on the code they were
    /// chosen for. Cocoa capitalises types and nothing else, so this is most
    /// of what makes an Objective-C diff readable.
    func testCocoaNamingDrivesTheTypeAndFunctionGuesses() {
        let line = "MASConstraintMaker *make = CGRectMake(0, 0, w, h);"
        XCTAssertEqual(kind(of: "MASConstraintMaker", in: line, .objectiveC), .type)
        XCTAssertEqual(kind(of: "CGRectMake", in: line, .objectiveC), .function)
        XCTAssertEqual(kind(of: "make", in: line, .objectiveC), .plain)
    }

    /// A capitalised name that is being *called* is a function, not a type.
    /// Checking the call shape first is what keeps `CGRectMake(` out of the
    /// type colour.
    func testCallShapeBeatsCapitalisation() {
        XCTAssertEqual(kind(of: "NSLog", in: #"NSLog(@"hi");"#, .objectiveC), .function)
    }

    /// The one place the call heuristic is reliably wrong: an Objective-C
    /// class extension is `@interface Foo()`, a declaration wearing a call's
    /// shape. Being told a name is being declared settles it.
    func testADeclaredNameIsATypeEvenWhenItLooksLikeACall() {
        XCTAssertEqual(kind(of: "ProfileMusicBannerV2",
                            in: "@interface ProfileMusicBannerV2()", .objectiveC), .type)
        XCTAssertEqual(kind(of: "Thing", in: "class Thing {", .swift), .type)
        XCTAssertEqual(kind(of: "Parser", in: "struct Parser(", .swift), .type)
    }

    /// The rule reaches exactly one identifier and only across whitespace, so
    /// an argument list after a directive is not swept up with it.
    func testTheDeclarationRuleDoesNotLeakPastPunctuation() {
        XCTAssertEqual(kind(of: "setNeedsLayout",
                            in: "@selector(setNeedsLayout)", .objectiveC), .plain)
        XCTAssertEqual(kind(of: "helper", in: "class Thing { helper(); }", .swift), .function,
                       "only the name right after the keyword is claimed")
    }

    /// And a real keyword beats both guesses, whatever shape it is in.
    func testKeywordsBeatTheHeuristics() {
        XCTAssertEqual(kind(of: "if", in: "if (x) { }", .c), .keyword)
        XCTAssertEqual(kind(of: "return", in: "return (a + b);", .c), .keyword)
    }

    // MARK: - Characters two rules both want

    /// The classic. Everything after `//` inside a string literal is still the
    /// string — a scanner that checks comments without checking quotes first
    /// greys out the rest of every line containing a URL.
    func testSlashesInsideAStringAreNotAComment() {
        let line = #"let url = "https://example.com/path" // real comment"#
        XCTAssertEqual(kind(of: "https", in: line, .swift), .string)
        XCTAssertEqual(kind(of: "real", in: line, .swift), .comment)
    }

    /// And the mirror image: a quote inside a comment must not open a string
    /// that then swallows the following lines.
    func testAQuoteInsideACommentOpensNothing() {
        let document = """
        // it's fine
        let x = 1
        """
        let second = kinds(line: 1, of: document, .swift)
        XCTAssertEqual(second.first, .keyword, "the line after must scan normally")
    }

    func testEscapedQuoteDoesNotCloseTheString() {
        let line = #"NSString *s = @"a \" b"; int n = 1;"#
        XCTAssertEqual(kind(of: "b", in: line, .objectiveC), .string)
        XCTAssertEqual(kind(of: "int", in: line, .objectiveC), .type,
                       "the string closed at the unescaped quote, so code resumes")
    }

    /// `#` opens a preprocessor directive in C and a comment in Python. Each
    /// language's own rule has to win.
    func testHashIsADirectiveInCAndACommentInPython() {
        XCTAssertEqual(kind(of: "#import", in: "#import <UIKit/UIKit.h>", .objectiveC), .directive)
        XCTAssertEqual(kind(of: "#", in: "# not a directive", .python), .comment)
    }

    /// `@"…"` is one literal. Taking the `@` as a directive sigil would leave
    /// a stray directive and an unattached string.
    func testObjectiveCStringLiteralKeepsItsAtSign() {
        let line = #"label.text = @"hello";"#
        XCTAssertEqual(kind(of: "@", in: line, .objectiveC), .string)
        XCTAssertEqual(kind(of: "hello", in: line, .objectiveC), .string)
    }

    func testIncludePathIsColouredAsAPathNotAsComparisons() {
        let line = "#import <Foundation/Foundation.h>"
        XCTAssertEqual(kind(of: "<Foundation", in: line, .objectiveC), .string)
    }

    /// `--` is SQL's line comment and a decrement operator elsewhere.
    func testSqlUsesDoubleDashComments() {
        XCTAssertEqual(kind(of: "-- note", in: "SELECT 1 -- note", .sql), .comment)
        XCTAssertEqual(kind(of: "SELECT", in: "SELECT 1 -- note", .sql), .keyword)
    }

    /// SQL keywords are case-insensitive; nothing else here is.
    func testSqlKeywordsMatchInAnyCase() {
        XCTAssertEqual(kind(of: "select", in: "select * from t", .sql), .keyword)
        XCTAssertEqual(kind(of: "FROM", in: "SELECT * FROM t", .sql), .keyword)
        XCTAssertEqual(kind(of: "Let", in: "Let x = 1", .swift), .type,
                       "case sensitivity elsewhere: Let is not the keyword let")
    }

    /// Ruby method names carry a trailing `?` or `!`. No C-family language may
    /// do this, or `cond?a:b` scans as an identifier called `cond?a`.
    func testTrailingPunctuationIsPartOfARubyNameOnly() {
        XCTAssertEqual(kind(of: "empty?", in: "return list.empty?", .ruby), .plain)
        XCTAssertEqual(kind(of: "cond", in: "x = cond?a:b;", .c), .plain)
        XCTAssertEqual(kind(of: "a", in: "x = cond?a:b;", .c), .plain)
    }

    // MARK: - State that crosses lines

    /// The reason `highlight(document:)` exists. From inside line 2 there is
    /// nothing to see; only the scanner's carried state knows it is a comment.
    func testBlockCommentSpansEveryLineItCovers() {
        let document = """
        int a = 1;
        /* opening
        still a comment
        last */ int b = 2;
        """
        XCTAssertEqual(kinds(line: 1, of: document, .c).first, .comment)
        XCTAssertEqual(Set(kinds(line: 2, of: document, .c)), [.comment])
        let closing = kinds(line: 3, of: document, .c)
        XCTAssertEqual(closing.first, .comment)
        XCTAssertEqual(closing.last, .plain, "code after the close is code again")
    }

    /// Swift and Rust count `/*` inside a block comment; C does not, so C's
    /// comment ends at the first `*/`.
    func testNestedBlockCommentsFollowTheLanguage() {
        let document = """
        /* outer /* inner */ still comment */
        let after = 1
        """
        XCTAssertEqual(Set(kinds(line: 0, of: document, .swift)), [.comment])
        XCTAssertEqual(kinds(line: 1, of: document, .swift).first, .keyword)

        let cDocument = """
        /* outer /* inner */ code_again();
        int x;
        """
        XCTAssertEqual(kind(of: "code_again", in: "/* outer /* inner */ code_again();", .c),
                       .function)
        XCTAssertEqual(kinds(line: 1, of: cDocument, .c).first, .type)
    }

    func testPythonDocstringSpansLines() {
        let document = """
        def f():
            \"\"\"Explains
            across lines.\"\"\"
            return 1
        """
        XCTAssertEqual(Set(kinds(line: 2, of: document, .python)).subtracting([.plain]), [.string])
        XCTAssertEqual(kind(of: "return", in: "    return 1", .python), .keyword)
    }

    /// An unterminated single-line string stops at the newline. Carrying it
    /// would paint the rest of the file as a string over one stray quote —
    /// exactly the state a half-edited file in a diff is often in.
    func testUnterminatedStringDoesNotLeakIntoTheNextLine() {
        let document = """
        let broken = "oops
        let fine = 1
        """
        XCTAssertEqual(kinds(line: 1, of: document, .swift).first, .keyword)
    }

    // MARK: - Invariants the renderer depends on

    /// The renderer walks kinds and diff spans in lockstep by character
    /// offset, so a length mismatch would shift every colour on the line.
    func testKindsCoverExactlyTheLine() {
        let line = #"static CGFloat const kSize = 64.0f; // trailing"#
        let kinds = SyntaxHighlighter.kindsPerCharacter(
            length: line.count,
            tokens: SyntaxHighlighter.highlight(line: line, language: .objectiveC)
        )
        XCTAssertEqual(kinds.count, line.count)
    }

    /// Tokens are emitted in order and never overlap, which is what lets
    /// `kindsPerCharacter` fill an array in one pass without sorting.
    func testTokensAreOrderedAndDisjoint() {
        let line = #"NSString *s = @"x"; /* c */ int n = 0xFF; // tail"#
        let tokens = SyntaxHighlighter.highlight(line: line, language: .objectiveC)
        for (previous, next) in zip(tokens, tokens.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.end, next.start,
                                     "\(previous) overlaps \(next)")
        }
        for token in tokens {
            XCTAssertGreaterThanOrEqual(token.start, 0)
            XCTAssertLessThanOrEqual(token.end, line.count)
            XCTAssertGreaterThan(token.length, 0)
        }
    }

    /// Offsets are counted in `Character`s because that is what the renderer
    /// counts. A line with a multi-scalar grapheme in it would otherwise drift.
    func testOffsetsAreCharacterBasedNotScalarBased() {
        let line = #"let flag = "🇻🇳" // after"#
        XCTAssertEqual(kind(of: "// after", in: line, .swift), .comment)
        let tokens = SyntaxHighlighter.highlight(line: line, language: .swift)
        for token in tokens {
            XCTAssertLessThanOrEqual(token.end, line.count)
        }
    }

    /// A diff shows plenty of these.
    func testEmptyAndWhitespaceLinesProduceNoTokens() {
        XCTAssertTrue(SyntaxHighlighter.highlight(line: "", language: .swift).isEmpty)
        XCTAssertTrue(SyntaxHighlighter.highlight(line: "    ", language: .swift).isEmpty)
        XCTAssertEqual(SyntaxHighlighter.kindsPerCharacter(length: 0, tokens: []), [])
    }

    /// Every line of the document gets an entry, so the renderer can index by
    /// line number without a bounds dance.
    func testDocumentReturnsOneEntryPerLine() {
        let document = "a\n\nb\n"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(document: document, language: .swift).count,
            document.components(separatedBy: "\n").count
        )
    }

    /// Mismatched tokens must clamp rather than trap: the renderer pairs a
    /// line with tokens by index, and an off-by-one there should mis-colour,
    /// not crash the window.
    func testOutOfRangeTokensAreClampedNotFatal() {
        let kinds = SyntaxHighlighter.kindsPerCharacter(
            length: 4,
            tokens: [
                SyntaxToken(start: 2, length: 99, kind: .string),
                SyntaxToken(start: -5, length: 3, kind: .comment),
                SyntaxToken(start: 40, length: 2, kind: .keyword)
            ]
        )
        XCTAssertEqual(kinds.count, 4)
        XCTAssertEqual(kinds[3], .string)
    }
}
