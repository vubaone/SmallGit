import XCTest
@testable import SmallGit

/// Covers the one thing every Escape interceptor agrees on.
///
/// Escape is taken in three places before it can reach a view — the main
/// window's app-wide key monitor, and each secondary window's own monitor and
/// `sendEvent` — and the order local monitors run in is not defined. So none
/// of them can be the one that decides whether a press belongs to the view:
/// they all ask `AppState` first, and this is that contract. Get it wrong and
/// Escape closes the compare window out from under a block being typed in,
/// which is exactly the bug it was added for.
@MainActor
final class EscapeClaimTests: XCTestCase {

    private func windowID(_ object: AnyObject) -> ObjectIdentifier {
        ObjectIdentifier(object)
    }

    /// Stand-ins for windows: the registry only ever uses their identity.
    private final class FakeWindow {}

    func testAClaimThatHandlesThePressStopsEverythingElse() {
        let state = makeIsolatedAppState()
        let window = FakeWindow()
        state.claimEscape(for: windowID(window)) { true }

        XCTAssertTrue(state.consumeEscape(in: windowID(window)))
    }

    /// A view with nothing left to unwind declines, and the window closes as
    /// it always did — the second press of "leave the editor, then close".
    func testAClaimThatDeclinesLetsThePressThrough() {
        let state = makeIsolatedAppState()
        let window = FakeWindow()
        state.claimEscape(for: windowID(window)) { false }

        XCTAssertFalse(state.consumeEscape(in: windowID(window)))
    }

    /// The claim is per window: a compare in the background must not answer
    /// for the one in front, or Escape would close a block open elsewhere.
    func testAnotherWindowsClaimIsNotConsulted() {
        let state = makeIsolatedAppState()
        let editing = FakeWindow()
        let frontmost = FakeWindow()
        state.claimEscape(for: windowID(editing)) { true }

        XCTAssertFalse(state.consumeEscape(in: windowID(frontmost)))
    }

    func testNoClaimAtAllDeclines() {
        let state = makeIsolatedAppState()
        XCTAssertFalse(state.consumeEscape(in: windowID(FakeWindow())))
        XCTAssertFalse(state.consumeEscape(in: nil))
    }

    /// The view re-registers on every render, so the newest closure — the one
    /// that can see the current state — has to be the one that answers.
    func testReClaimingReplacesThePreviousClosure() {
        let state = makeIsolatedAppState()
        let window = FakeWindow()
        var whichRan = ""
        state.claimEscape(for: windowID(window)) { whichRan = "stale"; return true }
        state.claimEscape(for: windowID(window)) { whichRan = "current"; return true }

        XCTAssertTrue(state.consumeEscape(in: windowID(window)))
        XCTAssertEqual(whichRan, "current")
    }

    /// Withdrawn when the window goes away: a claim left behind would answer
    /// for whatever window AppKit puts at that address next.
    func testAReleasedClaimIsGone() {
        let state = makeIsolatedAppState()
        let window = FakeWindow()
        state.claimEscape(for: windowID(window)) { true }
        state.releaseEscapeClaim(for: windowID(window))

        XCTAssertFalse(state.consumeEscape(in: windowID(window)))
    }
}
