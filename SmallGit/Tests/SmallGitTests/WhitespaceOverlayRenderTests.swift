import XCTest
import SwiftUI
import AppKit
@testable import SmallGit

/// Renders the compare view's whitespace markers and checks where the ink
/// lands. The markers are painted over the text rather than substituted
/// into it, so nothing but a real render can tell whether they line up
/// with the characters they describe.
@MainActor
final class WhitespaceOverlayRenderTests: XCTestCase {

    private let fontSize: CGFloat = 12
    private let scale: CGFloat = 2

    /// Width of one monospaced cell, in points.
    private var cell: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    private func render(_ view: some View) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.fixedSize())
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    /// Columns (in points) that differ between the two renders — i.e.
    /// where the overlay put ink the plain text didn't have.
    private func inkedColumns(plain: NSBitmapImageRep, marked: NSBitmapImageRep) -> Set<Int> {
        var columns: Set<Int> = []
        for x in 0..<marked.pixelsWide {
            for y in 0..<marked.pixelsHigh {
                let markedPixel = marked.colorAt(x: x, y: y)?.alphaComponent ?? 0
                let plainPixel = x < plain.pixelsWide && y < plain.pixelsHigh
                    ? (plain.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                    : 0
                if abs(markedPixel - plainPixel) > 0.15 {
                    columns.insert(Int(CGFloat(x) / scale))
                }
            }
        }
        return columns
    }

    private func renders(of line: String) throws -> (plain: NSBitmapImageRep, marked: NSBitmapImageRep) {
        let revealed = CompareTextLayout.revealed(line)
        let plain = try render(
            Text(revealed.text).font(.mono(size: fontSize))
        )
        let marked = try render(
            Text(revealed.text)
                .font(.mono(size: fontSize))
                .whitespaceMarkers(revealed, fontSize: fontSize)
        )
        return (plain, marked)
    }

    func testTheDotLandsInsideTheSpaceAndNowhereElse() throws {
        // "a b" — cells: [0] 'a', [1] ' ', [2] 'b'.
        let (plain, marked) = try renders(of: "a b")
        let inked = inkedColumns(plain: plain, marked: marked)
        XCTAssertFalse(inked.isEmpty, "the overlay drew nothing at all")

        let spaceCell = Int(cell)..<Int(cell * 2)
        XCTAssertTrue(inked.contains { spaceCell.contains($0) },
            "no dot inside the space's own cell")

        // The glyph cells must come back byte-identical: a marker drawn
        // over a character is a marker in the wrong place.
        let firstCell = 0..<Int(cell)
        XCTAssertFalse(inked.contains { firstCell.contains($0) },
            "the overlay painted over the 'a'")
    }

    func testTheLineEndMarkerIsDrawnPastTheLastCharacter() throws {
        let (plain, marked) = try renders(of: "ab")
        XCTAssertGreaterThan(marked.pixelsWide, plain.pixelsWide,
            "the canvas has to extend past the text or the pilcrow is clipped")

        let inked = inkedColumns(plain: plain, marked: marked)
        XCTAssertTrue(inked.contains { CGFloat($0) >= cell * 2 - 1 },
            "nothing drawn at the end of the line")
    }

    func testAnEmptyLineStillDrawsItsMarker() throws {
        let revealed = CompareTextLayout.revealed("")
        let marked = try render(
            Text(revealed.text)
                .font(.mono(size: fontSize))
                .whitespaceMarkers(revealed, fontSize: fontSize)
        )
        var ink = 0
        for x in 0..<marked.pixelsWide {
            for y in 0..<marked.pixelsHigh where (marked.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
                ink += 1
            }
        }
        XCTAssertGreaterThan(ink, 0,
            "an empty line is invisible without its pilcrow, which is the point of the mode")
    }

    /// The dot is positioned from CoreText's own layout, so a line with
    /// characters wider than one cell keeps its markers under the right
    /// spaces — the case a column-times-advance calculation gets wrong.
    func testMarkersFollowTheTextThroughWideCharacters() throws {
        let line = "漢字 x"
        let revealed = CompareTextLayout.revealed(line)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let ctLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: revealed.text, attributes: [.font: font])
        )
        let spaceMark = try XCTUnwrap(revealed.marks.first { $0.kind == .space })
        let x = CTLineGetOffsetForStringIndex(ctLine, spaceMark.utf16Offset, nil)
        XCTAssertGreaterThan(x, cell * 2,
            "two wide glyphs precede the space; a naive 1-cell-per-character sum would land short")
    }
}
