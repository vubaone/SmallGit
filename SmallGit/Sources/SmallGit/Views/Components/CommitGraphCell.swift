import SwiftUI

/// Renders one row's slice of the commit graph: vertical lane lines
/// passing through, smooth curves from this commit down to its
/// parents in their respective lanes, and a filled dot at the
/// commit's own lane.
///
/// Row-continuity contract: this view draws a `Canvas` at exactly
/// `Self.rowHeight` points. JournalView pins every other Journal
/// column to the same height so SwiftUI's Table never inflates a row
/// beyond what we drew into. Both halves of a same-lane vertical line
/// then meet at the row boundary with no gap, producing the
/// continuous ribbon look SmartGit ships.
///
/// `GeometryReader` doesn't work here — Table cells propose a tiny
/// natural height to their child, so the Canvas would draw a 10pt-
/// tall slice in the middle of a 26pt row.
struct CommitGraphCell: View {
    let row: GraphRow
    /// Number of lanes the column reserves space for. Usually
    /// `journalVM.graphLayout.maxLanes` so all rows align.
    let totalLanes: Int
    /// Overrides the dot's lane color when set (e.g. orange for
    /// unpushed). When `nil` the dot uses the lane palette.
    let dotOverride: Color?
    /// Draws a dashed line from the top edge into the dot — the other half
    /// of the working-tree row's connector. A branch tip has no incoming
    /// line of its own, so without this the uncommitted node above would
    /// dangle with a gap between it and the commit it sits on.
    var dashedIncoming: Bool = false

    /// The shared row height — matched by all Journal cells so the
    /// graph strokes meet at row boundaries exactly.
    static let rowHeight: CGFloat = 28

    /// Ceiling on how many lanes the column will ever render. A busy
    /// repo can be 30 lanes wide, and at 18pt each that column eats the
    /// panel and leaves no room for the commit subject — the graph stops
    /// being useful long before then. Deeper lanes fold onto the last
    /// column: every commit still gets a dot, the width stays sane.
    static let maxRenderedLanes: Int = 8

    /// Width the Journal reserves for the graph column at `lanes` lanes.
    static func columnWidth(lanes: Int) -> CGFloat {
        CGFloat(min(max(1, lanes), maxRenderedLanes)) * laneSpacing + 4
    }

    /// Horizontal distance between lane centres. Wider than the original
    /// 12pt so curves between lanes have room to bow into a real arc —
    /// otherwise a 12pt horizontal jump over a 13pt vertical drop reads
    /// as nearly straight and the lines look "cut" rather than smooth.
    static let laneSpacing: CGFloat = 18
    private static let lineWidth:   CGFloat = 1.8
    private static let dotRadius:   CGFloat = 4
    /// Shared by both halves of the working-tree connector, so the dashes
    /// line up across the row boundary instead of meeting mid-gap.
    static let dashedStroke = StrokeStyle(lineWidth: 1.8, dash: [3, 3])

    /// Centre of `lane` within the graph column — the one place this is
    /// worked out, so anything drawing alongside the graph lands on the
    /// same x as the dots.
    static func laneCentre(_ lane: Int) -> CGFloat {
        laneSpacing / 2 + CGFloat(max(0, lane)) * laneSpacing
    }

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .frame(width: cellWidth, height: Self.rowHeight)
    }

    private var laneCount: Int {
        min(max(1, totalLanes), Self.maxRenderedLanes)
    }

    private var cellWidth: CGFloat {
        CGFloat(laneCount) * Self.laneSpacing
    }

    /// Lanes past the cap all draw on the last column rather than off the
    /// edge — a folded lane is a small lie about position, an invisible
    /// commit is a bigger one.
    private func xFor(_ lane: Int) -> CGFloat {
        let clamped = min(max(0, lane), laneCount - 1)
        return Self.laneSpacing / 2 + CGFloat(clamped) * Self.laneSpacing
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let mid = size.height / 2
        let dotX = xFor(row.lane)
        // Overdraw past row edges so anti-aliasing doesn't fade the
        // last pixel — without this, the line on row N is full opacity
        // until y ≈ height-1 and the line on row N+1 starts at y ≈ 1,
        // leaving a sub-pixel break the user can see as a row seam.
        let overscan: CGFloat = 1

        // 1. Through-lanes: full-height vertical lines for branches
        //    that exist at this row but don't touch the dot. Drawn
        //    first so the dot + parent lines can paint on top.
        for lane in row.throughLanes {
            let x = xFor(lane)
            var p = Path()
            p.move(to: CGPoint(x: x, y: -overscan))
            p.addLine(to: CGPoint(x: x, y: size.height + overscan))
            ctx.stroke(p, with: .color(color(for: lane)), lineWidth: Self.lineWidth)
        }

        // 2. Incoming line — from top of cell down to the dot's centre,
        //    drawn in the dot's lane color. Skipped for branch tips
        //    and merge commits whose lane was freshly allocated, since
        //    nothing is on that lane above them — drawing it would
        //    create a phantom segment with no continuation.
        if row.incomingExpected {
            var top = Path()
            top.move(to: CGPoint(x: dotX, y: -overscan))
            top.addLine(to: CGPoint(x: dotX, y: mid))
            ctx.stroke(top, with: .color(color(for: row.lane)), lineWidth: Self.lineWidth)
        }

        // 2a. The working tree above this row, if it is there: dashed,
        //     because what it connects is not a commit yet.
        if dashedIncoming {
            var top = Path()
            top.move(to: CGPoint(x: dotX, y: -overscan))
            top.addLine(to: CGPoint(x: dotX, y: mid))
            ctx.stroke(
                top,
                with: .color(color(for: row.lane).opacity(0.7)),
                style: Self.dashedStroke
            )
        }

        // 2b. Incoming merge curves — for each lane (other than the dot's)
        //     that was waiting for this commit, draw a curve from the top
        //     of the row sweeping into the dot. Mirror of the outgoing
        //     curve so the two halves meet seamlessly at the merge point.
        for mergeLane in row.mergingLanes {
            let mx = xFor(mergeLane)
            var p = Path()
            p.move(to: CGPoint(x: mx, y: -overscan))
            p.addCurve(
                to: CGPoint(x: dotX, y: mid),
                control1: CGPoint(x: mx,   y: mid),
                control2: CGPoint(x: dotX, y: 0)
            )
            ctx.stroke(p, with: .color(color(for: mergeLane)), lineWidth: Self.lineWidth)
        }

        // 3. Outgoing lines to each parent's lane. Same-lane = straight
        //    vertical; cross-lane = smooth cubic that bulges into a
        //    full quarter-arc so the transition reads as "the branch
        //    swept down into this lane" rather than a zig-zag.
        for parentLane in row.parentLanes {
            let px = xFor(parentLane)
            var p = Path()
            p.move(to: CGPoint(x: dotX, y: mid))
            if parentLane == row.lane {
                p.addLine(to: CGPoint(x: px, y: size.height + overscan))
            } else {
                // Quarter-arc-shaped cubic: control point 1 stays on the
                // starting lane all the way down to the row's bottom
                // edge; control point 2 sits on the parent lane already
                // at the dot's y. The two together produce an arc that's
                // tangent-vertical at the dot end and tangent-vertical
                // at the parent-lane end, with a fully rounded belly.
                p.addCurve(
                    to: CGPoint(x: px, y: size.height + overscan),
                    control1: CGPoint(x: dotX, y: size.height),
                    control2: CGPoint(x: px,   y: mid)
                )
            }
            ctx.stroke(p, with: .color(color(for: parentLane)), lineWidth: Self.lineWidth)
        }

        // 4. The dot. Painted last so it sits on top of every line.
        let r = Self.dotRadius
        let dotRect = CGRect(x: dotX - r, y: mid - r, width: r * 2, height: r * 2)
        let fill = dotOverride ?? color(for: row.lane)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(fill))
        // Tiny ring keeps the dot legible against the lane line running
        // under it — dark on a dark theme, white on a light one.
        ctx.stroke(Path(ellipseIn: dotRect), with: .color(.graphDotRing), lineWidth: 1)
    }

    /// Color for `lane` — looked up from `JournalViewModel.laneColor`'s
    /// palette so the same lane stays the same color across rows.
    private func color(for lane: Int) -> Color {
        switch JournalViewModel.laneColor(lane) {
        case .blue:   return .graphBlue
        case .green:  return .graphGreen
        case .orange: return .graphOrange
        case .purple: return .graphPurple
        case .pink:   return .graphPink
        case .teal:   return .graphTeal
        case .yellow: return .graphYellow
        case .indigo: return .graphIndigo
        }
    }
}

/// The graph slice drawn on a collapsed run of hidden commits: the
/// lanes arriving from above as a top half-stroke, the lanes leaving
/// below as a bottom one, and a small hollow marker on the lane the
/// gap's own commits sat on. Dimmed, because none of these rows is a
/// commit you can point at.
struct CommitGraphGapCell: View {
    let gap: GraphGapRow
    let totalLanes: Int

    private var laneCount: Int {
        min(max(1, totalLanes), CommitGraphCell.maxRenderedLanes)
    }

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            let overscan: CGFloat = 1
            for lane in gap.topLanes {
                var p = Path()
                p.move(to: CGPoint(x: x(lane), y: -overscan))
                p.addLine(to: CGPoint(x: x(lane), y: mid))
                ctx.stroke(p, with: .color(color(lane).opacity(0.55)), lineWidth: 1.8)
            }
            for lane in gap.bottomLanes {
                var p = Path()
                p.move(to: CGPoint(x: x(lane), y: mid))
                p.addLine(to: CGPoint(x: x(lane), y: size.height + overscan))
                ctx.stroke(p, with: .color(color(lane).opacity(0.55)), lineWidth: 1.8)
            }
            // Hollow marker where the hidden commits live, on the
            // leftmost lane that crosses the gap.
            if let lane = gap.topLanes.first ?? gap.bottomLanes.first {
                let r: CGFloat = 2.5
                let rect = CGRect(x: x(lane) - r, y: mid - r, width: r * 2, height: r * 2)
                ctx.stroke(Path(ellipseIn: rect), with: .color(color(lane).opacity(0.7)), lineWidth: 1.4)
            }
        }
        .frame(width: CGFloat(laneCount) * CommitGraphCell.laneSpacing,
               height: CommitGraphCell.rowHeight)
    }

    private func x(_ lane: Int) -> CGFloat {
        let clamped = min(max(0, lane), laneCount - 1)
        return CommitGraphCell.laneSpacing / 2 + CGFloat(clamped) * CommitGraphCell.laneSpacing
    }

    private func color(_ lane: Int) -> Color {
        switch JournalViewModel.laneColor(lane) {
        case .blue:   return .graphBlue
        case .green:  return .graphGreen
        case .orange: return .graphOrange
        case .purple: return .graphPurple
        case .pink:   return .graphPink
        case .teal:   return .graphTeal
        case .yellow: return .graphYellow
        case .indigo: return .graphIndigo
        }
    }
}

// MARK: - Lane palette

/// Eight lane colours that have to stay apart from each other *and* from the
/// background. The dark set is bright and slightly pastel because it is drawn
/// on near-black; the light set is darker and more saturated for the same
/// reason in reverse — the dark theme's pale yellow is invisible on white.
extension Palette {
    static let graphBlue   = themed("graphBlue",   light: 0x1668C7, dark: 0x59B3FF)
    static let graphGreen  = themed("graphGreen",  light: 0x1E8E3E, dark: 0x66D980)
    static let graphOrange = themed("graphOrange", light: 0xC26A00, dark: 0xFFA64D)
    static let graphPurple = themed("graphPurple", light: 0x8A3FD1, dark: 0xCC8CFF)
    static let graphPink   = themed("graphPink",   light: 0xC93777, dark: 0xFF8CBF)
    static let graphTeal   = themed("graphTeal",   light: 0x0E8080, dark: 0x66D9D9)
    static let graphYellow = themed("graphYellow", light: 0xA07800, dark: 0xFFD959)
    static let graphIndigo = themed("graphIndigo", light: 0x4A4ADB, dark: 0x8C8CFF)
}

extension Color {
    static let graphBlue   = Color(nsColor: Palette.graphBlue)
    static let graphGreen  = Color(nsColor: Palette.graphGreen)
    static let graphOrange = Color(nsColor: Palette.graphOrange)
    static let graphPurple = Color(nsColor: Palette.graphPurple)
    static let graphPink   = Color(nsColor: Palette.graphPink)
    static let graphTeal   = Color(nsColor: Palette.graphTeal)
    static let graphYellow = Color(nsColor: Palette.graphYellow)
    static let graphIndigo = Color(nsColor: Palette.graphIndigo)
}


/// The graph slice for the working-tree row: an open dashed ring where a
/// commit has a filled dot, and a dashed line running down to the commit
/// below it.
///
/// Dashed throughout because the thing it marks is not in the history yet —
/// and drawn from `CommitGraphCell`'s own geometry so the ring sits on the
/// same lane centre as every dot under it.
struct WorkingTreeGraphCell: View {
    let totalLanes: Int

    var body: some View {
        Canvas { ctx, size in
            let x = CommitGraphCell.laneCentre(0)
            let mid = size.height / 2
            let color = Color.graphBlue.opacity(0.7)

            var down = Path()
            down.move(to: CGPoint(x: x, y: mid))
            down.addLine(to: CGPoint(x: x, y: size.height + 1))
            ctx.stroke(down, with: .color(color), style: CommitGraphCell.dashedStroke)

            let r: CGFloat = 4
            let ring = Path(ellipseIn: CGRect(x: x - r, y: mid - r, width: r * 2, height: r * 2))
            ctx.stroke(ring, with: .color(color), style: StrokeStyle(lineWidth: 1.8, dash: [2.5, 2.5]))
        }
        .frame(
            width: CGFloat(min(max(1, totalLanes), CommitGraphCell.maxRenderedLanes))
                * CommitGraphCell.laneSpacing,
            height: CommitGraphCell.rowHeight
        )
    }
}
