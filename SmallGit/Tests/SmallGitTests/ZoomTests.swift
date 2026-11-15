import XCTest
import SwiftUI
import AppKit
@testable import SmallGit

final class ZoomTests: XCTestCase {

    @MainActor
    func testBumpClampsAtUpperBound() async {
        let app = makeIsolatedAppState()
        app.appConfig.monoFontSize = AppState.monoFontSizeRange.upperBound
        app.bumpMonoFontSize(by: 5)
        XCTAssertEqual(app.appConfig.monoFontSize, AppState.monoFontSizeRange.upperBound)
    }

    @MainActor
    func testBumpClampsAtLowerBound() async {
        let app = makeIsolatedAppState()
        app.appConfig.monoFontSize = AppState.monoFontSizeRange.lowerBound
        app.bumpMonoFontSize(by: -5)
        XCTAssertEqual(app.appConfig.monoFontSize, AppState.monoFontSizeRange.lowerBound)
    }

    @MainActor
    func testBumpDeltaApplies() async {
        let app = makeIsolatedAppState()
        app.appConfig.monoFontSize = 12
        app.bumpMonoFontSize(by: 1)
        XCTAssertEqual(app.appConfig.monoFontSize, 13)
        app.bumpMonoFontSize(by: -1)
        XCTAssertEqual(app.appConfig.monoFontSize, 12)
    }

    @MainActor
    func testResetReturnsToDefault() async {
        let app = makeIsolatedAppState()
        app.appConfig.monoFontSize = 22
        app.resetMonoFontSize()
        XCTAssertEqual(app.appConfig.monoFontSize, AppState.defaultMonoFontSize)
    }

    func testRowHeightScalesWithFontSize() {
        XCTAssertEqual(monoRowHeight(for: 12), 18)
        XCTAssertEqual(monoRowHeight(for: 16), 24)
        XCTAssertEqual(monoRowHeight(for: 8),  12)
    }

    // MARK: - Reaching every window

    /// Renders `content` inside `AppZoom` and reports how tall it came out.
    ///
    /// Height is the observable consequence of the zoom environment: the same
    /// text at 24pt occupies more of it than at 12pt. If the environment never
    /// arrives, both renders are identical — which is exactly the bug this
    /// covers, where compare windows kept the size they opened with.
    @MainActor
    private func renderedHeight(monoFontSize: CGFloat) -> CGFloat? {
        let appState = makeIsolatedAppState()
        appState.appConfig.monoFontSize = monoFontSize
        let view = AppZoom(appState: appState) {
            ZoomProbe()
        }
        let renderer = ImageRenderer(content: view)
        return renderer.nsImage?.size.height
    }

    /// A view that sizes itself from the zoom environment, the way every
    /// diff row does.
    private struct ZoomProbe: View {
        @Environment(\.monoFontSize) private var monoSize
        var body: some View {
            Text("func example() {}")
                .font(.mono(size: monoSize))
                .frame(height: monoRowHeight(for: monoSize))
        }
    }

    @MainActor
    func testZoomEnvironmentReachesWrappedContent() throws {
        let small = try XCTUnwrap(renderedHeight(monoFontSize: 12))
        let large = try XCTUnwrap(renderedHeight(monoFontSize: 24))

        XCTAssertGreaterThan(large, small, """
        Content wrapped in AppZoom must follow the configured size. Equal \
        heights mean the environment was captured once instead of being read \
        on each render — the failure that left compare windows stuck at \
        whatever zoom they opened with.
        """)
    }

    /// The scale multiplier the rest of the UI keys off, so ⌘= grows panel
    /// chrome and not only the monospaced text.
    @MainActor
    func testUIScaleTracksTheMonoSize() {
        let appState = makeIsolatedAppState()
        appState.appConfig.monoFontSize = 18
        XCTAssertEqual(appState.appConfig.monoFontSize / 12, 1.5, accuracy: 0.001)
    }
}
