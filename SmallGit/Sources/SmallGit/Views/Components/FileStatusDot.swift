import SwiftUI

/// Status dot shown at the head of a file row. A rename / copy is a
/// delete *and* an add rolled into one entry, so it renders as a split
/// dot — red (the removed old path) on the left, green (the added new
/// path) on the right — to flag that dual nature at a glance. Every
/// other state is a solid dot in the caller-supplied `color` (which
/// already factors in stage state via `displaySwatch`).
struct FileStatusDot: View {
    let file: GitFileStatus
    var color: Color
    var size: CGFloat = 8

    private var isSplit: Bool {
        file.state == .renamed || file.state == .copied
    }

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: size, height: size)
    }

    private var fill: AnyShapeStyle {
        guard isSplit else { return AnyShapeStyle(color) }
        // Two hard stops at the midpoint give a clean vertical split
        // rather than a blended gradient.
        return AnyShapeStyle(LinearGradient(
            stops: [
                .init(color: GitFileState.deleted.swatch, location: 0),
                .init(color: GitFileState.deleted.swatch, location: 0.5),
                .init(color: GitFileState.added.swatch,   location: 0.5),
                .init(color: GitFileState.added.swatch,   location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        ))
    }
}
