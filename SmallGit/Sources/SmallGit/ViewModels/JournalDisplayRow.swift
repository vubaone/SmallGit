import Foundation

/// One rendered line of the Journal.
///
/// With no filter every commit is its own `.commit` row. A filter turns
/// each run of non-matching commits into a single `.collapsed` row
/// instead of deleting them: the graph is laid out over the *whole*
/// commit list, so the rows between two matches still have to exist for
/// the lanes to connect. This is what SmartGit does — the matches read
/// normally and the skipped ranges shrink to one dim line carrying the
/// refs buried inside them.
enum JournalDisplayRow: Identifiable, Sendable {
    case commit(GitCommit)
    case collapsed(CollapsedRun)

    var id: String {
        switch self {
        case .commit(let commit):  return commit.id
        case .collapsed(let run):  return run.id
        }
    }

    var commit: GitCommit? {
        if case .commit(let commit) = self { return commit }
        return nil
    }
}

/// A run of consecutive filtered-out commits, shown as one row.
struct CollapsedRun: Identifiable, Sendable {
    /// The first hidden commit's hash — stable while the query and the
    /// loaded window stay put, so expansion state survives a redraw.
    let id: String
    /// How many commits the run swallows.
    let count: Int
    /// Positions in the full commit list, for the graph slice.
    let firstIndex: Int
    let lastIndex: Int
    /// Refs found on the hidden commits: a branch tip or tag inside the
    /// gap stays discoverable instead of silently disappearing.
    let refs: [CommitRefLabel]
    /// Lanes crossing into and out of the gap, drawn as the two halves
    /// of the row's graph cell.
    let gap: GraphGapRow
}

enum JournalRowBuilder {

    /// Fold `commits` into display rows: matches stay, runs of misses
    /// collapse. `expanded` holds the ids of runs the user clicked open,
    /// which are emitted as ordinary commit rows.
    static func rows(
        commits: [GitCommit],
        matches: (GitCommit) -> Bool,
        layout: CommitGraphLayout,
        expanded: Set<String>
    ) -> [JournalDisplayRow] {
        var out: [JournalDisplayRow] = []
        out.reserveCapacity(commits.count)
        var runStart: Int?

        func flushRun(endingBefore end: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let last = end - 1
            let hidden = commits[start...last]
            let id = hidden.first?.hash ?? "gap-\(start)"
            if expanded.contains(id) {
                out.append(contentsOf: hidden.map { .commit($0) })
                return
            }
            out.append(.collapsed(CollapsedRun(
                id: id,
                count: hidden.count,
                firstIndex: start,
                lastIndex: last,
                // Cheap in practice: `%D` is empty for all but a handful
                // of commits, so this parses a few short strings per gap.
                refs: hidden.flatMap { RefParser.parse($0.refs) },
                gap: layout.gap(from: start, to: last)
            )))
        }

        for (idx, commit) in commits.enumerated() {
            if matches(commit) {
                flushRun(endingBefore: idx)
                out.append(.commit(commit))
            } else if runStart == nil {
                runStart = idx
            }
        }
        flushRun(endingBefore: commits.count)
        return out
    }
}
