import XCTest
@testable import SmallGit

/// Covers the diagnostic log's storage.
///
/// The properties that matter are the ones a logger is trusted on and rarely
/// checked for: that it stays inside its size budget however hard it is
/// pushed, that rotation keeps history rather than discarding it, and that a
/// half-written file still reads.
final class LogStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogStoreTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(maxTotalBytes: Int = 64 * 1024) -> LogStore {
        LogStore(
            directory: directory,
            maxTotalBytes: maxTotalBytes,
            // Long interval + huge threshold: these tests drive flushing
            // explicitly, so nothing lands on a timer mid-assertion.
            flushInterval: 3600,
            flushThreshold: .max
        )
    }

    private func record(_ operation: String, ms: Double? = nil, outcome: LogOutcome = .ok) -> LogRecord {
        LogRecord(category: .git, operation: operation, detail: "detail", ms: ms, outcome: outcome)
    }

    // MARK: - Not the user's log

    /// The instrumentation is in `ProcessRunner` and `DiskCache`, which the
    /// integration suites drive for real — so without this the whole test run
    /// dumps its `/var/folders` fixtures into the user's diagnostics log. It
    /// did, once: 1,601 records from a single `swift test`.
    func testTheSharedStoreDoesNotUseTheRealLogDirectoryUnderTests() {
        XCTAssertTrue(LogStore.isRunningTests)
        XCTAssertFalse(
            LogStore.shared.currentURL.path.contains("Library/Logs/SmallGit"),
            "a test run must never write to ~/Library/Logs/SmallGit"
        )
    }

    // MARK: - Round trip

    func testRecordsSurviveAWriteAndReadCycle() {
        let store = makeStore()
        store.record(record("git status", ms: 12))
        store.record(record("git fetch", ms: 800, outcome: .failed))

        let read = store.read()
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read.first?.operation, "git status")
        XCTAssertEqual(read.last?.outcome, .failed)
        XCTAssertEqual(read.last?.ms, 800)
    }

    /// Reading has to flush first, or the records the user just went looking
    /// for — the ones from the last second — are the exact ones missing.
    func testReadSeesRecordsStillSittingInTheBuffer() {
        let store = makeStore()
        store.record(record("git log"))
        XCTAssertEqual(store.totalSizeBytes, 0, "nothing written yet")
        XCTAssertEqual(store.read().count, 1)
        XCTAssertGreaterThan(store.totalSizeBytes, 0)
    }

    func testRecordsAreOrderedOldestFirst() {
        let store = makeStore()
        for i in 0..<20 { store.record(record("op-\(i)")) }
        let read = store.read()
        XCTAssertEqual(read.first?.operation, "op-0")
        XCTAssertEqual(read.last?.operation, "op-19")
    }

    // MARK: - The size cap

    /// The headline promise. Pushed with far more than the budget, the log
    /// must still fit inside it.
    func testTotalSizeNeverExceedsTheCap() {
        let cap = 16 * 1024
        let store = makeStore(maxTotalBytes: cap)
        for i in 0..<4000 {
            store.record(record("git status", ms: Double(i)))
            if i % 200 == 0 { store.flushNow() }
        }
        store.flushNow()

        XCTAssertLessThanOrEqual(store.totalSizeBytes, cap)
        XCTAssertGreaterThan(store.totalSizeBytes, 0, "it must keep something, not just stay empty")
    }

    /// Rotation keeps the previous generation rather than deleting it, so
    /// there is always history — the alternative throws everything away at
    /// the moment the file fills, which is exactly when it mattered.
    func testRotationPreservesThePreviousGeneration() {
        let store = makeStore(maxTotalBytes: 8 * 1024)
        for i in 0..<2000 {
            store.record(record("op-\(i)"))
            if i % 100 == 0 { store.flushNow() }
        }
        store.flushNow()

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.previousURL.path),
                      "a rotation must have happened at this volume")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.currentURL.path))
        XCTAssertGreaterThan(store.read().count, 0)
    }

    /// Both generations are read, previous first, so the sequence stays in
    /// order across the seam.
    func testReadingSpansBothGenerationsInOrder() {
        let store = makeStore(maxTotalBytes: 8 * 1024)
        for i in 0..<1500 {
            store.record(record("op-\(String(format: "%05d", i))"))
            if i % 100 == 0 { store.flushNow() }
        }
        store.flushNow()

        let operations = store.read().map(\.operation)
        XCTAssertEqual(operations, operations.sorted(), "records must not be interleaved out of order")
    }

    /// A single flush larger than one generation would otherwise land whole
    /// and blow the cap, since rotation only moves what is already on disk.
    func testAnOversizedBatchIsTrimmedRatherThanBlowingTheCap() {
        let cap = 4 * 1024
        let store = makeStore(maxTotalBytes: cap)
        for i in 0..<500 { store.record(record("op-\(i)")) }
        store.flushNow()

        XCTAssertLessThanOrEqual(store.totalSizeBytes, cap)
        let read = store.read()
        XCTAssertFalse(read.isEmpty)
        XCTAssertEqual(read.last?.operation, "op-499", "trimming drops the oldest, keeps the newest")
    }

    func testTrimmingCutsOnLineBoundaries() {
        let data = Data("aaaa\nbbbb\ncccc\n".utf8)
        let trimmed = LogStore.trimmingLeadingLines(data, to: 10)
        XCTAssertEqual(String(decoding: trimmed, as: UTF8.self), "bbbb\ncccc\n")
    }

    // MARK: - Robustness

    /// A process killed mid-write leaves a partial final line. That must cost
    /// one record, not the file.
    func testATornFinalLineDoesNotCostTheWholeLog() throws {
        let store = makeStore()
        store.record(record("git status"))
        store.record(record("git log"))
        store.flushNow()

        var raw = try Data(contentsOf: store.currentURL)
        raw.append(Data(#"{"at":"2026-08-16T01:00:00Z","cat":"git","op":"git fe"#.utf8))
        try raw.write(to: store.currentURL)

        let read = store.read()
        XCTAssertEqual(read.count, 2, "the two intact records must still be readable")
    }

    func testDisablingStopsRecordingAndDropsWhatWasBuffered() {
        let store = makeStore()
        store.record(record("git status"))
        store.setEnabled(false)
        store.record(record("git fetch"))

        XCTAssertFalse(store.isEnabled)
        XCTAssertTrue(store.read().isEmpty, "the buffered record is dropped along with the new one")
    }

    func testReenablingResumesRecording() {
        let store = makeStore()
        store.setEnabled(false)
        store.record(record("dropped"))
        store.setEnabled(true)
        store.record(record("kept"))

        XCTAssertEqual(store.read().map(\.operation), ["kept"])
    }

    func testClearRemovesBothGenerations() {
        let store = makeStore(maxTotalBytes: 8 * 1024)
        for i in 0..<1500 {
            store.record(record("op-\(i)"))
            if i % 100 == 0 { store.flushNow() }
        }
        store.flushNow()
        XCTAssertGreaterThan(store.totalSizeBytes, 0)

        store.clear()

        XCTAssertEqual(store.totalSizeBytes, 0)
        XCTAssertTrue(store.read().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.previousURL.path))
    }

    func testReadingAnAbsentLogIsEmptyRatherThanAnError() {
        XCTAssertTrue(makeStore().read().isEmpty)
    }

    func testReadHonoursItsLimit() {
        let store = makeStore()
        for i in 0..<100 { store.record(record("op-\(i)")) }
        let read = store.read(limit: 10)
        XCTAssertEqual(read.count, 10)
        XCTAssertEqual(read.last?.operation, "op-99", "the limit keeps the newest")
    }

    /// Records arrive from two actors, a `nonisolated` config write, the
    /// FSEvents queue and the main actor. Concurrent `record` calls must not
    /// lose or corrupt anything.
    func testConcurrentRecordingLosesNothing() {
        let store = makeStore(maxTotalBytes: 1024 * 1024)
        let writers = 8
        let each = 100

        DispatchQueue.concurrentPerform(iterations: writers) { writer in
            for i in 0..<each {
                store.record(self.record("writer-\(writer)-\(i)"))
            }
        }
        store.flushNow()

        XCTAssertEqual(store.read().count, writers * each)
    }
}
