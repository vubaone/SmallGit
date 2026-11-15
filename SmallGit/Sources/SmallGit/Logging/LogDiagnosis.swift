import Foundation

/// Something in the log worth a second look.
struct LogFinding: Identifiable, Hashable, Sendable {
    enum Severity: String, Sendable, Hashable {
        case warning
        case info
    }

    var id: String { "\(severity.rawValue):\(title)" }
    let severity: Severity
    let title: String
    /// What was actually measured. Kept concrete — a finding that says
    /// "possible performance issue" is noise; one that says "git status ran
    /// 412 times in 6 minutes" is a lead.
    let detail: String
}

/// Reads the summary and points at the patterns that usually mean a bug.
///
/// This is the difference between a log and an answer. Nobody scrolls 8,000
/// records looking for the one operation that runs twice a second — but that
/// operation is exactly the bug, and it is trivial to find arithmetically.
///
/// Every rule here is deliberately conservative and reports what it measured
/// rather than what it concluded. A diagnostic that cries wolf gets ignored,
/// and then the real finding is ignored with it.
enum LogDiagnosis {

    /// Sustained once-a-second is the threshold for "this is a loop, not a
    /// user". Below it, ordinary interactive use produces plenty of activity.
    private static let busyPerMinute: Double = 60

    /// Rates need a window to be a rate. Under a minute, a short burst of
    /// interactive work extrapolates to an alarming and meaningless number.
    private static let minimumWindowSeconds: TimeInterval = 60

    /// Remote operations are allowed to be slow — that is what remotes are.
    /// This is set where "slow" stops being the network and starts being
    /// worth investigating.
    private static let slowNetworkMs: Double = 5_000

    static func findings(_ summary: LogSummaryResult) -> [LogFinding] {
        var findings: [LogFinding] = []

        findings += busyOperations(summary)
        findings += dominantCost(summary)
        findings += failures(summary)
        findings += slowNetwork(summary)
        findings += cacheEffectiveness(summary)

        return findings.sorted { left, right in
            if left.severity != right.severity { return left.severity == .warning }
            return left.title < right.title
        }
    }

    /// Anything running on a timer it shouldn't be on.
    ///
    /// The watcher is called out separately: FSEvents batches arriving
    /// steadily while nothing is being edited means the app's own writes are
    /// feeding its watcher, which is a different bug from a poll loop even
    /// though the number looks the same.
    private static func busyOperations(_ summary: LogSummaryResult) -> [LogFinding] {
        // `activeSeconds`, not `windowSeconds`: the log spans every launch it
        // has survived, and judging a rate against the hours the app spent
        // closed buries exactly the finding this rule exists for.
        guard summary.activeSeconds >= minimumWindowSeconds else { return [] }
        return summary.rows.compactMap { row in
            guard let perMinute = row.perMinute, perMinute >= busyPerMinute else { return nil }
            let minutes = summary.activeSeconds / 60
            return LogFinding(
                severity: .warning,
                title: row.category == .watcher
                    ? "File watcher is firing continuously"
                    : "\(row.operation) is running constantly",
                detail: """
                \(row.count) calls in \(format(minutes: minutes)) of activity — \
                \(String(format: "%.0f", perMinute))/min. \
                \(row.category == .watcher
                    ? "Steady batches with nobody editing means the app's own writes are landing in the watched directory."
                    : "Check whether something is polling this rather than reacting to a change.")
                """
            )
        }
    }

    /// Where the time actually went.
    ///
    /// The rate rule only catches work spread evenly enough to look like a
    /// loop. Bursty work — a launch that spawns one subprocess per repository
    /// — averages out below any sane threshold while still being most of what
    /// the app did. Measured on a real log: `git rev-parse` was 50% of all git
    /// time at 387 calls, and 25/min, so nothing flagged it.
    ///
    /// Reported as information, not a warning: an operation being the most
    /// expensive one is not by itself a fault. It is, however, always the
    /// right place to look first.
    private static func dominantCost(_ summary: LogSummaryResult) -> [LogFinding] {
        let total = summary.rows.reduce(0) { $0 + $1.totalMs }
        guard total > 0 else { return [] }
        return summary.rows.compactMap { row in
            // Both conditions matter. Without the share, every log has a
            // "biggest" row; without the count, one genuinely slow command
            // reads as a systemic cost.
            guard row.count >= dominantMinimumCalls,
                  row.totalMs / total >= dominantShare else { return nil }
            return LogFinding(
                severity: .info,
                title: "\(row.operation) is where the time goes",
                detail: """
                \(String(format: "%.0f", row.totalMs / total * 100))% of all measured time — \
                \(row.count) calls totalling \(format(ms: row.totalMs)), \
                averaging \(format(ms: row.averageMs)) each. \
                Worth checking whether they are all needed, or cacheable.
                """
            )
        }
    }

    private static let dominantShare: Double = 0.4

    /// The threshold that stops this rule crying wolf, and it has to be high.
    ///
    /// In any ordinary session *something* is the biggest cost — 30 `git diff`
    /// calls can easily be 40% of a quiet session's time, and reporting that
    /// is noise. What is not ordinary is one operation accounting for most of
    /// the time across hundreds of cheap calls: that is a count problem
    /// wearing a cost problem's clothes, which is exactly the shape worth
    /// surfacing.
    private static let dominantMinimumCalls = 100

    private static func failures(_ summary: LogSummaryResult) -> [LogFinding] {
        summary.rows.filter { $0.failures > 0 }.map { row in
            LogFinding(
                severity: .warning,
                title: "\(row.operation) failed \(row.failures) time\(row.failures == 1 ? "" : "s")",
                detail: "\(row.failures) of \(row.count) calls did not succeed. Filter the Records tab by this operation to see the errors."
            )
        }
    }

    private static func slowNetwork(_ summary: LogSummaryResult) -> [LogFinding] {
        summary.rows.filter { $0.category == .network && $0.maxMs >= slowNetworkMs }.map { row in
            LogFinding(
                severity: .info,
                title: "\(row.operation) had a slow call",
                detail: "Slowest \(format(ms: row.maxMs)), average \(format(ms: row.averageMs)) over \(row.count) call\(row.count == 1 ? "" : "s")."
            )
        }
    }

    /// A disk cache that mostly misses is doing the work of a cache without
    /// any of the benefit — and it looks like an I/O problem from outside.
    private static func cacheEffectiveness(_ summary: LogSummaryResult) -> [LogFinding] {
        let hits = summary.rows.first { $0.operation == "cache.hit" }?.count ?? 0
        let misses = summary.rows.first { $0.operation == "cache.miss" }?.count ?? 0
        let total = hits + misses
        // Below this the ratio is noise — a fresh install misses everything
        // exactly once and that is correct behaviour, not a finding.
        guard total >= 50, misses > hits * 3 else { return [] }
        let rate = Double(hits) / Double(total) * 100
        return [LogFinding(
            severity: .info,
            title: "Disk cache is mostly missing",
            detail: "\(hits) hits against \(misses) misses (\(String(format: "%.0f", rate))% hit rate). Every miss falls through to git."
        )]
    }

    // MARK: - Formatting

    static func format(ms: Double) -> String {
        if ms >= 1000 { return String(format: "%.2f s", ms / 1000) }
        if ms >= 10 { return String(format: "%.0f ms", ms) }
        return String(format: "%.1f ms", ms)
    }

    static func format(minutes: Double) -> String {
        if minutes >= 60 { return String(format: "%.1f h", minutes / 60) }
        if minutes >= 1 { return String(format: "%.0f min", minutes) }
        return String(format: "%.0f s", minutes * 60)
    }
}
