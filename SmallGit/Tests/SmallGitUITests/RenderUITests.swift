import XCTest
import SwiftUI
import AppKit
@testable import SmallGit

@MainActor
final class RenderUITests: XCTestCase {
    /// PNG artifacts are diagnostic snapshots; assertions compare regions
    /// rendered in the same run to avoid OS-dependent font golden files.
    private func render(_ view: some View, name: String) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "Could not render \(name)")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = UIFixture.artifacts.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        return bitmap
    }

    private func color(_ image: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }

    private func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
            abs(a.blueComponent - b.blueComponent), abs(a.alphaComponent - b.alphaComponent))
    }

    func testRenamedFileDotShowsBothDeletedAndAddedColors() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        for scheme in [ColorScheme.light, .dark] {
            func dot(_ status: String, _ swatch: Color, _ name: String) throws -> NSBitmapImageRep {
                try render(FileStatusDot(file: GitFileStatus(path: "file.txt", indexStatus: status,
                                                             workTreeStatus: "."), color: swatch, size: 24)
                    .environment(\.colorScheme, scheme), name: "dot-\(name)-\(scheme)")
            }
            let deleted = try dot("D", GitFileState.deleted.swatch, "deleted")
            let added = try dot("A", GitFileState.added.swatch, "added")
            let renamed = try dot("R", .purple, "renamed")
            XCTAssertEqual(renamed.pixelsWide, 48)
            let left = try color(renamed, x: 12, y: 24)
            let right = try color(renamed, x: 36, y: 24)
            XCTAssertLessThan(difference(left, try color(deleted, x: 12, y: 24)), 0.03)
            XCTAssertLessThan(difference(right, try color(added, x: 36, y: 24)), 0.03)
            XCTAssertGreaterThan(difference(left, right), 0.1)
        }
    }

    func testStatusStripRendersAtCompactAndWideWidths() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        for width in [320, 800] {
            let view = StatusBar(statusText: "Pull completed — a repository with a long descriptive name",
                                 changedFileCount: 12, cursorInfo: "120:8", isWorking: false)
                .frame(width: CGFloat(width), height: 28)
            let image = try render(view, name: "status-\(width)")
            XCTAssertEqual(image.pixelsWide, width * 2)
            XCTAssertEqual(image.pixelsHigh, 56)
            let background = try color(image, x: 0, y: 0)
            var textPixels = 0
            for x in 0..<image.pixelsWide {
                for y in 0..<image.pixelsHigh {
                    if difference(try color(image, x: x, y: y), background) > 0.15 { textPixels += 1 }
                }
            }
            XCTAssertGreaterThan(textPixels, 100, "The status bar rendered no text")
        }
    }

    func testLongDiffTextCannotPaintOverTheOtherColumn() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let width: CGFloat = 260
        func row(_ text: String, _ name: String) throws -> NSBitmapImageRep {
            try render(HStack(spacing: 0) {
                DiffLineView(line: DiffLine(type: .context, content: text, oldLineNumber: 8, newLineNumber: 8),
                             side: .old, syntax: .swift).frame(width: width)
                Divider()
                DiffLineView(line: DiffLine(type: .context, content: "let right = 42", oldLineNumber: 8, newLineNumber: 8),
                             side: .new, syntax: .swift).frame(width: width)
            }
            .frame(width: width * 2 + 1, height: 18)
            .environment(\.monoFontSize, 12)
            .environment(\.colorScheme, .dark)
            .background(Color.bgPanel), name: name)
        }
        let empty = try row("", "diff-empty-left")
        let long = try row(String(repeating: "Nội dung dài ", count: 40), "diff-long-left")
        var leftChanges = 0
        for x in 0..<long.pixelsWide {
            for y in 0..<long.pixelsHigh {
                let delta = difference(try color(empty, x: x, y: y), try color(long, x: x, y: y))
                if x >= Int((width + 1) * 2) {
                    XCTAssertLessThan(delta, 0.01, "Left text leaked into the right column")
                } else if delta > 0.05 { leftChanges += 1 }
            }
        }
        XCTAssertGreaterThan(leftChanges, 0, "The left text must remain visible")
    }

}
