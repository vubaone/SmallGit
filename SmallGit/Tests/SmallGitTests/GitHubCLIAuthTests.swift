import XCTest
@testable import SmallGit

private actor AuthProgressRecorder {
    var states: [GitHubAuthState] = []
    func append(_ state: GitHubAuthState) { states.append(state) }
}

final class GitHubCLIAuthTests: XCTestCase {
    private struct Sandbox {
        let root: URL
        let executable: URL
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func commands() throws -> [String] {
            try String(contentsOf: root.appendingPathComponent("calls"))
                .split(separator: "\n").map(String.init)
        }
        func service(timeout: Duration = .seconds(10)) -> GitHubCLIAuth {
            GitHubCLIAuth(runner: ProcessRunner(importsUserShellEnvironment: false),
                          executable: executable.path, loginTimeout: timeout)
        }
    }

    private func sandbox(status: Int = 0, login: String = "exit 0",
                         refresh: String = "exit 0", setup: Int = 0) throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gh-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("gh")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "${0%/*}/calls"
        test "$GH_PROMPT_DISABLED" = 1 || exit 71
        test "$GH_BROWSER" = /usr/bin/false || exit 72
        test -z "$GH_DEBUG" || exit 73
        case "$*" in
            'auth status --active --hostname github.com') exit \(status) ;;
            'auth login --hostname github.com --git-protocol https --web --clipboard=false' | \
            'auth login --hostname github.com --git-protocol https --web --clipboard=false --scopes workflow')
                printf '! First copy your one-time code: ABCD-1234\\n' >&2
                printf 'Open this URL to continue in your web browser: https://github.com/login/device\\n' >&2
                \(login)
                ;;
            'auth refresh --hostname github.com --scopes workflow --clipboard=false')
                printf '! First copy your one-time code: WXYZ-5678\\n' >&2
                \(refresh)
                ;;
            'auth setup-git --hostname github.com') exit \(setup) ;;
            *) exit 74 ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return Sandbox(root: root, executable: script)
    }

    func testExistingLoginSkipsBrowserAndConfiguresOnlyGitHub() async throws {
        let box = try sandbox()
        defer { box.cleanup() }
        let progress = AuthProgressRecorder()
        try await box.service().connect { await progress.append($0) }
        XCTAssertEqual(try box.commands(), ["auth status --active --hostname github.com", "auth setup-git --hostname github.com"])
        let states = await progress.states
        XCTAssertEqual(states, [.checking, .configuring])
    }

    func testNewLoginPublishesDeviceCodeThenConfiguresGit() async throws {
        let box = try sandbox(status: 1)
        defer { box.cleanup() }
        let progress = AuthProgressRecorder()
        try await box.service().connect { await progress.append($0) }
        XCTAssertEqual(try box.commands(), [
            "auth status --active --hostname github.com",
            "auth login --hostname github.com --git-protocol https --web --clipboard=false",
            "auth setup-git --hostname github.com"
        ])
        let states = await progress.states
        XCTAssertEqual(states, [.checking, .waitingForBrowser(code: "ABCD-1234"), .configuring])
    }

    func testFailedLoginNeverConfiguresGit() async throws {
        let box = try sandbox(status: 1, login: "exit 1")
        defer { box.cleanup() }
        do {
            try await box.service().connect { _ in }
            XCTFail("Expected login failure")
        } catch { XCTAssertEqual(error as? GitHubAuthError, .loginFailed) }
        XCTAssertFalse(try box.commands().contains { $0.contains("setup-git") })
    }

    func testWorkflowRejectionRefreshesExistingLoginBeforeConfiguringGit() async throws {
        let box = try sandbox()
        defer { box.cleanup() }
        let progress = AuthProgressRecorder()
        try await box.service().connect(requiresWorkflowScope: true) { await progress.append($0) }
        XCTAssertEqual(try box.commands(), [
            "auth status --active --hostname github.com",
            "auth refresh --hostname github.com --scopes workflow --clipboard=false",
            "auth setup-git --hostname github.com"
        ])
        let states = await progress.states
        XCTAssertEqual(states, [.checking, .waitingForBrowser(code: "WXYZ-5678"), .configuring])
    }

    func testWorkflowRejectionWithoutLoginRequestsScopeDuringLogin() async throws {
        let box = try sandbox(status: 1)
        defer { box.cleanup() }
        try await box.service().connect(requiresWorkflowScope: true) { _ in }
        XCTAssertEqual(try box.commands(), [
            "auth status --active --hostname github.com",
            "auth login --hostname github.com --git-protocol https --web --clipboard=false --scopes workflow",
            "auth setup-git --hostname github.com"
        ])
    }

    func testFailedScopeRefreshDoesNotConfigureGit() async throws {
        let box = try sandbox(refresh: "exit 1")
        defer { box.cleanup() }
        do {
            try await box.service().connect(requiresWorkflowScope: true) { _ in }
            XCTFail("Expected workflow authorization failure")
        } catch {
            XCTAssertEqual(error as? GitHubAuthError, .workflowAuthorizationFailed)
            XCTAssertTrue(error.localizedDescription.contains("gh auth refresh"))
        }
        XCTAssertFalse(try box.commands().contains { $0.contains("setup-git") })
    }

    func testCancellationStopsScopeRefreshBeforeConfiguringGit() async throws {
        let box = try sandbox(refresh: "exec /bin/sleep 30")
        defer { box.cleanup() }
        let progress = AuthProgressRecorder()
        let task = Task {
            try await box.service().connect(requiresWorkflowScope: true) { await progress.append($0) }
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await progress.states.contains(.waitingForBrowser(code: "WXYZ-5678"))) {
            guard ContinuousClock.now < deadline else { return XCTFail("No device code arrived") }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(try box.commands().contains { $0.contains("setup-git") })
    }

    func testSetupFailureIsReportedSeparately() async throws {
        let box = try sandbox(setup: 1)
        defer { box.cleanup() }
        do {
            try await box.service().connect { _ in }
            XCTFail("Expected setup failure")
        } catch { XCTAssertEqual(error as? GitHubAuthError, .setupFailed) }
    }

    func testMissingExecutableHasInstallationGuidance() async {
        let service = GitHubCLIAuth(runner: ProcessRunner(importsUserShellEnvironment: false),
                                   executable: "/nonexistent-smallgit-test-gh")
        do {
            try await service.connect { _ in }
            XCTFail("Expected missing CLI error")
        } catch {
            XCTAssertEqual(error as? GitHubAuthError, .notInstalled)
            XCTAssertTrue(error.localizedDescription.contains("brew install gh"))
        }
    }

    func testLoginTimesOutAndDoesNotConfigureGit() async throws {
        let box = try sandbox(status: 1, login: "exec /bin/sleep 30")
        defer { box.cleanup() }
        let start = ContinuousClock.now
        do {
            try await box.service(timeout: .milliseconds(150)).connect { _ in }
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? GitHubAuthError, .timedOut) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        XCTAssertFalse(try box.commands().contains { $0.contains("setup-git") })
    }

    func testCancellationStopsLoginBeforeConfiguringGit() async throws {
        let box = try sandbox(status: 1, login: "exec /bin/sleep 30")
        defer { box.cleanup() }
        let progress = AuthProgressRecorder()
        let task = Task { try await box.service().connect { await progress.append($0) } }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await progress.states.contains(.waitingForBrowser(code: "ABCD-1234"))) {
            guard ContinuousClock.now < deadline else { return XCTFail("No device code arrived") }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(try box.commands().contains { $0.contains("setup-git") })
    }

    func testOnlyDeviceCodeLinesBecomeUIState() {
        XCTAssertEqual(GitHubCLIAuth.deviceCode(in: "! First copy your one-time code: ABCD-1234"), "ABCD-1234")
        XCTAssertNil(GitHubCLIAuth.deviceCode(in: "token=ABCD-1234"))
        XCTAssertNil(GitHubCLIAuth.deviceCode(in: "! First copy your one-time code: malformed"))
        XCTAssertNil(GitHubCLIAuth.deviceCode(in: "https://github.com/login/device"))
    }
}
