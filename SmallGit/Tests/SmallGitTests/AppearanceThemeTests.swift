import XCTest
import AppKit
@testable import SmallGit

/// The palette is the one place where "it compiles" says nothing about
/// whether it works: a token that resolves to the same colour in both
/// appearances is a perfectly valid `NSColor` and a broken theme.
@MainActor
final class AppearanceThemeTests: XCTestCase {

    // MARK: - Helpers

    private func resolve(_ color: NSColor, dark: Bool) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB)
        }
        return out!
    }

    private func hex(_ color: NSColor, dark: Bool) -> UInt32 {
        let c = resolve(color, dark: dark)
        let r = UInt32((c.redComponent   * 255).rounded())
        let g = UInt32((c.greenComponent * 255).rounded())
        let b = UInt32((c.blueComponent  * 255).rounded())
        return (r << 16) | (g << 8) | b
    }

    // MARK: - Palette

    func testPaletteResolvesPerAppearance() {
        XCTAssertEqual(hex(Palette.bgPanel, dark: false), 0xFFFFFF)
        XCTAssertEqual(hex(Palette.bgPanel, dark: true),  0x252526)
        XCTAssertEqual(hex(Palette.textPrimary, dark: false), 0x1E1E20)
        XCTAssertEqual(hex(Palette.textPrimary, dark: true),  0xCCCCCC)
    }

    func testEveryTokenDiffersBetweenLightAndDark() {
        // A token identical in both appearances is almost always a value
        // that was pasted twice rather than one that was designed twice.
        // The two intentional exceptions are the conflict wash and the
        // search highlights, which keep their hue and change only in
        // alpha or lightness — those still differ, so nothing is exempt.
        let tokens: [(String, NSColor)] = [
            ("bgApp", Palette.bgApp), ("bgPanel", Palette.bgPanel),
            ("bgPanelHeader", Palette.bgPanelHeader), ("bgInput", Palette.bgInput),
            ("bgSelected", Palette.bgSelected), ("bgHover", Palette.bgHover),
            ("borderColor", Palette.borderColor), ("strongBorder", Palette.strongBorder),
            ("textPrimary", Palette.textPrimary), ("textSecondary", Palette.textSecondary),
            ("textDisabled", Palette.textDisabled), ("textGroupHeader", Palette.textGroupHeader),
            ("accentBlue", Palette.accentBlue),
            ("diffAddBg", Palette.diffAddBg), ("diffDelBg", Palette.diffDelBg),
            ("diffAddText", Palette.diffAddText), ("diffDelText", Palette.diffDelText),
            ("diffAddWordBg", Palette.diffAddWordBg), ("diffDelWordBg", Palette.diffDelWordBg),
            ("searchMatchBg", Palette.searchMatchBg), ("searchCurrentBg", Palette.searchCurrentBg),
            ("graphDotRing", Palette.graphDotRing),
            ("synKeyword", Palette.synKeyword), ("synString", Palette.synString),
            ("synComment", Palette.synComment), ("synFunction", Palette.synFunction)
        ]
        for (name, color) in tokens {
            XCTAssertNotEqual(
                resolve(color, dark: false), resolve(color, dark: true),
                "\(name) resolves to the same colour in both appearances"
            )
        }
    }

    func testDiffWashesStayOnTheirSideOfTheirText() {
        // The rule the diff palette is built on: the row wash and the text
        // drawn on it sit at opposite ends of the brightness range, so code
        // stays readable on an added or deleted line in either theme.
        for dark in [false, true] {
            let addBg   = resolve(Palette.diffAddBg,   dark: dark).brightnessComponent
            let addText = resolve(Palette.diffAddText, dark: dark).brightnessComponent
            let delBg   = resolve(Palette.diffDelBg,   dark: dark).brightnessComponent
            let delText = resolve(Palette.diffDelText, dark: dark).brightnessComponent
            if dark {
                XCTAssertGreaterThan(addText, addBg)
                XCTAssertGreaterThan(delText, delBg)
            } else {
                XCTAssertLessThan(addText, addBg)
                XCTAssertLessThan(delText, delBg)
            }
        }
    }

    /// WCAG relative luminance, the standard way to ask "can this be read".
    private func luminance(_ c: NSColor) -> CGFloat {
        func channel(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
             + 0.7152 * channel(c.greenComponent)
             + 0.0722 * channel(c.blueComponent)
    }

    private func contrast(_ fg: NSColor, on bg: NSColor, dark: Bool) -> CGFloat {
        let a = luminance(resolve(fg, dark: dark))
        let b = luminance(resolve(bg, dark: dark))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The pairs that actually get drawn on top of each other, with the
    /// contrast floor each one was designed to clear — in *both* themes.
    ///
    /// This is the test that makes a second theme maintainable. A colour
    /// tweak that reads fine on the dark background it was picked against
    /// can quietly drop light-mode text to unreadable, and nobody notices
    /// until they switch. The floors are below the measured values rather
    /// than at them, so ordinary retouching does not trip the suite; a real
    /// regression moves these by far more than the slack.
    func testTextStaysReadableOnItsBackgroundInBothThemes() {
        let pairs: [(String, NSColor, NSColor, CGFloat)] = [
            ("primary on panel",        Palette.textPrimary,   Palette.bgPanel,         7.0),
            ("primary on header",       Palette.textPrimary,   Palette.bgPanelHeader,   7.0),
            ("secondary on panel",      Palette.textSecondary, Palette.bgPanel,         3.4),
            ("group header on panel",   Palette.textGroupHeader, Palette.bgPanel,       3.4),
            ("white on selection",      .white,                Palette.bgSelected,      4.5),
            ("white on status bar",     .white,                Palette.accentBlue,      4.4),
            ("code on added row",       Palette.textPrimary,   Palette.diffAddBg,       4.5),
            ("code on deleted row",     Palette.textPrimary,   Palette.diffDelBg,       4.5),
            ("code on added word",      Palette.textPrimary,   Palette.diffAddWordBg,   4.5),
            ("code on deleted word",    Palette.textPrimary,   Palette.diffDelWordBg,   4.5),
            ("add text on added row",   Palette.diffAddText,   Palette.diffAddBg,       4.5),
            ("del text on deleted row", Palette.diffDelText,   Palette.diffDelBg,       4.5),
            ("black on current hit",    .black,                Palette.searchCurrentBg, 4.5),
            ("comment on deleted row",  Palette.synComment,    Palette.diffDelBg,       4.5),
            ("string on panel",         Palette.synString,     Palette.bgPanel,         4.5)
        ]
        for (name, fg, bg, floor) in pairs {
            for dark in [false, true] {
                let ratio = contrast(fg, on: bg, dark: dark)
                XCTAssertGreaterThanOrEqual(
                    ratio, floor,
                    "\(name) is \(String(format: "%.2f", Double(ratio))):1 in \(dark ? "dark" : "light")"
                )
            }
        }
    }

    func testAuthorBadgeInitialsStayReadable() {
        // The badge draws white initials and nothing else, so every entry in
        // the palette has to hold up against white — which is what ruled out
        // the stock SwiftUI colours this used to use.
        for (i, fill) in Palette.authorBadge.enumerated() {
            for dark in [false, true] {
                XCTAssertGreaterThanOrEqual(
                    contrast(.white, on: fill, dark: dark), 4.0,
                    "author badge \(i) in \(dark ? "dark" : "light")"
                )
            }
        }
    }

    func testHighContrastAppearancesCountAsDark() {
        // `bestMatch` rather than a name comparison, so the accessibility
        // variants a user can switch on don't fall back to the light theme.
        let increased = NSAppearance(named: .accessibilityHighContrastDarkAqua)!
        XCTAssertTrue(increased.isDark)
        XCTAssertFalse(NSAppearance(named: .accessibilityHighContrastAqua)!.isDark)
    }

    // MARK: - Setting

    func testAppearanceModeMapsToSwiftUIAndAppKit() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertNil(AppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
    }

    func testConfigDefaultsToSystemAndRoundTrips() throws {
        let legacy = """
        { "fontSize": 13, "monoFontSize": 12, "diffMode": "sideBySide" }
        """.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: legacy).appearance, .system)

        var cfg = AppConfig()
        cfg.appearance = .light
        let data = try JSONEncoder().encode(cfg)
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: data).appearance, .light)
    }
}
