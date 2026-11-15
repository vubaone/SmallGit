import XCTest
import SwiftUI
import AppKit
@testable import SmallGit

/// Covers the wrap-off compare panes scrolling as one.
///
/// Two things are being pinned down: the sync controller's own arithmetic
/// (mirror, clamp, don't loop), and the AppKit/SwiftUI assumption it stands
/// on — that a representable placed inside a SwiftUI `ScrollView` can reach
/// the `NSScrollView` backing it. The second is the fragile one: SwiftUI
/// doesn't promise that hosting shape, and if a future release changes it the
/// panes would silently drift apart again with nothing else to catch it.
@MainActor
final class ComparePaneScrollSyncTests: XCTestCase {

    private func makeScrollView(
        document: CGSize,
        viewport: CGSize = CGSize(width: 400, height: 300)
    ) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: viewport))
        scrollView.documentView = NSView(frame: NSRect(origin: .zero, size: document))
        return scrollView
    }

    private func scroll(_ scrollView: NSScrollView, to point: CGPoint) {
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Mirroring

    func testScrollingTheLeftPaneMovesTheRightOne() {
        let sync = ComparePaneScrollSync()
        let left = makeScrollView(document: CGSize(width: 900, height: 4000))
        let right = makeScrollView(document: CGSize(width: 900, height: 4000))
        sync.register(left, as: .left)
        sync.register(right, as: .right)

        scroll(left, to: CGPoint(x: 0, y: 1200))

        XCTAssertEqual(right.contentView.bounds.origin.y, 1200, accuracy: 0.5,
                       "the right pane must follow the left vertically")
    }

    /// Symmetric: whichever side the user drags is the one that leads.
    func testScrollingTheRightPaneMovesTheLeftOne() {
        let sync = ComparePaneScrollSync()
        let left = makeScrollView(document: CGSize(width: 900, height: 4000))
        let right = makeScrollView(document: CGSize(width: 900, height: 4000))
        sync.register(left, as: .left)
        sync.register(right, as: .right)

        scroll(right, to: CGPoint(x: 0, y: 800))

        XCTAssertEqual(left.contentView.bounds.origin.y, 800, accuracy: 0.5)
    }

    /// Horizontal too — otherwise scrolling out to read a long line compares
    /// column 5 on one side against column 80 on the other.
    func testHorizontalScrollIsMirrored() {
        let sync = ComparePaneScrollSync()
        let left = makeScrollView(document: CGSize(width: 2000, height: 4000))
        let right = makeScrollView(document: CGSize(width: 2000, height: 4000))
        sync.register(left, as: .left)
        sync.register(right, as: .right)

        scroll(left, to: CGPoint(x: 350, y: 0))

        XCTAssertEqual(right.contentView.bounds.origin.x, 350, accuracy: 0.5)
    }

    // MARK: - Clamping

    /// The panes agree on height but not width — the longest line differs per
    /// side. Mirroring a wide pane's offset onto a narrow one unclamped would
    /// scroll it past its content and show blank space.
    func testMirroredOffsetIsClampedToTheTargetsOwnContent() {
        let sync = ComparePaneScrollSync()
        let wide = makeScrollView(document: CGSize(width: 3000, height: 4000))
        let narrow = makeScrollView(document: CGSize(width: 600, height: 4000))
        sync.register(wide, as: .left)
        sync.register(narrow, as: .right)

        scroll(wide, to: CGPoint(x: 2400, y: 0))

        // viewport is 400 wide, so the narrow pane can only reach 600 - 400.
        XCTAssertEqual(narrow.contentView.bounds.origin.x, 200, accuracy: 0.5,
                       "must stop at the narrow pane's own maximum, not follow to 2400")
    }

    // MARK: - Loop safety

    /// Mirroring changes the target's bounds, which posts the same
    /// notification back. Without the re-entrancy guard plus the "already
    /// close enough" check that would ping-pong forever.
    func testMirroringSettlesInsteadOfLooping() {
        let sync = ComparePaneScrollSync()
        let left = makeScrollView(document: CGSize(width: 900, height: 4000))
        let right = makeScrollView(document: CGSize(width: 900, height: 4000))
        sync.register(left, as: .left)
        sync.register(right, as: .right)

        // Would hang or blow the stack if the mirror fed back into itself.
        scroll(left, to: CGPoint(x: 120, y: 900))

        XCTAssertEqual(left.contentView.bounds.origin.y, 900, accuracy: 0.5,
                       "the pane the user moved must stay where they put it")
        XCTAssertEqual(right.contentView.bounds.origin.y, 900, accuracy: 0.5)
    }

    /// SwiftUI calls the finder on every update pass, so re-registering the
    /// same scroll view has to be free rather than stacking observers (which
    /// would mirror N times per scroll).
    func testReregisteringTheSamePaneIsIdempotent() {
        let sync = ComparePaneScrollSync()
        let left = makeScrollView(document: CGSize(width: 900, height: 4000))
        let right = makeScrollView(document: CGSize(width: 900, height: 4000))
        for _ in 0..<5 {
            sync.register(left, as: .left)
            sync.register(right, as: .right)
        }

        scroll(left, to: CGPoint(x: 0, y: 640))

        XCTAssertEqual(right.contentView.bounds.origin.y, 640, accuracy: 0.5)
    }

    /// Resolve Conflict has three aligned panes. The same controller must
    /// mirror one gesture to every other member, not just a hard-coded pair.
    func testOnePaneCanDriveAThreePaneGroup() {
        enum Side: Hashable, Sendable { case ours, base, theirs }
        let sync = SynchronizedPaneScrollGroup<Side>()
        let ours = makeScrollView(document: CGSize(width: 1200, height: 4000))
        let base = makeScrollView(document: CGSize(width: 1200, height: 4000))
        let theirs = makeScrollView(document: CGSize(width: 1200, height: 4000))
        sync.register(ours, as: .ours)
        sync.register(base, as: .base)
        sync.register(theirs, as: .theirs)

        scroll(theirs, to: CGPoint(x: 240, y: 1100))

        XCTAssertEqual(ours.contentView.bounds.origin.x, 240, accuracy: 0.5)
        XCTAssertEqual(ours.contentView.bounds.origin.y, 1100, accuracy: 0.5)
        XCTAssertEqual(base.contentView.bounds.origin.x, 240, accuracy: 0.5)
        XCTAssertEqual(base.contentView.bounds.origin.y, 1100, accuracy: 0.5)
    }

    // MARK: - The SwiftUI assumption underneath

    /// `ComparePaneScrollSync` can only be handed a scroll view because
    /// `enclosingScrollView`, called from a representable inside a SwiftUI
    /// `ScrollView`, resolves to the one SwiftUI is driving. Nothing in the
    /// SwiftUI contract guarantees that, so verify it directly.
    func testRepresentableInsideASwiftUIScrollViewCanReachItsNSScrollView() {
        final class Accessor: NSView {
            var report: ((NSScrollView?) -> Void)?
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                report?(enclosingScrollView)
            }
        }
        struct Finder: NSViewRepresentable {
            let report: (NSScrollView?) -> Void
            func makeNSView(context: Context) -> Accessor {
                let view = Accessor()
                view.report = report
                return view
            }
            func updateNSView(_ nsView: Accessor, context: Context) {
                nsView.report = report
                report(nsView.enclosingScrollView)
            }
        }

        var found: [String: NSScrollView] = [:]
        let root = HStack(spacing: 0) {
            ForEach(["left", "right"], id: \.self) { side in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<60, id: \.self) { i in
                            Text("\(side) \(i)").fixedSize()
                        }
                    }
                    .background(Finder { if let s = $0 { found[side] = s } })
                }
            }
        }
        .frame(width: 800, height: 300)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        // A window built this way defaults to releasing itself on close, which
        // under ARC is an over-release: `close()` drops AppKit's reference and
        // then `window` going out of scope drops it again. The corpse is only
        // touched later, when AppKit's animation teardown drains the pool — so
        // the segfault lands in whichever test happens to be running then, not
        // in this one. Same reason `CompareWindowPresenter` clears it.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        XCTAssertNotNil(found["left"], "left pane's backing NSScrollView must be reachable")
        XCTAssertNotNil(found["right"], "right pane's backing NSScrollView must be reachable")
        XCTAssertFalse(
            found["left"] === found["right"],
            "each pane must resolve to its *own* scroll view, or syncing is meaningless"
        )

        window.close()
    }
}
