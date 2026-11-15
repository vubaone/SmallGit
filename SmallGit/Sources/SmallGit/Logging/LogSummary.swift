import Foundation

/// One operation's totals across the log.
struct LogSummaryRow: Identifiable, Hashable, Sendable {
    var id: String { "\(category.rawValue)/\(operation)" }

    let category: LogCategory
    let operation: String
    let count: Int
    let failures: Int
    let totalMs: Double
    let averageMs: Double
    let maxMs: Double
    let bytes: Int
    /// Calls per minute over the log's window, or `nil` when the window is
    /// too short to extrapolate from honestly.
    let perMinute: Double?
}

/// Aggregated view of the log.
struct LogSummaryResult: Sendable {
    let rows: [LogSummaryRow]
    let start: Date?
    let end: Date?
    /// First record to last, idle time included.
    let windowSeconds: TimeInterval
    /// Time the app was actually doing something, with the gaps between
    /// sessions removed. This is the denominator for every rate.
    let activeSeconds: TimeInterval
    /// Runs of activity separated by an idle gap — roughly "how many times
    /// was the app used" across the retained log.
    let sessionCount: Int
    let recordCount: Int
    let failureCount: Int

    static let empty = LogSummaryResult(
        rows: [], start: nil, end: nil, windowSeconds: 0, activeSeconds: 0,
        sessionCount: 0, recordCount: 0, failureCount: 0
    )
}

/// Rolls the raw log up per operation.
///
/// This exists because the two bug shapes a diagnostic log has to catch look
/// nothing alike in the raw stream:
///
/// - **Something is slow.** Visible in one record, if you happen to scroll
///   past it. `maxMs` and `totalMs` find it without the scrolling.
/// - **Something runs far too often.** Invisible in every individual record —
///   each one is fast and successful — and obvious the moment you see that
///   `git status` ran 900 times in four idle minutes. That is what
///   `perMinute` is for, and it is the shape of the feedback-loop bug this
///   app has already had once.
enum LogSummary {

    /// Below this the window is too short to turn a handful of calls into a
    /// per-minute figure anyone should act on — three calls in two seconds is
    /// not "90 per minute", it is three calls.
    private static let minimumWindowSeconds: TimeInterval = 10

    /// A quiet stretch longer than this is the app sitting closed or idle,
    /// not the app working slowly. Anything shorter is ordinary think-time
    /// between two clicks and stays inside the session.
    static let idleGapSeconds: TimeInterval = 60

    static func summarize(_ records: [LogRecord]) -> LogSummaryResult {
        guard !records.isEmpty else { return .empty }

        // Not `first`/`last`: rotation can splice generations together and a
        // clock change can reorder timestamps, neither of which should make
        // the window come out negative.
        let timestamps = records.map(\.at).sorted()
        let start = timestamps.first
        let end = timestamps.last
        let window = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : 0
        let activity = activeTime(of: timestamps)

        var buckets: [String: Bucket] = [:]
        for record in records {
            let key = "\(record.category.rawValue)/\(record.operation)"
            buckets[key, default: Bucket(category: record.category, operation: record.operation)]
                .add(record)
        }

        let rows = buckets.values
            .map { $0.row(windowSeconds: activity.seconds) }
            .sorted { left, right in
                if left.totalMs != right.totalMs { return left.totalMs > right.totalMs }
                return left.count > right.count
            }

        return LogSummaryResult(
            rows: rows,
            start: start,
            end: end,
            windowSeconds: window,
            activeSeconds: activity.seconds,
            sessionCount: activity.sessions,
            recordCount: records.count,
            failureCount: records.count { $0.outcome.isFailure }
        )
    }

    /// Total time the app was actually working, and how many separate runs
    /// of activity that was.
    ///
    /// Rates are computed against this rather than against first-to-last,
    /// because the log survives across launches and the gap between two
    /// sessions is not time the app spent doing anything. Measured on a real
    /// log: two sessions totalling 141 seconds of work, nine hours apart,
    /// made a `git rev-parse` storm running at 123/min read as 0.5/min —
    /// comfortably under every threshold, so the one real finding in the file
    /// was reported as nothing at all.
    static func activeTime(of sortedTimestamps: [Date]) -> (seconds: TimeInterval, sessions: Int) {
        guard let first = sortedTimestamps.first else { return (0, 0) }
        var total: TimeInterval = 0
        var sessions = 1
        var sessionStart = first
        var previous = first

        for timestamp in sortedTimestamps.dropFirst() {
            if timestamp.timeIntervalSince(previous) > idleGapSeconds {
                total += previous.timeIntervalSince(sessionStart)
                sessions += 1
                sessionStart = timestamp
            }
            previous = timestamp
        }
        total += previous.timeIntervalSince(sessionStart)
        return (total, sessions)
    }

    /// The individual slowest calls — the ones worth looking at directly once
    /// the summary has said which operation to suspect.
    static func slowest(_ records: [LogRecord], limit: Int = 25) -> [LogRecord] {
        records
            .filter { ($0.ms ?? 0) > 0 }
            .sorted { ($0.ms ?? 0) > ($1.ms ?? 0) }
            .prefix(limit)
            .map { $0 }
    }

    private struct Bucket {
        let category: LogCategory
        let operation: String
        var count = 0
        var failures = 0
        var totalMs: Double = 0
        var maxMs: Double = 0
        var bytes = 0

        mutating func add(_ record: LogRecord) {
            count += 1
            if record.outcome.isFailure { failures += 1 }
            if let ms = record.ms {
                totalMs += ms
                maxMs = Swift.max(maxMs, ms)
            }
            bytes += record.bytes ?? 0
        }

        func row(windowSeconds: TimeInterval) -> LogSummaryRow {
            LogSummaryRow(
                category: category,
                operation: operation,
                count: count,
                failures: failures,
                totalMs: totalMs,
                averageMs: count > 0 ? totalMs / Double(count) : 0,
                maxMs: maxMs,
                bytes: bytes,
                perMinute: windowSeconds >= minimumWindowSeconds
                    ? Double(count) / (windowSeconds / 60)
                    : nil
            )
        }
    }
}
