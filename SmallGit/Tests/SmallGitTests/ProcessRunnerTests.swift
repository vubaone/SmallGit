import XCTest
@testable import SmallGit

final class ProcessRunnerTests: XCTestCase {

    func testRunTimesOutLongRunningProcess() async throws {
        let sleepPath = "/bin/sleep"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: sleepPath))
        let runner = ProcessRunner(gitPath: sleepPath)

        do {
            _ = try await runner.run(in: nil, args: ["5"], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch ProcessError.timedOut {
            // Expected.
        } catch {
            XCTFail("Expected timeout, got \(error)")
        }
    }

    // MARK: - Descriptors

    /// Every descriptor this process holds open. Cheap enough at these
    /// limits, and it counts the pipes a `Process` leaves behind — which is
    /// the thing under test.
    private func openFDCount() -> Int {
        var limits = rlimit()
        getrlimit(RLIMIT_NOFILE, &limits)
        let ceiling = Int32(min(Int(limits.rlim_cur), 20_000))
        var count = 0
        for fd in 0..<ceiling where fcntl(fd, F_GETFD) != -1 { count += 1 }
        return count
    }

    /// A command that finishes in milliseconds used to hold its two pipe
    /// read ends for the whole timeout — 120 seconds by default — because
    /// the watchdog task guarding it kept the `Process` alive. A refresh
    /// across a sidebar full of repositories runs one command per repo, so
    /// the app ran out of descriptors mid-session; after that every spawn
    /// failed and every repository read as "Not a Repo" until relaunch.
    func testFinishedCommandsReleaseTheirPipes() async throws {
        let echoPath = "/bin/echo"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: echoPath))
        let runner = ProcessRunner(gitPath: echoPath)

        _ = try? await runner.run(in: nil, args: ["warm-up"])
        try? await Task.sleep(nanoseconds: 200_000_000)

        let before = openFDCount()
        for _ in 0..<20 {
            _ = try? await runner.run(in: nil, args: ["hello"], timeout: 120)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let after = openFDCount()

        XCTAssertLessThanOrEqual(
            after - before,
            4,
            "20 finished commands left \(after - before) descriptors open"
        )
    }

    // MARK: - PATH augmentation
    //
    // A Finder-launched `.app` inherits only the bare macOS PATH, so the
    // hooks git spawns (e.g. LFS's `post-checkout`, which does
    // `command -v git-lfs || exit 2`) can't find their tools.

    func testAugmentedPathAppendsPackageManagerDirs() {
        let result = ProcessRunner.augmentedPath("/usr/bin:/bin")
        XCTAssertEqual(result, "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin")
    }

    func testAugmentedPathDoesNotDuplicateExistingEntries() {
        // /usr/local/bin is already present — and must keep its original
        // position, so a user's ordering still wins over ours.
        let result = ProcessRunner.augmentedPath("/usr/local/bin:/usr/bin")
        XCTAssertEqual(result, "/usr/local/bin:/usr/bin:/opt/homebrew/bin:/opt/local/bin")
    }

    func testAugmentedPathHandlesNilAndEmpty() {
        let expected = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin"
        XCTAssertEqual(ProcessRunner.augmentedPath(nil), expected)
        XCTAssertEqual(ProcessRunner.augmentedPath(""), expected)
    }

    // MARK: - Interactive shell environment

    func testShellEnvironmentParserIgnoresStartupOutput() {
        let bytes = Data(
            "startup banner\n\0SMALLGIT_ENVIRONMENT_START_7D88E2C9\0"
            .utf8
        ) + Data("PATH=/custom/bin:/usr/bin\0HTTPS_PROXY=http://proxy.example:8080\0EMPTY=\0".utf8)

        let result = ProcessRunner.parseShellEnvironment(bytes)

        XCTAssertEqual(result?["PATH"], "/custom/bin:/usr/bin")
        XCTAssertEqual(result?["HTTPS_PROXY"], "http://proxy.example:8080")
        XCTAssertEqual(result?["EMPTY"], "")
        XCTAssertNil(result?["startup banner"])
    }

    func testShellEnvironmentParserPreservesEqualsInValue() {
        let bytes = Data(
            "\0SMALLGIT_ENVIRONMENT_START_7D88E2C9\0TOKEN=first=second==\0".utf8
        )
        XCTAssertEqual(
            ProcessRunner.parseShellEnvironment(bytes)?["TOKEN"],
            "first=second=="
        )
    }

    func testShellEnvironmentParserRejectsOutputWithoutMarker() {
        XCTAssertNil(ProcessRunner.parseShellEnvironment(Data("HTTPS_PROXY=set\0".utf8)))
    }

    func testShellLaunchEnvironmentDropsLauncherOnlyProxy() {
        let inherited = [
            "PATH": "/usr/bin:/bin",
            "HTTPS_PROXY": "http://launcher-only.invalid:8080",
            "NO_PROXY": "launcher-only.invalid",
            "APP_SESSION": "keep-me"
        ]

        let result = ProcessRunner.shellLaunchEnvironment(
            inherited: inherited,
            launchdProxy: [:]
        )

        XCTAssertNil(result["HTTPS_PROXY"])
        XCTAssertNil(result["NO_PROXY"])
        XCTAssertEqual(result["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(result["APP_SESSION"], "keep-me")
    }

    func testShellLaunchEnvironmentUsesLaunchdProxyBaseline() {
        let result = ProcessRunner.shellLaunchEnvironment(
            inherited: ["HTTPS_PROXY": "http://launcher.invalid"],
            launchdProxy: [
                "HTTPS_PROXY": "http://session-proxy.example:8080",
                "UNRELATED": "ignored"
            ]
        )

        XCTAssertEqual(result["HTTPS_PROXY"], "http://session-proxy.example:8080")
        XCTAssertNil(result["UNRELATED"])
    }
}
