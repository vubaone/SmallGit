import XCTest
import SwiftUI
import AppKit
@testable import SmallGit

/// Settings › Colors: what the user picks has to survive the round trip to the
/// config file, apply to the theme they picked it in, and leave the other one
/// alone — a colour chosen for a dark editor is a highlighter pen on white.
@MainActor
final class DiffColorSettingsTests: XCTestCase {

    override func tearDown() async throws {
        // The palette is process-wide; a test must not leave it recoloured.
        DiffPalette.shared.apply(DiffColorOverrides())
    }

    private func hex(_ color: Color, dark: Bool) -> String? {
        NSColor(color).resolved(in: .theme(dark: dark)).hexStringRGBA
    }

    func testHexRoundTripKeepsTheAlphaAWashDependsOn() {
        let wash = NSColor(hex: 0xF26673, alpha: 0.42)
        let text = try? XCTUnwrap(wash.hexStringRGBA)
        XCTAssertEqual(text, "#F266736B")

        let back = try? XCTUnwrap(NSColor(hexString: "#F266736B"))
        XCTAssertEqual(back?.hexStringRGBA, "#F266736B")
    }

    func testHexWithoutAlphaIsOpaqueAndJunkIsRefused() {
        XCTAssertEqual(NSColor(hexString: "1E3A1E")?.hexStringRGBA, "#1E3A1EFF")
        XCTAssertEqual(NSColor(hexString: "#1E3A1E")?.hexStringRGBA, "#1E3A1EFF")
        // A hand-edited config must not be able to make a colour undrawable.
        XCTAssertNil(NSColor(hexString: "not a colour"))
        XCTAssertNil(NSColor(hexString: "#FFF"))
    }

    func testAnOverrideAppliesToItsOwnThemeAndLeavesTheOtherAlone() {
        let defaultLight = hex(Color(nsColor: DiffColorRole.addedLine.defaultColor), dark: false)

        var stored = DiffColorOverrides()
        stored.set("#112233FF", for: DiffColorRole.addedLine.rawValue, dark: true)
        DiffPalette.shared.apply(stored)

        XCTAssertEqual(hex(DiffPalette.shared.color(.addedLine), dark: true), "#112233FF")
        XCTAssertEqual(
            hex(DiffPalette.shared.color(.addedLine), dark: false), defaultLight,
            "the theme that was not customised keeps its own colour"
        )
    }

    func testAnUntouchedRoleStillComesFromTheTheme() {
        var stored = DiffColorOverrides()
        stored.set("#112233FF", for: DiffColorRole.addedLine.rawValue, dark: true)
        DiffPalette.shared.apply(stored)

        XCTAssertEqual(
            hex(DiffPalette.shared.color(.conflict), dark: true),
            hex(Color(nsColor: DiffColorRole.conflict.defaultColor), dark: true)
        )
    }

    func testSettingAColourPersistsItAndResetPutsEveryThemeBack() async {
        let app = makeIsolatedAppState()
        XCTAssertTrue(app.appConfig.diffColors.isEmpty)

        app.setDiffColor(.removedLine, hex: "#AABBCCDD", dark: true)
        app.setDiffColor(.conflict, hex: "#00FF00FF", dark: false)
        XCTAssertEqual(app.appConfig.diffColors.dark["removedLine"], "#AABBCCDD")
        XCTAssertEqual(app.appConfig.diffColors.light["conflict"], "#00FF00FF")
        XCTAssertEqual(hex(DiffPalette.shared.color(.removedLine), dark: true), "#AABBCCDD")

        // One row's revert arrow: that role only, that theme only.
        app.setDiffColor(.removedLine, hex: nil, dark: true)
        XCTAssertNil(app.appConfig.diffColors.dark["removedLine"])
        XCTAssertEqual(app.appConfig.diffColors.light["conflict"], "#00FF00FF")

        app.resetDiffColors()
        XCTAssertTrue(app.appConfig.diffColors.isEmpty)
        XCTAssertEqual(
            hex(DiffPalette.shared.color(.conflict), dark: false),
            hex(Color(nsColor: DiffColorRole.conflict.defaultColor), dark: false)
        )
    }

    func testAConfigWrittenBeforeThisExistedStillLoads() throws {
        let json = #"{"fontSize":13,"monoFontSize":12,"diffMode":"sideBySide"}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.diffColors.isEmpty, "no overrides is the same as never having had any")
    }

    func testPickedColoursSurviveEncodingToTheConfigFile() throws {
        var config = AppConfig()
        config.diffColors.set("#AABBCCDD", for: DiffColorRole.conflictFocused.rawValue, dark: true)

        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(back.diffColors.dark["conflictFocused"], "#AABBCCDD")
        XCTAssertTrue(back.diffColors.light.isEmpty)
    }
}
