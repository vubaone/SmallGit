import XCTest
@testable import SmallGit

final class FileWatcherServiceTests: XCTestCase {

    func testFiresOnWorkingTreeChange() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-fwtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let watcher = FileWatcherService(latency: 0.05)
        let expectation = expectation(description: "FSEvents fires")
        let receivedPaths = PathBox()

        watcher.start(directories: [tmp.path]) { paths in
            receivedPaths.append(paths)
            expectation.fulfill()
        }

        // Give FSEvents a beat to install.
        try await Task.sleep(nanoseconds: 200_000_000)

        let target = tmp.appendingPathComponent("test.txt")
        try "hello".data(using: .utf8)!.write(to: target)

        await fulfillment(of: [expectation], timeout: 3.0)
        watcher.stop()

        let all = receivedPaths.snapshot()
        // FSEvents resolves /var to /private/var and may report either the
        // changed file or its containing directory — both are sufficient
        // for our InvalidationEngine, which only needs to know *something*
        // under the watched root changed.
        let tail = (tmp.lastPathComponent as String)
        XCTAssertTrue(
            all.contains { $0.contains(tail) },
            "Expected event referencing \(tail), got: \(all)"
        )
    }
}

private final class PathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func append(_ batch: [String]) {
        lock.lock(); defer { lock.unlock() }
        paths.append(contentsOf: batch)
    }
    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }
}
