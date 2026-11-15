import XCTest
@testable import SmallGit

/// The modal window's opening size is the one piece of the presenter that is
/// pure value-in/value-out, and the one that misbehaves on hardware nobody
/// has to hand — a laptop display smaller than the dialog asks for.
final class ModalWindowSizeTests: XCTestCase {

    private let requested = CGSize(width: 900, height: 640)
    private let minimum = CGSize(width: 560, height: 360)

    private func fitted(_ visible: CGSize?) -> CGSize {
        ModalWindowPresenter.fittedSize(requested: requested, minimum: minimum, visible: visible)
    }

    func testRoomyDisplayGetsTheRequestedSize() {
        XCTAssertEqual(fitted(CGSize(width: 1920, height: 1058)), requested)
    }

    func testUnknownDisplayGetsTheRequestedSize() {
        XCTAssertEqual(fitted(nil), requested)
    }

    func testSmallDisplayShrinksToWhatFits() {
        XCTAssertEqual(fitted(CGSize(width: 800, height: 500)), CGSize(width: 800, height: 500))
    }

    func testNeverExceedsTheDisplayEvenBelowTheMinimum() {
        // A display narrower than the dialog's own minimum: the minimum has
        // to yield rather than hang the window off the edge.
        let size = fitted(CGSize(width: 420, height: 300))
        XCTAssertEqual(size, CGSize(width: 420, height: 300))
    }

    func testOneAxisShrinkingLeavesTheOtherAlone() {
        XCTAssertEqual(fitted(CGSize(width: 700, height: 1058)), CGSize(width: 700, height: 640))
    }
}
