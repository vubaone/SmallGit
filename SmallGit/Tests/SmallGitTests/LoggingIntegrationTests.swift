import XCTest
@testable import SmallGit

/// End-to-end: does the instrumentation actually fire?
///
/// The unit tests prove the classifier and the store are correct in
/// isolation, which is worth nothing if `ProcessRunner` never calls them. A
/// logging feature fails silently by construction — an empty log looks
/// exactly like a quiet app — so this drives real `git` through the real code
/// path and checks that records come out the other end.
final class LoggingIntegrationTests: XCTestCase {

    private var directory: URL!
    private var store: LogStore!
    private var repo: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                          "git not available")

        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LoggingIntegration-\(UUID().uuidString)")
        store = LogStore(directory: directory, flushInterval: 3600, flushThreshold: .max)
        // Redirected so the suite never writes into the user's real
        // diagnostics log.
        Log.store = store

        repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LoggingRepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init"])
    }

    override func tearDownWithError() throws {
        Log.store = .shared
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: repo)
    }

    /// Plain `Process`, not `ProcessRunner` — used only to set the fixture up,
    /// so it stays out of the log we are about to assert on.
    private func runGit(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    // MARK: - ProcessRunner

    func testALocalGitCommandIsRecordedAsGitNotNetwork() async throws {
        _ = try await ProcessRunner.shared.run(in: repo.path, args: ["status", "--porcelain"])

        let record = try XCTUnwrap(store.read().first { $0.operation == "git status" })
        XCTAssertEqual(record.category, .git)
        XCTAssertEqual(record.outcome, .ok)
        XCTAssertNotNil(record.ms)
        XCTAssertGreaterThan(record.ms ?? 0, 0, "a real subprocess takes measurable time")
        XCTAssertNotNil(record.bytes)
    }

    /// The classification has to survive the real argument vector, `-C` prefix
    /// and all — this is the one thing the unit test has to assume.
    func testARemoteCommandIsRecordedAsNetwork() async throws {
        // Fails (there is no remote) but still goes out over the network path,
        // which is exactly the classification being checked.
        _ = try? await ProcessRunner.shared.run(
            in: repo.path, args: ["ls-remote", "--exit-code", "origin"], timeout: 20
        )

        let record = try XCTUnwrap(store.read().first { $0.operation == "git ls-remote" })
        XCTAssertEqual(record.category, .network)
    }

    /// A non-zero exit is the ordinary way git reports a problem, and it must
    /// not be logged as a success.
    func testAFailingCommandIsRecordedAsAFailureWithItsError() async throws {
        _ = try? await ProcessRunner.shared.run(in: repo.path, args: ["cat-file", "-p", "deadbeef"])

        let record = try XCTUnwrap(store.read().first { $0.operation == "git cat-file" })
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertNotNil(record.message, "the first line of stderr is what makes this diagnosable")
    }

    /// Timeouts never produce a `GitCommandResult`, so they are invisible
    /// unless the throwing path logs them too — and a hung git is precisely
    /// the bug worth catching.
    ///
    /// Driven by a stand-in `git` that sleeps rather than by a real command
    /// that happens to be slow: every genuinely slow git operation is slow for
    /// environmental reasons, and a timeout test that races the machine is a
    /// test that fails on someone else's.
    func testATimeoutIsRecordedRatherThanVanishing() async throws {
        let slowGit = directory.appendingPathComponent("slow-git")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "#!/bin/sh\nsleep 30\n".write(to: slowGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowGit.path)

        await ProcessRunner.shared.setGitPath(slowGit.path)
        defer { Task { await ProcessRunner.shared.setGitPath(nil) } }

        _ = try? await ProcessRunner.shared.run(in: repo.path, args: ["status"], timeout: 0.4)

        let record = try XCTUnwrap(store.read().first { $0.operation == "git status" })
        XCTAssertEqual(record.outcome, .timedOut)
        XCTAssertNotNil(record.ms, "a timeout still took time, and how long matters")
    }

    /// Repository paths land in the log, and a real one sits under the user's
    /// home. Nothing should reach the file unscrubbed.
    func testRecordedCommandsAreScrubbed() async throws {
        _ = try await ProcessRunner.shared.run(in: repo.path, args: ["status"])
        // Asserting on the file itself, not on `read()`: scrubbing that only
        // happened on the way out of the viewer would leave the secret on disk.
        store.flushNow()

        let raw = try Data(contentsOf: store.currentURL)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains(NSHomeDirectory()),
                       "the home directory must be abbreviated before it is written")
    }

    // MARK: - DiskCache

    func testDiskCacheHitsAndMissesAreRecordedSeparately() async throws {
        let cacheDirectory = directory.appendingPathComponent("cache")
        let cache = DiskCache()
        let key = CacheKey.fileStatus
        let path = cacheDirectory.path

        _ = await cache.load(key: key, repoPath: path, as: [String].self)
        await cache.save(key: key, repoPath: path, entry: CacheEntry(value: ["a"], gitRef: nil))
        _ = await cache.load(key: key, repoPath: path, as: [String].self)

        let operations = store.read().map(\.operation)
        XCTAssertTrue(operations.contains("cache.miss"))
        XCTAssertTrue(operations.contains("cache.save"))
        XCTAssertTrue(operations.contains("cache.hit"))

        await cache.removeAll(repoPath: path)
    }

    // MARK: - The switch

    /// Turning it off has to actually stop the instrumentation, not merely
    /// hide it in the viewer.
    func testDisablingStopsTheInstrumentationAtSource() async throws {
        store.setEnabled(false)
        _ = try await ProcessRunner.shared.run(in: repo.path, args: ["status"])
        XCTAssertTrue(store.read().isEmpty)
    }
}
