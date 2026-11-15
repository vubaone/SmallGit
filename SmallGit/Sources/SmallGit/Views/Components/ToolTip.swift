import SwiftUI
import AppKit

/// Attaches a real AppKit tooltip to the view it backs.
///
/// SwiftUI's `.help` is unreliable inside a `List` row on macOS: the row
/// is hosted in an `NSTableView` cell whose tracking areas belong to the
/// table, and the modifier's tooltip frequently never fires — which is
/// how a sidebar full of truncated names ends up with no way to read
/// them. Setting `toolTip` on a background `NSView` puts the string where
/// AppKit is already looking, and the background sizes itself to the row
/// so the whole row is hoverable, not just the glyphs.
private struct ToolTipBacking: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughToolTipView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.toolTip = text
    }

    /// Invisible to the mouse. A plain `NSView` would answer hit tests and
    /// swallow the click the table needs to select the row with; a tooltip
    /// must not cost a click.
    private final class PassthroughToolTipView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// Hover text for this view, delivered by AppKit.
    ///
    /// Prefer this over `.help` for anything inside a `List`; use `.help`
    /// as well when the string is also worth having as an accessibility
    /// hint.
    func toolTip(_ text: String) -> some View {
        background(ToolTipBacking(text: text))
    }
}
