import XCTest
@testable import SmallGit

/// Covers the roll-up and the findings drawn from it.
///
/// The findings are the part that has to be right in both directions. A rule
/// that misses the polling loop is useless; a rule that reports one on every
/// ordinary session is worse, because then the real finding arrives in a list
/// the user has already learned to ignore.
final class LogSummaryTests: XCTestCase {

    /// Shared time base. Mixing this with `Date()` in one test stretches the
    /// observed window to years and silently disables every rate-based rule.
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        _ operation: String,
        category: LogCategory = .git,
        at: Date,
        ms: Double? = nil,
        bytes: Int? = nil,
        outcome: LogOutcome = .ok
    ) -> LogRecord {
        LogRecord(at: at, category: category, operation: operation,
                  ms: ms, bytes: bytes, outcome: outcome)
    }

    /// Spreads `count` records evenly across `seconds`, which is what makes
    /// the per-minute arithmetic meaningful.
    private func spread(
        _ operation: String,
        category: LogCategory = .git,
        count: Int,
        overSeconds seconds: TimeInterval,
        ms: Double? = 5,
        outcome: LogOutcome = .ok
    ) -> [LogRecord] {
        let step = count > 1 ? seconds / Double(count - 1) : 0
        return (0..<count).map { i in
            record(operation, category: category,
                   at: base.addingTimeInterval(step * Double(i)),
                   ms: ms, outcome: outcome)
        }
    }

    // MARK: - Aggregation

    func testTotalsAreAccumulatedPerOperation() throws {
        let start = Date()
        let records = [
            record("git status", at: start, ms: 10, bytes: 100),
            record("git status", at: start.addingTimeInterval(1), ms: 30, bytes: 200),
            record("git log", at: start.addingTimeInterval(2), ms: 500, bytes: 900)
        ]
        let summary = LogSummary.summarize(records)

        let status = try XCTUnwrap(summary.rows.first { $0.operation == "git status" })
        XCTAssertEqual(status.count, 2)
        XCTAssertEqual(status.totalMs, 40)
        XCTAssertEqual(status.averageMs, 20)
        XCTAssertEqual(status.maxMs, 30)
        XCTAssertEqual(status.bytes, 300)
        XCTAssertEqual(summary.recordCount, 3)
    }

    /// Sorted by where the time went, because that is the default question.
    func testRowsAreSortedByTotalTime() {
        let start = Date()
        let summary = LogSummary.summarize([
            record("fast", at: start, ms: 1),
            record("slow", at: start, ms: 900),
            record("medium", at: start, ms: 100)
        ])
        XCTAssertEqual(summary.rows.map(\.operation), ["slow", "medium", "fast"])
    }

    func testFailuresAreCountedSeparatelyFromCalls() {
        let start = Date()
        let summary = LogSummary.summarize([
            record("git push", at: start, ms: 10),
            record("git push", at: start, ms: 10, outcome: .failed),
            record("git push", at: start, ms: 10, outcome: .timedOut)
        ])
        XCTAssertEqual(summary.rows.first?.count, 3)
        XCTAssertEqual(summary.rows.first?.failures, 2)
        XCTAssertEqual(summary.failureCount, 2)
    }

    /// Same operation name from different categories stays separate — a
    /// `git fetch` filed under network is not the same row as one that
    /// somehow arrived as local.
    func testCategoryIsPartOfTheGrouping() {
        let start = Date()
        let summary = LogSummary.summarize([
            record("git fetch", category: .network, at: start, ms: 10),
            record("git fetch", category: .git, at: start, ms: 10)
        ])
        XCTAssertEqual(summary.rows.count, 2)
    }

    /// Watcher batches carry no duration; they must still be counted rather
    /// than dropped for having no `ms`.
    func testRecordsWithNoDurationStillCount() {
        let summary = LogSummary.summarize(
            spread("fsevents.batch", category: .watcher, count: 5, overSeconds: 60, ms: nil)
        )
        XCTAssertEqual(summary.rows.first?.count, 5)
        XCTAssertEqual(summary.rows.first?.totalMs, 0)
        XCTAssertEqual(summary.rows.first?.maxMs, 0)
    }

    func testEmptyInputSummarisesToNothing() {
        let summary = LogSummary.summarize([])
        XCTAssertTrue(summary.rows.isEmpty)
        XCTAssertEqual(summary.recordCount, 0)
        XCTAssertNil(summary.start)
    }

    // MARK: - Rates

    func testPerMinuteIsComputedOverTheObservedWindow() throws {
        let summary = LogSummary.summarize(spread("git status", count: 121, overSeconds: 120))
        let rate = try XCTUnwrap(summary.rows.first?.perMinute)
        XCTAssertEqual(rate, 60.5, accuracy: 0.5)
    }

    /// Three calls in two seconds is three calls, not "90 per minute".
    /// Extrapolating from a window that short invents a number.
    func testAShortWindowReportsNoRateAtAll() {
        let summary = LogSummary.summarize(spread("git status", count: 3, overSeconds: 2))
        XCTAssertNil(summary.rows.first?.perMinute)
    }

    // MARK: - Findings

    /// The bug shape this whole feature exists to catch: every call is fast
    /// and successful, and the problem is only visible in how many there are.
    func testASustainedPollingLoopIsReported() {
        let summary = LogSummary.summarize(
            spread("git status", count: 600, overSeconds: 300, ms: 8)
        )
        let findings = LogDiagnosis.findings(summary)

        let busy = findings.first { $0.title.contains("git status") }
        XCTAssertNotNil(busy, "120 calls a minute for five minutes is a loop")
        XCTAssertEqual(busy?.severity, .warning)
        XCTAssertTrue(busy?.detail.contains("600 calls") == true,
                      "the finding must say what it measured")
    }

    /// A watcher firing continuously means the app's own writes are landing
    /// in the directory it watches — a different bug from a poll loop, and
    /// worth saying so.
    func testAContinuouslyFiringWatcherIsCalledOutAsSuch() {
        let summary = LogSummary.summarize(
            spread("fsevents.batch", category: .watcher, count: 400, overSeconds: 200, ms: nil)
        )
        let finding = LogDiagnosis.findings(summary).first { $0.title.contains("watcher") }
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.detail.contains("own writes") == true)
    }

    /// The false-positive guard. Ordinary interactive use — a burst of git
    /// while the user clicks around — must not be reported as a loop.
    func testOrdinaryInteractiveUseProducesNoFindings() {
        var records = spread("git status", count: 20, overSeconds: 300, ms: 15)
        records += spread("git log", count: 10, overSeconds: 300, ms: 120)
        records += spread("git diff", count: 30, overSeconds: 300, ms: 40)
        records += spread("cache.hit", category: .disk, count: 60, overSeconds: 300, ms: 2)

        XCTAssertTrue(LogDiagnosis.findings(LogSummary.summarize(records)).isEmpty)
    }

    /// A short session can't be judged on rate, so it must not be.
    func testAShortSessionIsNotJudgedOnRate() {
        let summary = LogSummary.summarize(spread("git status", count: 50, overSeconds: 5))
        XCTAssertTrue(LogDiagnosis.findings(summary).isEmpty)
    }

    func testFailuresAreAlwaysReported() {
        let start = Date()
        let summary = LogSummary.summarize([
            record("git push", category: .network, at: start, ms: 200, outcome: .failed)
        ])
        let finding = LogDiagnosis.findings(summary).first
        XCTAssertEqual(finding?.severity, .warning)
        XCTAssertTrue(finding?.title.contains("git push failed") == true)
    }

    func testASlowRemoteCallIsInformationalNotAWarning() throws {
        let start = Date()
        let summary = LogSummary.summarize([
            record("git fetch", category: .network, at: start, ms: 9_000)
        ])
        let finding = try XCTUnwrap(LogDiagnosis.findings(summary).first)
        XCTAssertEqual(finding.severity, .info)
        XCTAssertTrue(finding.title.contains("slow call"))
    }

    /// A cache that mostly misses looks like an I/O problem from outside but
    /// isn't one — worth separating.
    func testAMostlyMissingCacheIsReported() {
        var records = spread("cache.miss", category: .disk, count: 80, overSeconds: 300, ms: 1)
        records += spread("cache.hit", category: .disk, count: 10, overSeconds: 300, ms: 1)
        let finding = LogDiagnosis.findings(LogSummary.summarize(records))
            .first { $0.title.contains("cache") }
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.detail.contains("hit rate") == true)
    }

    /// A fresh install misses every key exactly once. That is correct
    /// behaviour, and reporting it would train the user to ignore findings.
    func testAColdCacheIsNotReportedAsAProblem() {
        let records = spread("cache.miss", category: .disk, count: 12, overSeconds: 300, ms: 1)
        XCTAssertTrue(
            LogDiagnosis.findings(LogSummary.summarize(records))
                .filter { $0.title.contains("cache") }
                .isEmpty
        )
    }

    func testWarningsSortAboveInformation() {
        var records = spread("git status", count: 600, overSeconds: 300, ms: 8)
        records.append(record("git fetch", category: .network, at: base, ms: 9_000))
        let findings = LogDiagnosis.findings(LogSummary.summarize(records))
        XCTAssertEqual(findings.first?.severity, .warning)
    }

    // MARK: - Dominant cost

    /// The real-log case the rate rule missed: bursty work that averages out
    /// below any threshold while still being most of what the app did.
    func testAnOperationDominatingTotalTimeIsReported() {
        var records = spread("git rev-parse", count: 380, overSeconds: 900, ms: 62)
        records += spread("git status", count: 20, overSeconds: 900, ms: 400)

        let finding = LogDiagnosis.findings(LogSummary.summarize(records))
            .first { $0.title.contains("rev-parse") }
        XCTAssertNotNil(finding, "50% of all time must surface even at 25/min")
        XCTAssertEqual(finding?.severity, .info, "expensive is not the same as broken")
        XCTAssertTrue(finding?.detail.contains("%") == true)
    }

    /// The guard that keeps this rule usable: in any quiet session something
    /// is the biggest cost, and saying so on every log is noise.
    func testTheBiggestCostInAnOrdinarySessionIsNotReported() {
        var records = spread("git diff", count: 30, overSeconds: 900, ms: 40)
        records += spread("git status", count: 20, overSeconds: 900, ms: 15)
        records += spread("git log", count: 10, overSeconds: 900, ms: 120)

        XCTAssertTrue(
            LogDiagnosis.findings(LogSummary.summarize(records))
                .filter { $0.title.contains("where the time goes") }
                .isEmpty,
            "git diff is 40% of this session and that is simply normal"
        )
    }

    /// One slow command is not a systemic cost, and saying so would make the
    /// rule fire on every log that contains a single `git clone`.
    func testASingleSlowCommandIsNotCalledDominant() {
        var records = spread("git clone", category: .network, count: 1, overSeconds: 1, ms: 30_000)
        records += spread("git status", count: 40, overSeconds: 900, ms: 20)

        XCTAssertTrue(
            LogDiagnosis.findings(LogSummary.summarize(records))
                .filter { $0.title.contains("where the time goes") }
                .isEmpty
        )
    }

    // MARK: - Active time

    /// The defect the first real log exposed. The file survives across
    /// launches, so a rate measured first-to-last is divided by every hour the
    /// app spent closed — and a genuine storm reads as nothing.
    func testIdleGapsBetweenSessionsDoNotDiluteRates() {
        // Two 60-second bursts, nine hours apart. Judged on wall-clock the
        // rate is under 1/min; judged on activity it is over 100.
        var records = spread("git rev-parse", count: 110, overSeconds: 60)
        let later = base.addingTimeInterval(9 * 3600)
        records += (0..<110).map { i in
            record("git rev-parse", at: later.addingTimeInterval(Double(i) * 60 / 109), ms: 5)
        }

        let summary = LogSummary.summarize(records)
        XCTAssertEqual(summary.sessionCount, 2)
        XCTAssertEqual(summary.activeSeconds, 120, accuracy: 1)
        XCTAssertGreaterThan(summary.windowSeconds, 9 * 3600, "the wall span still spans the gap")

        let rate = summary.rows.first?.perMinute ?? 0
        XCTAssertEqual(rate, 110, accuracy: 5, "220 calls in 120 s of activity")
        XCTAssertFalse(LogDiagnosis.findings(summary).isEmpty,
                       "a storm split across two launches must still be found")
    }

    /// Think-time between two clicks is not the end of a session.
    func testShortPausesStayInsideOneSession() {
        let records = (0..<10).map { i in
            record("git status", at: base.addingTimeInterval(Double(i) * 30), ms: 5)
        }
        let summary = LogSummary.summarize(records)
        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(summary.activeSeconds, 270, accuracy: 1)
    }

    func testActiveTimeOfASingleRecordIsZeroNotNegative() {
        let summary = LogSummary.summarize([record("git status", at: base, ms: 5)])
        XCTAssertEqual(summary.activeSeconds, 0)
        XCTAssertEqual(summary.sessionCount, 1)
    }

    // MARK: - Slowest

    func testSlowestReturnsTheLongestCallsFirst() {
        let start = Date()
        let slowest = LogSummary.slowest([
            record("a", at: start, ms: 10),
            record("b", at: start, ms: 900),
            record("c", at: start, ms: nil),
            record("d", at: start, ms: 400)
        ])
        XCTAssertEqual(slowest.map(\.operation), ["b", "d", "a"])
    }
}
