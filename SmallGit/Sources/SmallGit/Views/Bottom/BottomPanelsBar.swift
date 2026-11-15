import SwiftUI

/// The arrow in front of the Journal's title that folds the bottom row away,
/// and the one on the folded bar that brings it back.
///
/// Points the way the panels will move: down to put them away, up to pull
/// them back out — rather than the sideways disclosure triangle of a tree,
/// which would say nothing about where the content went.
struct BottomPanelsDisclosure: View {
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                .scaledFont(10, weight: .semibold)
                // A chevron is a small glyph; the frame around it is what
                // makes it something you can hit without aiming.
                .frame(width: 30, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.textSecondary)
        .keyboardShortcut("j", modifiers: [.command, .control])
        .help(collapsed
              ? "Show Journal and Output (⌃⌘J)"
              : "Hide Journal and Output (⌃⌘J)")
    }
}

/// What the bottom row becomes when it is folded away: one bar naming the
/// two panels that are down there, so the space they had goes to the diff or
/// the terminal without the panels themselves going missing.
struct BottomPanelsBar: View {
    let expand: () -> Void

    /// Tall enough to read and to hold a comfortable hit target, short
    /// enough to be worth collapsing for. About a `PanelHeader`'s own height,
    /// so the folded row looks like what it is — two panel headers with
    /// nothing under them.
    static let height: CGFloat = 26

    var body: some View {
        HStack(spacing: 6) {
            BottomPanelsDisclosure(collapsed: true, toggle: expand)
            Text("JOURNAL")
            Text("·")
            Text("OUTPUT")
            Spacer(minLength: 4)
        }
        .scaledFont(11, weight: .medium)
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgPanelHeader)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.borderColor)
                .frame(height: 0.5)
        }
        // Deliberately not tappable as a whole: the bar sits directly under
        // the terminal's input and directly over the status bar, and a
        // full-width target there reopens the panels on a misplaced click
        // aimed at either. The arrow is the way back, and it is big enough
        // to hit.
    }
}

#Preview {
    BottomPanelsBar(expand: {})
        .frame(width: 600)
        .preferredColorScheme(.dark)
}
