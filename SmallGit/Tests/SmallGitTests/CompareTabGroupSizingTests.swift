import XCTest
import AppKit
@testable import SmallGit

/// Covers the rule that lets a compare window tell its tab group's size apart
/// from one SwiftUI invented.
///
/// The failure this guards against is only visible with several files open at
/// once: drag tab one bigger, switch to tab two, and the window snaps back to
/// the size it opened at — because tab two never saw a live resize of its own
/// and read the group's frame as SwiftUI auto-fit.
final class CompareTabGroupSizingTests: XCTestCase {

    private let groupSize = CGSize(width: 1500, height: 950)

    func testTheSizeASiblingTabIsAtIsTheGroupSize() {
        XCTAssertTrue(
            CompareTabGroupSizing.isGroupSize(groupSize, siblings: [groupSize])
        )
    }

    /// Only one sibling has to agree: the tab the user actually dragged is
    /// resized first, and the others follow one at a time as they are selected.
    func testOneMatchingSiblingIsEnough() {
        XCTAssertTrue(
            CompareTabGroupSizing.isGroupSize(
                groupSize,
                siblings: [CGSize(width: 900, height: 600), groupSize]
            )
        )
    }

    /// Sub-point differences come out of `contentRect(forFrameRect:)` rounding
    /// on a scaled display, not out of a different size being asked for.
    func testASubPointDifferenceStillCountsAsTheGroupSize() {
        XCTAssertTrue(
            CompareTabGroupSizing.isGroupSize(
                CGSize(width: 1500.4, height: 949.6),
                siblings: [groupSize]
            )
        )
    }

    /// The auto-fit defence has to survive: SwiftUI shrinking the window to
    /// its content produces a height no other tab is at, and that one is still
    /// undone.
    func testAutoFitHeightIsNotTheGroupSize() {
        XCTAssertFalse(
            CompareTabGroupSizing.isGroupSize(
                CGSize(width: 1500, height: 412),
                siblings: [groupSize]
            )
        )
    }

    /// A compare opened on its own has no siblings, so every stray resize
    /// stays a stray resize.
    func testAWindowWithNoTabsNeverAdoptsASize() {
        XCTAssertFalse(CompareTabGroupSizing.isGroupSize(groupSize, siblings: []))
    }
}

/// Pins the AppKit behaviour the rule above is written against: a tab group
/// keeps one frame, and hands it to a sibling only when that sibling is
/// selected — as an ordinary resize, with no live resize around it.
///
/// If a macOS release ever changed this to resize every tab up front, the
/// sibling lookup would still be right, so this test is here to say which
/// behaviour was measured rather than assumed.
@MainActor
final class CompareTabGroupFrameTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Closing a window that still defaults to releasing itself would
        // over-release it under ARC. Same reason as in
        // WindowResizeNotificationTests.
        window.isReleasedWhenClosed = false
        // What the presenter does: automatic tabbing stays off so compares
        // never join the main window, and the group is made explicitly.
        window.tabbingMode = .disallowed
        window.makeKeyAndOrderFront(nil)
        drain()
        windows.append(window)
        return window
    }

    private func drain() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    func testSelectingATabAppliesTheGroupFrameToIt() throws {
        let first = makeWindow()
        let second = makeWindow()
        first.addTabbedWindow(second, ordered: .above)
        first.tabGroup?.selectedWindow = first
        drain()
        try XCTSkipIf(first.tabGroup == nil, "No tab group — headless run.")

        let resized = NSRect(x: 60, y: 60, width: 1500, height: 950)
        first.setFrame(resized, display: true)
        drain()

        // The unselected tab is left where it was...
        XCTAssertEqual(second.frame.width, 900, accuracy: 1)

        var sawResize = false
        var sawLiveResize = false
        let center = NotificationCenter.default
        let tokens = [
            center.addObserver(
                forName: NSWindow.didResizeNotification, object: second, queue: nil
            ) { _ in sawResize = true },
            center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: second, queue: nil
            ) { _ in sawLiveResize = true }
        ]
        defer { tokens.forEach { center.removeObserver($0) } }

        first.tabGroup?.selectedWindow = second
        drain()

        // ...and picks the group's frame up when it is selected.
        XCTAssertEqual(second.frame.width, resized.width, accuracy: 1)
        XCTAssertEqual(second.frame.height, resized.height, accuracy: 1)
        XCTAssertTrue(sawResize, "The selected tab is resized into the group frame.")
        XCTAssertFalse(sawLiveResize, "Nothing about that resize is a user drag.")
    }
}
