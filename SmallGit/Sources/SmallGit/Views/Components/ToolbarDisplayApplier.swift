import SwiftUI
import AppKit

/// Reaches up to the hosting `NSWindow` and toggles its toolbar's
/// `displayMode` between icon+label and icon-only. SwiftUI's
/// `.toolbar` content is bridged to `NSToolbar` under the hood, but
/// the display mode isn't exposed as a SwiftUI modifier — so we set
/// it directly via AppKit on every config change.
///
/// Used as a `.background { ToolbarDisplayApplier(...) }` on any
/// window that hosts a SwiftUI toolbar (MainWindow, LogWindow, …)
/// so the user's "Show button labels" preference applies everywhere
/// consistently.
struct ToolbarDisplayApplier: NSViewRepresentable {
    let showLabels: Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { apply(from: v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(from: nsView) }
    }

    private func apply(from view: NSView) {
        guard let toolbar = view.window?.toolbar else { return }
        toolbar.displayMode = showLabels ? .iconAndLabel : .iconOnly
    }
}
