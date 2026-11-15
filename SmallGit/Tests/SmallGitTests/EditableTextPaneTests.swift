import XCTest
import SwiftUI
import AppKit
@testable import SmallGit

/// Covers the conflict resolver's merged pane.
///
/// This one is an `NSTextView` rather than a `TextEditor`, so it is the only
/// place in the app that colours text through `NSTextStorage` — and the only
/// place where the scanner's `Character` offsets have to be translated into
/// UTF-16. It is also an editor the user types a merge into, so "does not
/// crash and does not move the cursor" matters as much as "is the right
/// colour".
@MainActor
final class EditableTextPaneTests: XCTestCase {

    private func makeCoordinator(_ syntax: SyntaxLanguage?) -> EditableTextPane.Coordinator {
        EditableTextPane(text: .constant(""), syntax: syntax).makeCoordinator()
    }

    private func textView(_ source: String) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = source
        return view
    }

    private func color(of view: NSTextView, at index: Int) -> NSColor? {
        view.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    /// Colours land on the tokens they belong to.
    func testKeywordsAndStringsGetTheirOwnColours() throws {
        let source = #"let name = "value""#
        let view = textView(source)
        makeCoordinator(.swift).highlight(view, syntax: .swift, fontSize: 12)

        let nsSource = source as NSString
        let keyword = try XCTUnwrap(color(of: view, at: 0))
        let string = try XCTUnwrap(color(of: view, at: nsSource.range(of: "\"value\"").location))
        let plain = try XCTUnwrap(color(of: view, at: nsSource.range(of: "name").location))

        XCTAssertEqual(keyword, NSColor(SyntaxTokenKind.keyword.color))
        XCTAssertEqual(string, NSColor(SyntaxTokenKind.string.color))
        XCTAssertEqual(plain, NSColor(Color.textPrimary))
        XCTAssertNotEqual(keyword, string)
    }

    /// The whole point of the UTF-16 translation: a wide character must not
    /// shift the colours of everything after it.
    func testColoursStayAlignedPastAMultiScalarCharacter() throws {
        let source = #"let flag = "🇻🇳" // trailing"#
        let view = textView(source)
        makeCoordinator(.swift).highlight(view, syntax: .swift, fontSize: 12)

        let commentStart = (source as NSString).range(of: "// trailing").location
        XCTAssertEqual(try XCTUnwrap(color(of: view, at: commentStart)),
                       NSColor(SyntaxTokenKind.comment.color))
    }

    /// A block comment opened on one line must colour the next, which only
    /// works because the pane scans the whole document rather than each line.
    func testAMultiLineCommentIsColouredAcrossItsLines() throws {
        let source = "let a = 1\n/* opening\nstill comment */\nlet b = 2"
        let view = textView(source)
        makeCoordinator(.swift).highlight(view, syntax: .swift, fontSize: 12)

        let middle = (source as NSString).range(of: "still comment").location
        XCTAssertEqual(try XCTUnwrap(color(of: view, at: middle)),
                       NSColor(SyntaxTokenKind.comment.color))

        let after = (source as NSString).range(of: "let b").location
        XCTAssertEqual(try XCTUnwrap(color(of: view, at: after)),
                       NSColor(SyntaxTokenKind.keyword.color))
    }

    /// Conflict markers are not source in any language. They must render as
    /// ordinary text rather than derailing the scan for the rest of the file.
    func testConflictMarkersDoNotDisturbTheRest() throws {
        let source = """
        <<<<<<< HEAD
        let ours = 1
        =======
        let theirs = 2
        >>>>>>> branch
        """
        let view = textView(source)
        makeCoordinator(.swift).highlight(view, syntax: .swift, fontSize: 12)

        for keyword in ["let ours", "let theirs"] {
            let location = (source as NSString).range(of: keyword).location
            XCTAssertEqual(try XCTUnwrap(color(of: view, at: location)),
                           NSColor(SyntaxTokenKind.keyword.color),
                           "\(keyword) must still colour normally")
        }
    }

    /// No language means the pane renders exactly as it did before.
    func testWithoutALanguageEverythingIsPlain() throws {
        let source = "let name = 1"
        let view = textView(source)
        makeCoordinator(nil).highlight(view, syntax: nil, fontSize: 12)

        for index in 0..<(source as NSString).length {
            XCTAssertEqual(try XCTUnwrap(color(of: view, at: index)), NSColor(Color.textPrimary))
        }
    }

    /// The font is applied to everything, so re-colouring can't leave a run
    /// in the system font.
    func testTheMonospacedFontCoversTheWholeDocument() throws {
        let source = "let a = 1\nlet b = 2"
        let view = textView(source)
        makeCoordinator(.swift).highlight(view, syntax: .swift, fontSize: 14)

        let storage = try XCTUnwrap(view.textStorage)
        for index in 0..<storage.length {
            let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            XCTAssertEqual(font?.pointSize, 14)
        }
    }

    /// Highlighting runs under the user's cursor, so it must not move it.
    func testHighlightingLeavesTheSelectionAlone() {
        let source = "let value = 42"
        let view = textView(source)
        let selection = NSRange(location: 4, length: 5)
        view.setSelectedRange(selection)

        makeCoordinator(.swift).highlight(view, syntax: .swift, fontSize: 12)

        XCTAssertEqual(view.selectedRange(), selection)
    }

    /// Empty and whitespace-only documents are ordinary states for a merged
    /// pane mid-edit.
    func testEmptyDocumentIsHandled() {
        let view = textView("")
        makeCoordinator(.swift).highlight(view, syntax: .swift, fontSize: 12)
        XCTAssertEqual(view.textStorage?.length, 0)
    }

    /// Re-highlighting must be idempotent: it runs on a debounce after every
    /// pause in typing, so a leak of stale attributes would compound.
    func testRepeatedHighlightingIsStable() throws {
        let source = #"let s = "x" // c"#
        let view = textView(source)
        let coordinator = makeCoordinator(.swift)
        coordinator.highlight(view, syntax: .swift, fontSize: 12)
        let first = color(of: view, at: 0)
        for _ in 0..<5 { coordinator.highlight(view, syntax: .swift, fontSize: 12) }

        XCTAssertEqual(color(of: view, at: 0), first)
        let commentStart = (source as NSString).range(of: "// c").location
        XCTAssertEqual(try XCTUnwrap(color(of: view, at: commentStart)),
                       NSColor(SyntaxTokenKind.comment.color))
    }
}
