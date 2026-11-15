import XCTest
@testable import SmallGit

/// The streaming path's contract: every line arrives, the last one arrives
/// even without its newline, and the exit code comes last. Nothing here
/// waits on a thread any more — the pipe's EOF and the process's exit are
/// counted and whichever lands last finishes the stream — so these guard
/// the case that ordering used to protect: output still in the pipe when
/// the process has already gone.
final class ProcessRunnerStreamTests: XCTestCase {

    private func collect(_ script: String) async throws -> (lines: [String], exit: Int32?) {
        var lines: [String] = []
        var code: Int32?
        for try await event in await ProcessRunner.shared.stream(
            executable: "/bin/sh", args: ["-c", script], cwd: nil
        ) {
            switch event {
            case .line(let l): lines.append(l)
            case .exit(let c): code = c
            }
        }
        return (lines, code)
    }

    func testLargeOutputAndUnterminatedTailSurvive() async throws {
        let (lines, code) = try await collect("seq 1 5000; printf 'tail-no-newline'")
        XCTAssertEqual(lines.count, 5001)
        XCTAssertEqual(lines.first, "1")
        XCTAssertEqual(lines[4999], "5000")
        XCTAssertEqual(lines.last, "tail-no-newline")
        XCTAssertEqual(code, 0)
    }

    func testEmptyOutputStillReportsExit() async throws {
        let (lines, code) = try await collect("exit 0")
        XCTAssertEqual(lines, [])
        XCTAssertEqual(code, 0)
    }

    func testNonZeroExitArrivesAfterOutput() async throws {
        let (lines, code) = try await collect("echo x; exit 3")
        XCTAssertEqual(lines, ["x"])
        XCTAssertEqual(code, 3)
    }

    func testRepeatedShortCommandsNeverTruncate() async throws {
        for _ in 0..<50 {
            let (lines, code) = try await collect("printf 'a\\nb\\n'")
            XCTAssertEqual(lines, ["a", "b"])
            XCTAssertEqual(code, 0)
        }
    }
}
