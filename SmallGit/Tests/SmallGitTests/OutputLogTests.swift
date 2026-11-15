import XCTest
@testable import SmallGit

/// Covers the Output panel's command journal.
///
/// The panel's whole job is to say what ran and how it went, so the property
/// that matters is that a finished entry stops describing itself as pending.
@MainActor
final class OutputLogTests: XCTestCase {

    private func result(
        command: String = "git -C /repo branch -d feat",
        exitCode: Int32 = 0,
        stdout: String = "Deleted branch feat (was 40802c3).\n",
        stderr: String = "",
        duration: TimeInterval = 0.042
    ) -> GitCommandResult {
        GitCommandResult(command: command, exitCode: exitCode,
                         stdout: stdout, stderr: stderr, duration: duration)
    }

    // MARK: - Finishing

    /// The reported bug: an entry opened without a known command kept showing
    /// its placeholder after the command had run and returned.
    func testFinishingFillsInTheCommandThatActuallyRan() throws {
        let log = OutputLog()
        let id = log.begin(action: "Delete feat", command: "")
        XCTAssertEqual(log.entries.first?.command, "")

        log.finish(id: id, result: result())

        let entry = try XCTUnwrap(log.entries.first)
        XCTAssertEqual(entry.command, "git -C /repo branch -d feat")
        XCTAssertEqual(entry.status, .success)
        XCTAssertTrue(entry.detail.contains("Deleted branch"))
    }

    /// A duration is the visible difference between "finished" and "still
    /// going" — a 6pt status dot is not enough on its own.
    func testFinishingRecordsHowLongItTook() throws {
        let log = OutputLog()
        let id = log.begin(action: "Delete feat", command: "")
        XCTAssertNil(log.entries.first?.duration, "nothing to report while running")

        log.finish(id: id, result: result(duration: 1.25))

        XCTAssertEqual(try XCTUnwrap(log.entries.first?.duration), 1.25, accuracy: 0.001)
    }

    /// A caller that already knew the command must keep it — the result's
    /// version is a fill-in, not an override for its own sake.
    func testAKnownCommandIsNotReplacedByAnEmptyOne() throws {
        let log = OutputLog()
        let id = log.begin(action: "File History", command: "git log --follow -- a.swift")

        log.finish(id: id, result: result(command: ""))

        XCTAssertEqual(try XCTUnwrap(log.entries.first).command, "git log --follow -- a.swift")
    }

    func testAFailedCommandIsMarkedFailedAndKeepsItsStderr() throws {
        let log = OutputLog()
        let id = log.begin(action: "Push", command: "")

        log.finish(id: id, result: result(
            command: "git -C /repo push", exitCode: 1,
            stdout: "", stderr: "fatal: rejected\n"
        ))

        let entry = try XCTUnwrap(log.entries.first)
        XCTAssertEqual(entry.status, .failure)
        XCTAssertTrue(entry.detail.contains("rejected"))
        XCTAssertNotNil(entry.duration, "a failure still took time and still finished")
    }

    /// Work that never produces a `GitCommandResult` — a guard that fails
    /// before anything runs — still has to leave the row finished.
    func testFinishingWithoutAResultStillLeavesTheRunningState() throws {
        let log = OutputLog()
        let id = log.begin(action: "Delete feat", command: "")

        log.finish(id: id, status: .failure, detail: "Repository folder is missing")

        let entry = try XCTUnwrap(log.entries.first)
        XCTAssertEqual(entry.status, .failure)
        XCTAssertNotEqual(entry.status, .running)
    }

    // MARK: - Bookkeeping

    func testAnUnfinishedEntryStaysRunning() throws {
        let log = OutputLog()
        _ = log.begin(action: "Fetch", command: "")
        let entry = try XCTUnwrap(log.entries.first)
        XCTAssertEqual(entry.status, .running)
        XCTAssertNil(entry.duration)
    }

    /// Finishing an id that isn't there must not disturb the others — an
    /// operation can be superseded while in flight.
    func testFinishingAnUnknownIDIsIgnored() {
        let log = OutputLog()
        let id = log.begin(action: "Fetch", command: "")
        log.finish(id: UUID(), result: result())

        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.id, id)
        XCTAssertEqual(log.entries.first?.status, .running)
    }

    func testEntriesAreCappedOldestFirst() {
        let log = OutputLog()
        log.maxEntries = 3
        for i in 0..<5 { _ = log.begin(action: "op-\(i)", command: "") }

        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries.map(\.action), ["op-2", "op-3", "op-4"])
    }

    func testClearEmptiesTheJournal() {
        let log = OutputLog()
        _ = log.begin(action: "Fetch", command: "")
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }
}
