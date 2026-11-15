import XCTest
@testable import SmallGit

final class AppConfigTests: XCTestCase {

    func testTolerantDecodeOfOlderJSON() throws {
        // Snapshot of the previous schema (no externalEditor, no lastOpenedRepoID).
        let json = """
        {
          "fontSize": 13,
          "monoFontSize": 12,
          "diffMode": "sideBySide",
          "ignoreWhitespace": false,
          "syncedFromSmartGit": true,
          "smartGitConfigPath": "/some/path"
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(cfg.externalEditor, .system)
        XCTAssertNil(cfg.lastOpenedRepoID)
        XCTAssertTrue(cfg.syncedFromSmartGit)
        XCTAssertEqual(cfg.smartGitConfigPath, "/some/path")
    }

    func testRoundTrip() throws {
        let id = UUID()
        let original = AppConfig(
            fontSize: 14,
            monoFontSize: 13,
            diffMode: .unified,
            ignoreWhitespace: true,
            gitPath: "/opt/homebrew/bin/git",
            syncedFromSmartGit: true,
            smartGitConfigPath: "/Users/me/Library/Preferences/SmartGit/25.1",
            externalEditor: .cursor,
            lastOpenedRepoID: id
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        let data = try enc.encode(original)
        let decoded = try dec.decode(AppConfig.self, from: data)

        XCTAssertEqual(decoded.fontSize, 14)
        XCTAssertEqual(decoded.diffMode, .unified)
        XCTAssertEqual(decoded.gitPath, "/opt/homebrew/bin/git")
        XCTAssertEqual(decoded.externalEditor, .cursor)
        XCTAssertEqual(decoded.lastOpenedRepoID, id)
    }

    func testLegacyCompactDiffModeMigratesToUnifiedPlusCompactFlag() throws {
        // "compact" used to be a third DiffMode case; it's now the
        // orthogonal `diffCompactMode` flag. An old config carrying it
        // must decode without throwing and land on unified + compact-on.
        let json = """
        {
          "fontSize": 13,
          "monoFontSize": 12,
          "diffMode": "compact",
          "ignoreWhitespace": false
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(cfg.diffMode, .unified)
        XCTAssertTrue(cfg.diffCompactMode)
    }

    func testDiffCompactModeDefaultsOnWhenAbsent() throws {
        // Compact (short diff with context) is the default, so a config
        // predating the field should come back with it on — not suddenly
        // showing whole files.
        let json = """
        { "diffMode": "sideBySide" }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(cfg.diffMode, .sideBySide)
        XCTAssertTrue(cfg.diffCompactMode)
    }

    func testDiffCompactModeRoundTripsExplicitOff() throws {
        let json = """
        { "diffMode": "unified", "diffCompactMode": false }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertFalse(cfg.diffCompactMode)
    }

    func testExternalEditorBundleIDs() {
        XCTAssertEqual(ExternalEditor.system.bundleIDs, [])
        XCTAssertTrue(ExternalEditor.cursor.bundleIDs.contains("com.todesktop.230313mzl4w4u92"))
        XCTAssertTrue(ExternalEditor.vscode.bundleIDs.contains("com.microsoft.VSCode"))
        XCTAssertTrue(ExternalEditor.xcode.bundleIDs.contains("com.apple.dt.Xcode"))
        XCTAssertTrue(ExternalEditor.zed.bundleIDs.contains("dev.zed.Zed"))
    }

    /// System Default on a folder tries real editors: macOS's own default
    /// for a folder is Finder, which is not an editor.
    func testSystemEditorSendsFoldersToAnEditor() {
        XCTAssertEqual(ExternalEditor.system.candidateBundleIDs(isDirectory: false), [])
        XCTAssertTrue(ExternalEditor.system.candidateBundleIDs(isDirectory: true).contains("dev.zed.Zed"))
        XCTAssertEqual(ExternalEditor.vscode.candidateBundleIDs(isDirectory: true),
                       ExternalEditor.vscode.bundleIDs)
    }
    func testWhitespaceDefaultsOffAndRoundTrips() {
        // Off for anyone upgrading: turning every space in every diff into a
        // dot is not a change to make on someone's behalf.
        var cfg = AppConfig()
        XCTAssertFalse(cfg.showWhitespace)

        cfg.showWhitespace = true
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        let restored = try? dec.decode(AppConfig.self, from: enc.encode(cfg))
        XCTAssertEqual(restored?.showWhitespace, true)
    }

    func testSingleClickOpensRepoDefaultsOnForExistingConfigs() throws {
        // A config written before the setting existed keeps the behaviour it
        // was written under: one click opens the repository. Defaulting the
        // other way would quietly make every existing install need a second
        // click for something that used to take one.
        let json = """
        { "diffMode": "sideBySide", "toolbarShowsLabels": true }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertTrue(cfg.singleClickOpensRepo)
        XCTAssertTrue(AppConfig().singleClickOpensRepo)
    }

    func testSingleClickOpensRepoRoundTripsExplicitOff() throws {
        // Off is the SmartGit reading — a click selects, a double-click
        // opens — and it has to survive a relaunch or the choice means
        // nothing the next morning.
        var cfg = AppConfig()
        cfg.singleClickOpensRepo = false
        let restored = try JSONDecoder().decode(
            AppConfig.self, from: JSONEncoder().encode(cfg)
        )
        XCTAssertFalse(restored.singleClickOpensRepo)
    }

    func testPerformanceBadgeIsOffUntilAskedFor() throws {
        // A debugging read-out that arrives switched on is a debugging
        // read-out nobody asked for — and it samples the kernel every second.
        XCTAssertFalse(AppConfig().perfBadgeEnabled)

        let json = """
        { "diffMode": "sideBySide" }
        """.data(using: .utf8)!
        XCTAssertFalse(try JSONDecoder().decode(AppConfig.self, from: json).perfBadgeEnabled)

        var cfg = AppConfig()
        cfg.perfBadgeEnabled = true
        let restored = try JSONDecoder().decode(
            AppConfig.self, from: JSONEncoder().encode(cfg)
        )
        XCTAssertTrue(restored.perfBadgeEnabled, "and it stays on across a relaunch")
    }

}
