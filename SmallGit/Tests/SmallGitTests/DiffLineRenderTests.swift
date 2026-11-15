import XCTest
import SwiftUI
import AppKit
@testable import SmallGit

@MainActor
final class DiffLineRenderTests: XCTestCase {
    private let columnWidth: CGFloat = 260
    private let fontSize: CGFloat = 12
    private let scale: CGFloat = 2
    private let longLine = "    kSPS_ChatGroup_InviteFailed_TapMember = 356; // "
        + String(repeating: "Nội dung dài để kiểm tra hiển thị ", count: 8)

    private func render(left: String, whitespace: Bool, offset: CGFloat) throws -> NSBitmapImageRep {
        let view = HStack(spacing: 0) {
            DiffLineView(
                line: DiffLine(type: .context, content: left, oldLineNumber: 84, newLineNumber: 84),
                side: .old, syntax: .objectiveC
            )
            .frame(width: columnWidth, alignment: .leading)
            Divider()
            DiffLineView(
                line: DiffLine(type: .context, content: "    right_column = 357;", oldLineNumber: 84, newLineNumber: 84),
                side: .new, syntax: .objectiveC
            )
            .frame(width: columnWidth, alignment: .leading)
        }
        .frame(width: columnWidth * 2 + 1, height: monoRowHeight(for: fontSize))
        .environment(\.monoFontSize, fontSize)
        .environment(\.showWhitespace, whitespace)
        .environment(\.diffHorizontalOffset, offset)
        .environment(\.colorScheme, .dark)
        .background(Color.bgPanel)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    private func changedPixels(
        _ first: NSBitmapImageRep, _ second: NSBitmapImageRep, in columns: Range<Int>
    ) -> Int {
        var count = 0
        for x in columns {
            for y in 0..<first.pixelsHigh {
                guard let a = first.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = second.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if max(abs(a.redComponent - b.redComponent),
                       abs(a.greenComponent - b.greenComponent),
                       abs(a.blueComponent - b.blueComponent)) > 0.05 {
                    count += 1
                }
            }
        }
        return count
    }

    func testLongLeftLineCannotPaintOverTheRightColumn() throws {
        for whitespace in [false, true] {
            for offset: CGFloat in [0, 150] {
                let empty = try render(left: "", whitespace: whitespace, offset: offset)
                let long = try render(left: longLine, whitespace: whitespace, offset: offset)
                let rightColumn = Int((columnWidth + 1) * scale)..<long.pixelsWide
                XCTAssertEqual(changedPixels(empty, long, in: rightColumn), 0,
                               "left text leaked into the right column (whitespace: \(whitespace), offset: \(offset))")
                let leftText = Int(DiffLineView.leadingWidth(fontSize: fontSize) * scale)..<Int(columnWidth * scale)
                XCTAssertGreaterThan(changedPixels(empty, long, in: leftText), 0,
                                     "clipping must keep the visible portion of the long line")
            }
        }
    }

    func testScrollingLongTextKeepsLineNumbersFixed() throws {
        let start = try render(left: longLine, whitespace: true, offset: 0)
        let scrolled = try render(left: longLine, whitespace: true, offset: 150)
        let gutter = 0..<Int(DiffLineView.leadingWidth(fontSize: fontSize) * scale)
        XCTAssertEqual(changedPixels(start, scrolled, in: gutter), 0)
        let text = gutter.upperBound..<Int(columnWidth * scale)
        XCTAssertGreaterThan(changedPixels(start, scrolled, in: text), 0,
                             "the line must remain horizontally scrollable")
    }
}
