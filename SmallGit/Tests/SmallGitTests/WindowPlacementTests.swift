import XCTest
@testable import SmallGit

/// Placement is pure value-in/value-out, so every multi-display case that is
/// awkward to reproduce by hand — monitor unplugged, displays rearranged, a
/// frame saved on a 6K panel reopening on a laptop — is covered here.
///
/// Coordinates are AppKit's: origin at the primary display's bottom-left,
/// y growing upwards. A display to the *left* of the primary therefore has a
/// negative origin.x.
final class WindowPlacementTests: XCTestCase {

    // A 1920x1080 primary with a 22pt menu bar, and a 2560x1440 secondary
    // sitting to its left.
    private let primary = ScreenInfo(
        displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1058)
    )
    private let secondary = ScreenInfo(
        displayID: 2,
        frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1418)
    )

    private var bothScreens: [ScreenInfo] { [primary, secondary] }

    // MARK: - Nothing to restore

    func testNoSavedStateLeavesPlacementToSwiftUI() {
        XCTAssertNil(WindowPlacement.resolve(saved: nil, screens: bothScreens))
    }

    func testNoScreensReportedYieldsNoFrame() {
        let saved = WindowFrameState(frame: CGRect(x: 10, y: 10, width: 1200, height: 800))
        XCTAssertNil(WindowPlacement.resolve(saved: saved, screens: []))
    }

    func testDegenerateSavedFrameIsIgnored() {
        let saved = WindowFrameState(frame: CGRect(x: 0, y: 0, width: 0, height: 0))
        XCTAssertNil(WindowPlacement.resolve(saved: saved, screens: bothScreens))
    }

    // MARK: - Same setup as last time

    func testRestoresExactFrameWhenNothingChanged() {
        let frame = CGRect(x: 120, y: 90, width: 1400, height: 900)
        let saved = WindowFrameState(frame: frame, displayID: 1, screenFrame: primary.frame)
        XCTAssertEqual(WindowPlacement.resolve(saved: saved, screens: bothScreens), frame)
    }

    /// The point of storing the display: a window on the secondary monitor has
    /// to come back on the secondary monitor, not on the primary.
    func testRestoresOntoSecondaryDisplay() {
        let frame = CGRect(x: -2000, y: 200, width: 1600, height: 1000)
        let saved = WindowFrameState(frame: frame, displayID: 2, screenFrame: secondary.frame)
        let resolved = WindowPlacement.resolve(saved: saved, screens: bothScreens)
        XCTAssertEqual(resolved, frame)
        XCTAssertTrue(
            secondary.visibleFrame.contains(resolved ?? .zero),
            "restored frame must land inside the secondary display"
        )
    }

    // MARK: - Display IDs are not stable

    /// Display IDs change across reboots and re-plugging. Identical geometry
    /// identifies the same physical panel.
    func testFallsBackToScreenGeometryWhenDisplayIDChanged() {
        let frame = CGRect(x: -2000, y: 200, width: 1600, height: 1000)
        let saved = WindowFrameState(frame: frame, displayID: 99, screenFrame: secondary.frame)
        XCTAssertEqual(WindowPlacement.resolve(saved: saved, screens: bothScreens), frame)
    }

    /// Neither ID nor geometry matches (displays rearranged in System
    /// Settings), so fall back to whichever screen the frame overlaps most.
    func testFallsBackToLargestOverlapWhenIDAndGeometryBothChanged() {
        let frame = CGRect(x: -1200, y: 200, width: 800, height: 600)
        let saved = WindowFrameState(
            frame: frame,
            displayID: 99,
            screenFrame: CGRect(x: -3000, y: 0, width: 3000, height: 2000)
        )
        let resolved = WindowPlacement.resolve(saved: saved, screens: bothScreens)
        XCTAssertNotNil(resolved)
        XCTAssertTrue(
            secondary.visibleFrame.intersects(resolved ?? .zero),
            "frame overlapping only the secondary display should stay there"
        )
    }

    func testOverlapPicksTheScreenHoldingMostOfTheWindow() {
        // Straddles the boundary at x=0, with the larger share on the primary.
        let frame = CGRect(x: -200, y: 100, width: 1000, height: 700)
        let saved = WindowFrameState(frame: frame, displayID: nil, screenFrame: nil)
        let matched = WindowPlacement.matchedScreen(
            for: saved,
            in: bothScreens
        )
        XCTAssertEqual(matched?.displayID, primary.displayID)
    }

    // MARK: - Display gone

    /// Undocking must not restore a window to coordinates that no longer
    /// exist — it would be invisible and unreachable. Keep the size, centre
    /// it on the primary.
    func testUnpluggedDisplayCentersOnPrimaryKeepingSize() {
        let saved = WindowFrameState(
            frame: CGRect(x: -2000, y: 200, width: 1400, height: 900),
            displayID: 2,
            screenFrame: secondary.frame
        )
        let resolved = WindowPlacement.resolve(saved: saved, screens: [primary])
        let frame = try? XCTUnwrap(resolved)
        XCTAssertEqual(frame?.size, CGSize(width: 1400, height: 900))
        XCTAssertEqual(frame?.midX, primary.visibleFrame.midX)
        XCTAssertEqual(frame?.midY, primary.visibleFrame.midY)
        XCTAssertTrue(primary.visibleFrame.contains(frame ?? .zero))
    }

    // MARK: - Clamping

    /// A window sized on the 2560x1440 monitor must shrink to fit when it
    /// reopens on the 1920x1080 one.
    func testFrameLargerThanTargetScreenShrinksToFit() {
        let saved = WindowFrameState(
            frame: CGRect(x: 0, y: 0, width: 2400, height: 1400),
            displayID: 1,
            screenFrame: primary.frame
        )
        let resolved = WindowPlacement.resolve(saved: saved, screens: [primary])
        XCTAssertEqual(resolved?.width, primary.visibleFrame.width)
        XCTAssertEqual(resolved?.height, primary.visibleFrame.height)
        XCTAssertTrue(primary.visibleFrame.contains(resolved ?? .zero))
    }

    func testFrameHangingOffTheRightEdgeSlidesBackIn() {
        let saved = WindowFrameState(
            frame: CGRect(x: 1800, y: 100, width: 1200, height: 800),
            displayID: 1,
            screenFrame: primary.frame
        )
        let resolved = try? XCTUnwrap(WindowPlacement.resolve(saved: saved, screens: [primary]))
        XCTAssertEqual(resolved?.size, CGSize(width: 1200, height: 800), "size is preserved")
        XCTAssertEqual(resolved?.maxX, primary.visibleFrame.maxX, "slid flush to the right edge")
        XCTAssertTrue(primary.visibleFrame.contains(resolved ?? .zero))
    }

    func testFrameBelowTheVisibleAreaSlidesUp() {
        // visibleFrame starts at y=0; a Dock-reserved strip would push it up.
        let docked = ScreenInfo(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 70, width: 1920, height: 988)
        )
        let saved = WindowFrameState(
            frame: CGRect(x: 100, y: 0, width: 1200, height: 800),
            displayID: 1,
            screenFrame: docked.frame
        )
        let resolved = WindowPlacement.resolve(saved: saved, screens: [docked])
        XCTAssertEqual(resolved?.minY, docked.visibleFrame.minY)
    }

    /// A tiny saved frame is pulled back up to the window's declared minimum
    /// rather than restored unusably small.
    func testTinyFrameIsRaisedToMinimumSize() {
        let saved = WindowFrameState(
            frame: CGRect(x: 100, y: 100, width: 200, height: 150),
            displayID: 1,
            screenFrame: primary.frame
        )
        let resolved = WindowPlacement.resolve(saved: saved, screens: [primary])
        XCTAssertEqual(resolved?.width, WindowPlacement.minSize.width)
        XCTAssertEqual(resolved?.height, WindowPlacement.minSize.height)
    }

    /// ...but not past what the display can show, which would push the window
    /// partly off a small screen.
    func testMinimumSizeNeverExceedsASmallScreen() {
        let small = ScreenInfo(
            displayID: 7,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 578)
        )
        let saved = WindowFrameState(
            frame: CGRect(x: 0, y: 0, width: 200, height: 150),
            displayID: 7,
            screenFrame: small.frame
        )
        let resolved = try? XCTUnwrap(WindowPlacement.resolve(saved: saved, screens: [small]))
        XCTAssertEqual(resolved?.size, small.visibleFrame.size)
        XCTAssertTrue(small.visibleFrame.contains(resolved ?? .zero))
    }

    // MARK: - Restored vs. fallback

    /// The caller needs to tell "put it where it was" apart from "the display
    /// isn't there, here's a stand-in" — the latter stays open for a retry.
    func testPlanReportsRestoredWhenTargetDisplayIsPresent() {
        let saved = WindowFrameState(
            frame: CGRect(x: -2000, y: 200, width: 1600, height: 1000),
            displayID: 2,
            screenFrame: secondary.frame
        )
        XCTAssertEqual(
            WindowPlacement.plan(saved: saved, screens: bothScreens)?.isRestored,
            true
        )
    }

    func testPlanReportsFallbackWhenTargetDisplayIsMissing() {
        let saved = WindowFrameState(
            frame: CGRect(x: -2000, y: 200, width: 1600, height: 1000),
            displayID: 2,
            screenFrame: secondary.frame
        )
        XCTAssertEqual(
            WindowPlacement.plan(saved: saved, screens: [primary])?.isRestored,
            false
        )
    }

    /// An external display that registers a few seconds after launch (waking
    /// from sleep, docking) must still get the window: the same saved state
    /// falls back while it's absent, then restores once it appears.
    func testLateArrivingDisplayLetsARetrySucceed() {
        let frame = CGRect(x: -2000, y: 200, width: 1600, height: 1000)
        let saved = WindowFrameState(frame: frame, displayID: 2, screenFrame: secondary.frame)

        let atLaunch = WindowPlacement.plan(saved: saved, screens: [primary])
        XCTAssertEqual(atLaunch?.isRestored, false)

        let afterDisplayWakes = WindowPlacement.plan(saved: saved, screens: bothScreens)
        XCTAssertEqual(afterDisplayWakes, .restored(frame))
    }

    func testPlanIsNilWithNothingSavedSoTheCallerCanRetryLater() {
        XCTAssertNil(WindowPlacement.plan(saved: nil, screens: bothScreens))
    }

    // MARK: - Round-trip through the config file

    func testWindowFrameStateSurvivesJSONRoundTrip() throws {
        let original = WindowFrameState(
            frame: CGRect(x: -2000, y: 200, width: 1600, height: 1000),
            displayID: 2,
            screenFrame: secondary.frame
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(WindowFrameState.self, from: data), original)
    }

    /// `ui-state.json` files written before this feature must still load.
    func testUIStateDecodesWithoutAWindowFrame() throws {
        let json = #"{"sidebarWidth":300,"reposPanelRatio":0.5,"topBottomRatio":0.55,"journalOutputRatio":0.6,"compactMode":true}"#
        let state = try JSONDecoder().decode(UIState.self, from: Data(json.utf8))
        XCTAssertNil(state.mainWindowFrame)
        XCTAssertEqual(state.sidebarWidth, 300)
        XCTAssertTrue(state.compactMode)
    }

    /// Same again for the two layout switches added since: an existing
    /// `ui-state.json` predates both keys, and a strict decode would throw
    /// away the whole file — window frame, sidebar width and all — over a
    /// missing boolean.
    func testUIStateDecodesWithoutTheLayoutSwitches() throws {
        let json = #"{"sidebarWidth":300,"compactMode":true}"#
        let state = try JSONDecoder().decode(UIState.self, from: Data(json.utf8))
        XCTAssertFalse(state.showsTerminal, "the diff is what was there before")
        XCTAssertFalse(state.bottomPanelsCollapsed, "and the Journal was open")
        XCTAssertEqual(state.sidebarWidth, 300)
    }

    func testLayoutSwitchesRoundTrip() throws {
        var state = UIState()
        state.showsTerminal = true
        state.bottomPanelsCollapsed = true
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertTrue(decoded.showsTerminal)
        XCTAssertTrue(decoded.bottomPanelsCollapsed)
    }

    func testUIStateRoundTripsWithAWindowFrame() throws {
        var state = UIState()
        state.mainWindowFrame = WindowFrameState(
            frame: CGRect(x: 10, y: 20, width: 1300, height: 850),
            displayID: 1,
            screenFrame: primary.frame
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.mainWindowFrame, state.mainWindowFrame)
    }

    // MARK: - Blocking write

    /// The blocking screen-change write must land in the same file the async
    /// path reads back, or the frame would be saved somewhere nothing loads.
    func testBlockingWriteLandsWhereLoadUIStateReadsFrom() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-uistate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = ConfigService(supportDirectory: dir)

        var state = UIState()
        state.sidebarWidth = 321
        state.mainWindowFrame = WindowFrameState(
            frame: CGRect(x: 100, y: 1100, width: 1000, height: 880),
            displayID: 2,
            screenFrame: secondary.frame
        )
        service.saveUIStateBlocking(state)

        let reloaded = await service.loadUIState()
        XCTAssertEqual(reloaded.mainWindowFrame, state.mainWindowFrame)
        XCTAssertEqual(reloaded.sidebarWidth, 321)
    }

    /// It also has to be synchronous — the whole point is that it completes
    /// before the caller returns, so a kill straight afterwards can't lose it.
    func testBlockingWriteIsVisibleImmediatelyOnReturn() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-uistate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = ConfigService(supportDirectory: dir)

        var state = UIState()
        state.mainWindowFrame = WindowFrameState(frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        service.saveUIStateBlocking(state)

        let url = ConfigService.uiStateURL(supportDirectory: dir)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "the file must exist the moment saveUIStateBlocking returns"
        )
        let decoded = try JSONDecoder().decode(UIState.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.mainWindowFrame, state.mainWindowFrame)
    }

    // MARK: - Close-to-quit config

    func testQuitsOnMainWindowCloseDefaultsOn() {
        XCTAssertTrue(AppConfig().quitsOnMainWindowClose)
    }

    /// config.json files predating the toggle should adopt the new default
    /// rather than silently keeping the old macOS behaviour.
    func testQuitsOnMainWindowCloseDefaultsOnForOlderConfigs() throws {
        let json = #"{"fontSize":13,"monoFontSize":12}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.quitsOnMainWindowClose)
    }

    func testQuitsOnMainWindowCloseRoundTrips() throws {
        var config = AppConfig()
        config.quitsOnMainWindowClose = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertFalse(decoded.quitsOnMainWindowClose)
    }
}
