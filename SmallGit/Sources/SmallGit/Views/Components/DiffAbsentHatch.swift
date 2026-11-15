import SwiftUI

/// The "nothing on this side" fill for a side-by-side diff: 45° hatching
/// across the gap a block of added or removed lines leaves opposite itself.
///
/// A blank cell reads as blank *lines* — content that exists and happens to
/// be empty, which is exactly what the reader must not conclude there. The
/// hatching reads as absence instead, and because it is one continuous
/// pattern it gives the block an extent: the eye takes in "eight lines were
/// inserted here" in a glance rather than counting rows. Beyond Compare
/// draws the same thing, and it is the single clearest cue it has.
struct DiffAbsentHatch: View {
    @Environment(\.monoFontSize) private var monoFontSize

    var body: some View {
        Canvas { context, size in
            var path = Path()
            // Start one row-height to the left of the cell so the stripes
            // crossing the top-left corner are drawn too, and run one past
            // the right edge for the same reason.
            var x = -size.height
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += stripeSpacing
            }
            context.stroke(path, with: .color(.diffAbsentHatch), lineWidth: 1)
        }
        .background(Color.diffEmptyBg)
        // Rows sit above this; nothing here should intercept a click meant
        // for the row's selection or context menu.
        .allowsHitTesting(false)
    }

    /// Half a row — the density Beyond Compare's own hatching reads at.
    ///
    /// The fraction matters more than the value. Each row draws its own
    /// hatching from its own origin, so the pattern only continues across a
    /// row boundary if its period divides the row height — otherwise every
    /// boundary steps the stripes sideways and the block reads as a stack of
    /// separate cells, which is the problem the hatching is here to solve.
    private var stripeSpacing: CGFloat {
        max(3, monoRowHeight(for: monoFontSize) / 2)
    }
}
