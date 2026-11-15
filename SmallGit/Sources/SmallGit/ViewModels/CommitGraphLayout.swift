import Foundation

/// Per-commit layout produced by `CommitGraphLayoutEngine`.
///
/// Indexed by commit row position (i.e. the same order as the `[GitCommit]`
/// array passed in). Lane 0 is the leftmost column. A commit "lives" on
/// one lane (where its dot is drawn); other lanes can pass through that
/// row without intersecting (drawn as plain vertical lines behind the
/// commit dot).
struct GraphRow: Hashable, Sendable {
    /// The lane index this commit's dot sits on.
    let lane: Int
    /// Lanes that have a vertical line through this row from the previous
    /// row down to the next (a branch / continuation that doesn't touch
    /// this commit).
    let throughLanes: [Int]
    /// Lanes that this row's parents continue onto. For a merge commit
    /// this has > 1 entry. The first lane is the same as `lane`
    /// (first-parent continuation).
    let parentLanes: [Int]
    /// Lanes (other than `lane`) that were also waiting for this commit
    /// and need to curve into the dot from above — i.e. branches that
    /// merge back into the dot's lane here. SmartGit draws these as a
    /// closing arc from the top of the row down to the dot's centre.
    let mergingLanes: [Int]
    /// Total lane count in use at this row. Determines column width.
    let activeLaneCount: Int
    /// `true` when some earlier commit's parent already pointed to this
    /// lane before we got here (i.e. the lane was "expecting" us). False
    /// for branch tips and merge commits whose lane was freshly allocated
    /// — those shouldn't render a top-to-dot vertical line because
    /// there's nothing on that lane above the row.
    let incomingExpected: Bool
}

/// The graph slice drawn for a collapsed run of hidden commits: the
/// lanes entering the gap from above and the ones leaving it below.
/// Drawn as two half-height strokes so a branch that begins or ends
/// inside the gap reads as a stub rather than a line that lies about
/// running through.
struct GraphGapRow: Hashable, Sendable {
    let topLanes: [Int]
    let bottomLanes: [Int]

    static let empty = GraphGapRow(topLanes: [], bottomLanes: [])
}

/// Output of laying out a sequence of commits as a topology graph.
struct CommitGraphLayout: Sendable {
    /// Per-commit graph data, parallel to the input commits array.
    let rows: [GraphRow]
    /// Maximum lane count seen across all rows. Used to size the column.
    let maxLanes: Int

    static let empty = CommitGraphLayout(rows: [], maxLanes: 0)

    /// A dot per row on lane 0 and nothing else. Used when the list on
    /// screen isn't a contiguous history — git-backed search results are
    /// commits plucked from all over, and laying out a topology over
    /// them invents lanes for parents that were never fetched.
    static func flat(count: Int) -> CommitGraphLayout {
        let row = GraphRow(
            lane: 0,
            throughLanes: [],
            parentLanes: [],
            mergingLanes: [],
            activeLaneCount: 1,
            incomingExpected: false
        )
        return CommitGraphLayout(rows: Array(repeating: row, count: count), maxLanes: 1)
    }

    /// Lanes crossing the boundary above row `index`.
    func incomingLanes(at index: Int) -> [Int] {
        guard rows.indices.contains(index) else { return [] }
        let row = rows[index]
        var lanes = Set(row.throughLanes)
        lanes.formUnion(row.mergingLanes)
        if row.incomingExpected { lanes.insert(row.lane) }
        return lanes.sorted()
    }

    /// Lanes crossing the boundary below row `index`.
    func outgoingLanes(at index: Int) -> [Int] {
        guard rows.indices.contains(index) else { return [] }
        let row = rows[index]
        var lanes = Set(row.throughLanes)
        lanes.formUnion(row.parentLanes)
        return lanes.sorted()
    }

    /// The graph for a hidden run spanning rows `first...last`: what
    /// enters at the top, what leaves at the bottom. Anything that only
    /// lives inside the run is deliberately absent — the row is one line
    /// tall and can't tell that story honestly.
    func gap(from first: Int, to last: Int) -> GraphGapRow {
        GraphGapRow(
            topLanes: incomingLanes(at: first),
            bottomLanes: outgoingLanes(at: last)
        )
    }
}

/// Walks commits newest-first and assigns each one to a lane.
///
/// Mental model: think of each lane as a vertical track that's "waiting"
/// for a particular commit hash to come down. When we encounter that
/// commit, we draw a dot on the track, then the track switches to
/// waiting for the commit's first parent. Additional parents (merges)
/// each get their own track on the right if no existing track is
/// already waiting for them.
///
/// The algorithm is O(rows × lanes); lane reuse keeps lane count small
/// for typical linear / lightly-branched histories.
enum CommitGraphLayoutEngine {

    static func compute(commits: [GitCommit]) -> CommitGraphLayout {
        guard !commits.isEmpty else { return .empty }

        // active[i] = hash that lane i is currently waiting to draw, or
        // nil if the lane is free for reuse.
        var active: [String?] = []
        var rows: [GraphRow] = []
        var maxLanes = 0
        // Hashes already drawn on an earlier (higher) row. A parent in this
        // set can never be matched by a later row, so opening a lane for it
        // would leave a line dangling to the bottom of the view. This only
        // happens when the input isn't topologically ordered (e.g. a stale
        // cached log); `--topo-order` normally guarantees parents follow
        // their children.
        var seen = Set<String>()

        for commit in commits {
            // 1. Find every lane currently waiting on this commit. The
            //    leftmost match is the dot's lane; others get collapsed.
            let waiting = active.indices.filter { active[$0] == commit.hash }
            let dotLane: Int
            let incomingExpected: Bool
            let mergingLanes: [Int]

            if let first = waiting.first {
                dotLane = first
                incomingExpected = true
                // Any other lanes also waiting for this commit are
                // branches that merge back into the dot here. Capture
                // them so the renderer can draw closing curves before
                // we clear the slots.
                mergingLanes = waiting.dropFirst().map { $0 }
                for idx in waiting { active[idx] = nil }
            } else {
                // No one was expecting this commit (a branch tip, or the
                // first row). Place it on the leftmost free lane and tell
                // the renderer to skip the phantom top-to-dot line.
                dotLane = allocateLane(in: &active)
                incomingExpected = false
                mergingLanes = []
            }

            // 2. Promote the commit's first parent onto this lane. Skip any
            //    parent already drawn above (see `seen`) — routing to it
            //    would dangle a line that never closes.
            var parentLanes: [Int] = []
            let drawableParents = commit.parentHashes.filter { !seen.contains($0) }
            if let firstParent = drawableParents.first {
                active[dotLane] = firstParent
                parentLanes.append(dotLane)
                // 3. Additional parents (merge): each gets its own lane,
                //    reusing any existing lane that already waits for it.
                for extraParent in drawableParents.dropFirst() {
                    if let existing = active.firstIndex(where: { $0 == extraParent }) {
                        parentLanes.append(existing)
                    } else {
                        let lane = allocateLane(in: &active)
                        active[lane] = extraParent
                        parentLanes.append(lane)
                    }
                }
            } else {
                // Root commit, parent outside the window, or every parent
                // already drawn above — the lane terminates here.
                active[dotLane] = nil
                parentLanes.append(dotLane)
            }

            // 4. Trailing nil lanes can be dropped — keeps activeLaneCount
            //    honest as branches die out.
            while let last = active.last, last == nil { active.removeLast() }

            // 5. Pass-through lanes = anything in active that isn't this
            //    commit's dot lane and isn't one of its parent lanes.
            let throughLanes = active.indices.filter { idx in
                active[idx] != nil && idx != dotLane && !parentLanes.contains(idx)
            }

            let activeCount = max(dotLane + 1, active.count)
            maxLanes = max(maxLanes, activeCount)
            rows.append(GraphRow(
                lane: dotLane,
                throughLanes: throughLanes,
                parentLanes: parentLanes,
                mergingLanes: mergingLanes,
                activeLaneCount: activeCount,
                incomingExpected: incomingExpected
            ))
            seen.insert(commit.hash)
        }

        return CommitGraphLayout(rows: rows, maxLanes: maxLanes)
    }

    /// Find the leftmost free lane, expanding the array if necessary.
    private static func allocateLane(in active: inout [String?]) -> Int {
        if let empty = active.firstIndex(where: { $0 == nil }) {
            return empty
        }
        active.append(nil)
        return active.count - 1
    }
}
