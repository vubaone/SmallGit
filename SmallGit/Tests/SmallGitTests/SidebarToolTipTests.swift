import XCTest
import SwiftUI
import AppKit
@testable import SmallGit

/// The sidebar's rows are truncated by design — the panel is narrow and
/// the names are long — so hover text is the only way to read one in
/// full. `.help` alone doesn't deliver it inside a `List`, so these pin
/// the AppKit path that does.
@MainActor
final class SidebarToolTipTests: XCTestCase {

    /// Renders a view and returns the tooltip AppKit ended up holding.
    private func installedToolTip(on view: some View) throws -> String? {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 24)
        host.layoutSubtreeIfNeeded()
        return firstToolTip(in: host)
    }

    private func firstToolTip(in view: NSView) -> String? {
        if let text = view.toolTip { return text }
        for subview in view.subviews {
            if let found = firstToolTip(in: subview) { return found }
        }
        return nil
    }

    func testTheToolTipReachesAnAppKitView() throws {
        let text = "On social/ZSOC-1256-bug-1825927-missmp3button"
        let tip = try installedToolTip(on: Text("truncated…").toolTip(text))
        XCTAssertEqual(tip, text,
            "the string has to land on a real NSView or no tooltip ever appears")
    }

    func testTheToolTipUpdatesWhenTheTextDoes() throws {
        let host = NSHostingView(rootView: AnyView(Text("row").toolTip("first")))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 24)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(firstToolTip(in: host), "first")

        host.rootView = AnyView(Text("row").toolTip("second"))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(firstToolTip(in: host), "second",
            "a row recycled for another stash must not keep the old name")
    }

    /// The tooltip must not cost a click: the row underneath it is what
    /// the table selects with.
    func testTheToolTipViewIsInvisibleToTheMouse() throws {
        let host = NSHostingView(rootView: AnyView(Color.clear.toolTip("x")))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 24)
        host.layoutSubtreeIfNeeded()

        let tipViews = collectToolTipViews(in: host)
        XCTAssertFalse(tipViews.isEmpty, "no tooltip view was installed")
        for view in tipViews {
            XCTAssertNil(view.hitTest(CGPoint(x: view.bounds.midX, y: view.bounds.midY)),
                "the tooltip backing swallowed a click meant for the row")
        }
    }

    private func collectToolTipViews(in view: NSView) -> [NSView] {
        var out: [NSView] = []
        if view.toolTip != nil { out.append(view) }
        for subview in view.subviews { out += collectToolTipViews(in: subview) }
        return out
    }
}
