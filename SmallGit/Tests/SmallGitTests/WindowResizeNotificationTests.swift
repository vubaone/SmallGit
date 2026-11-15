import XCTest
import AppKit
@testable import SmallGit

/// Pins down the AppKit notification behaviour `MainWindowStateHandler` relies
/// on to tell a user resize apart from SwiftUI's own window placement.
///
/// This exists because getting it wrong is invisible in code review and shows
/// up only as an intermittent "I made the window bigger and it snapped back":
/// the handler used to assume a resize would surface as a `didMove` it could
/// catch the mouse button down on. It does not — see below — so every resize
/// looked like SwiftUI's placement and was reverted.
@MainActor
final class WindowResizeNotificationTests: XCTestCase {

    /// Windows made by `makeWindow`, closed together in `tearDown` so a test
    /// run doesn't leave a pile of them on the tester's screen.
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Closing a window that still defaults to releasing itself would
        // over-release it under ARC, and the crash would surface in some later,
        // unrelated test. See the note in ComparePaneScrollSyncTests.
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        drain()
        windows.append(window)
        return window
    }

    /// Notifications are posted synchronously by `setFrame`, but the window has
    /// to have been through a runloop turn after being ordered in before AppKit
    /// posts them at all.
    private func drain() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    /// Records which of the two frame notifications fire for `change`.
    private func notifications(
        for window: NSWindow,
        change: () -> Void
    ) -> Set<String> {
        var seen: Set<String> = []
        let center = NotificationCenter.default
        let tokens = [
            center.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: nil
            ) { _ in seen.insert("didMove") },
            center.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: nil
            ) { _ in seen.insert("didResize") }
        ]
        defer { tokens.forEach(center.removeObserver) }

        change()
        drain()
        return seen
    }

    // MARK: - The behaviour the old code assumed

    /// The crux. Dragging the *left* or *bottom* edge moves the frame's origin
    /// (AppKit frames are bottom-left based), so it looks like it ought to post
    /// `didMove` mid-drag — which is what the handler was counting on to see
    /// the mouse button held down.
    ///
    /// It doesn't. AppKit collapses any `setFrame` that changes the size into
    /// `didResize` alone, however far the origin travels.
    func testResizeThatAlsoMovesTheOriginPostsNoDidMove() {
        let window = makeWindow()
        let origin = window.frame.origin

        let fired = notifications(for: window) {
            window.setFrame(
                CGRect(x: origin.x - 100, y: origin.y - 100, width: 1000, height: 800),
                display: true
            )
        }

        XCTAssertTrue(fired.contains("didResize"))
        XCTAssertFalse(
            fired.contains("didMove"),
            """
            A resize must not be assumed to surface as didMove. If AppKit ever \
            starts posting it, MainWindowStateHandler's mouse-button check would \
            cover resizes on its own — but until then willStartLiveResize is the \
            only signal that a resize is user-driven.
            """
        )
    }

    /// The right/top-edge case, where the origin genuinely is pinned. Same
    /// outcome, for the more obvious reason.
    func testResizeWithPinnedOriginPostsNoDidMove() {
        let window = makeWindow()
        let origin = window.frame.origin

        let fired = notifications(for: window) {
            window.setFrame(
                CGRect(origin: origin, size: CGSize(width: 900, height: 700)),
                display: true
            )
        }

        XCTAssertEqual(fired, ["didResize"])
    }

    /// The control: a pure move — dragging the titlebar — *does* post didMove.
    /// This is why the mouse-button check works for moves and only for moves.
    func testPureMovePostsDidMove() {
        let window = makeWindow()
        let origin = window.frame.origin

        let fired = notifications(for: window) {
            window.setFrameOrigin(CGPoint(x: origin.x + 60, y: origin.y + 60))
        }

        XCTAssertEqual(fired, ["didMove"])
    }

    // MARK: - The signal the handler now uses

    /// `willStartLiveResize` fires before the frame changes, so the handler can
    /// stand down *before* it has anything to misread. Guarding the restored
    /// frame after the fact is what produced the snap-back.
    func testLiveResizeNotificationsBracketTheFrameChange() {
        let window = makeWindow()
        var order: [String] = []
        let center = NotificationCenter.default
        let tokens = [
            center.addObserver(
                forName: NSWindow.willStartLiveResizeNotification, object: window, queue: nil
            ) { _ in order.append("willStart") },
            center.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: nil
            ) { _ in order.append("didResize") },
            center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: nil
            ) { _ in order.append("didEnd") }
        ]
        defer { tokens.forEach(center.removeObserver) }

        // Stands in for the user's drag: AppKit posts these around a real
        // edge-drag, and they can't be synthesised without one.
        center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        window.setFrame(
            CGRect(origin: window.frame.origin, size: CGSize(width: 1100, height: 850)),
            display: true
        )
        center.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        drain()

        XCTAssertEqual(order.first, "willStart", "the takeover signal must land before any frame change")
        XCTAssertEqual(order.last, "didEnd")
        XCTAssertTrue(order.contains("didResize"))
    }
}
