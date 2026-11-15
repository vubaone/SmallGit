import XCTest
import SwiftUI
import ViewInspector
@testable import SmallGit

@MainActor
private final class ScriptedGitHubAuth: GitHubAuthenticating {
    var shouldWait = false
    var failure: GitHubAuthError?
    var onConnected: (() throws -> Void)?
    private(set) var calls = 0
    private(set) var cancellations = 0
    private(set) var workflowRequests: [Bool] = []

    func connect(requiresWorkflowScope: Bool, progress: @escaping @Sendable (GitHubAuthState) async -> Void) async throws {
        calls += 1
        workflowRequests.append(requiresWorkflowScope)
        if let failure { throw failure }
        await progress(.waitingForBrowser(code: "ABCD-1234"))
        do {
            while shouldWait { try await Task.sleep(for: .milliseconds(10)) }
            try Task.checkCancellation()
        } catch {
            cancellations += 1
            throw error
        }
        try onConnected?()
        await progress(.configuring)
    }
}

@MainActor
final class CredentialsUITests: XCTestCase {
    private func request(host: String = "github.com", repoPath: String? = nil) -> CredentialRequest {
        CredentialRequest(action: "Fetch", url: "https://\(host)", scheme: "https",
                          host: host, suggestedUsername: nil, repoPath: repoPath)
    }

    func testGitHubOptionIsOnlyShownForGitHubHTTPS() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        for host in ["github.com", "GITHUB.COM", "gitlab.com", "github.com.example.org"] {
            let pending = request(host: host)
            let ui = UIDriver(view: CredentialsSheet(appState: f.app, request: pending))
            if host.lowercased() == "github.com" {
                XCTAssertNoThrow(try ui.element("credentials.github"))
            } else {
                XCTAssertThrowsError(try ui.element("credentials.github"))
            }
        }
        let insecure = CredentialRequest(action: "Fetch", url: "http://github.com", scheme: "http",
                                         host: "github.com", suggestedUsername: nil, repoPath: nil)
        XCTAssertFalse(insecure.supportsGitHubCLI)
    }

    func testButtonShowsDeviceCodeAndPreventsDuplicateSignIn() async throws {
        let auth = ScriptedGitHubAuth()
        auth.shouldWait = true
        let f = try UIFixture(gitHubAuth: auth)
        defer { f.cleanup() }
        let pending = request()
        f.app.credentialRequest = pending
        let ui = UIDriver(view: CredentialsSheet(appState: f.app, request: pending))
        try ui.fire("credentials.github")
        try await awaitUI("device code") { f.app.gitHubAuthState == .waitingForBrowser(code: "ABCD-1234") }
        XCTAssertEqual(try ui.element("credentials.githubCode").text().string(), "ABCD-1234")
        XCTAssertEqual(try ui.element("credentials.openGitHub").link().url(), URL(string: "https://github.com/login/device"))
        XCTAssertTrue(try ui.element("credentials.username").isDisabled())
        XCTAssertTrue(try ui.element("credentials.submit").isDisabled())
        XCTAssertThrowsError(try ui.fire("credentials.github"))
        XCTAssertNil(f.app.signInWithGitHubCLI(for: pending))
        XCTAssertEqual(auth.calls, 1)
        // The actual Cancel button terminates the pending sign-in too.
        try ui.fire("credentials.cancel")
        try await awaitUI("auth cancelled") { auth.cancellations == 1 }
        XCTAssertNil(f.app.credentialRequest)
        XCTAssertEqual(f.app.gitHubAuthState, .idle)
    }

    func testMissingCLILeavesTheFormOpenWithAnActionableError() async throws {
        let auth = ScriptedGitHubAuth()
        auth.failure = .notInstalled
        let f = try UIFixture(gitHubAuth: auth)
        defer { f.cleanup() }
        let pending = request()
        f.app.credentialRequest = pending
        let ui = UIDriver(view: CredentialsSheet(appState: f.app, request: pending))
        try ui.fire("credentials.github")
        try await awaitUI("missing CLI error") { f.app.gitHubAuthState == .missingCLI }
        XCTAssertTrue(try ui.element("credentials.githubError").text().string().contains("brew install gh"))
        XCTAssertFalse(try ui.element("credentials.username").isDisabled())
        XCTAssertFalse(try ui.element("credentials.github").isDisabled())
        XCTAssertEqual(f.app.credentialRequest, pending)
    }

    func testInstallButtonOpensEmbeddedTerminalAndOnlyPrefillsTheCommand() async throws {
        let auth = ScriptedGitHubAuth()
        auth.failure = .notInstalled
        let f = try UIFixture(gitHubAuth: auth)
        defer { f.cleanup() }
        let repo = try await f.makeRepo("repo")
        await f.open(repo)
        // Keep a previous transcript entry; this is a built-in, not a process.
        f.app.terminalVM.input = "cd ."
        f.app.terminalVM.submit()
        let previousEntries = f.app.terminalVM.entries.map(\.id)
        let previousHistory = f.app.terminalVM.history
        let pending = request(repoPath: repo.path)
        f.app.credentialRequest = pending
        let ui = UIDriver(view: CredentialsSheet(appState: f.app, request: pending))
        try ui.fire("credentials.github")
        try await awaitUI("install option") { f.app.gitHubAuthState == .missingCLI }
        try ui.fire("credentials.installGitHubCLI")

        XCTAssertNil(f.app.credentialRequest, "The modal must close so the terminal can be used")
        XCTAssertTrue(f.app.uiState.showsTerminal)
        let terminal = UIDriver(view: TerminalPanel(appState: f.app, viewModel: f.app.terminalVM))
        XCTAssertEqual(try terminal.element("terminal.input").textField().input(), "brew install gh")
        XCTAssertEqual(f.app.terminalVM.directory, repo.path)
        XCTAssertFalse(f.app.terminalVM.isRunning)
        XCTAssertEqual(f.app.terminalVM.entries.map(\.id), previousEntries)
        XCTAssertEqual(f.app.terminalVM.history, previousHistory)
        XCTAssertEqual(auth.calls, 1)
    }

    func testInstallButtonWorksBeforeAnyRepositoryIsOpen() async throws {
        let auth = ScriptedGitHubAuth()
        auth.failure = .notInstalled
        let f = try UIFixture(gitHubAuth: auth)
        defer { f.cleanup() }
        let pending = request()
        f.app.credentialRequest = pending
        let task = try XCTUnwrap(f.app.signInWithGitHubCLI(for: pending))
        await task.value
        try UIDriver(view: CredentialsSheet(appState: f.app, request: pending)).fire("credentials.installGitHubCLI")
        XCTAssertTrue(f.app.uiState.showsTerminal)
        XCTAssertEqual(f.app.terminalVM.input, "brew install gh")
        XCTAssertEqual(f.app.terminalVM.directory, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertTrue(f.app.terminalVM.entries.isEmpty)
        XCTAssertFalse(f.app.terminalVM.isRunning)
    }

    func testInstallButtonIsAbsentForOtherAuthenticationStates() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let pending = request()
        let ui = UIDriver(view: CredentialsSheet(appState: f.app, request: pending))
        for state in [GitHubAuthState.idle, .checking, .failed("Sign-in failed") ] {
            f.app.gitHubAuthState = state
            XCTAssertThrowsError(try ui.element("credentials.installGitHubCLI"))
        }
    }

    /// A real local fetch is refused by a tiny Git wrapper until the fake
    /// authentication service succeeds. No GitHub account or network is used.
    private func prepareFailedFetch(_ f: UIFixture, auth: ScriptedGitHubAuth) async throws -> URL {
        let origin = try await f.makeRepo("origin")
        let repo = try await f.clone(origin, name: "repo")
        await f.open(repo)
        let script = f.root.appendingPathComponent("fake-git")
        try """
        #!/bin/sh
        if [ "$3" = fetch ]; then
            printf 'fetch\\n' >> "${0%/*}/fetch-calls"
            if [ ! -f "${0%/*}/authenticated" ]; then
                printf "fatal: could not read Username for 'https://github.com': terminal prompts disabled\\n" >&2
                exit 128
            fi
        fi
        exec /usr/bin/git "$@"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        await f.runner.setGitPath(script.path)
        let marker = f.root.appendingPathComponent("authenticated")
        auth.onConnected = { try Data().write(to: marker) }
        await f.app.fetch()
        XCTAssertEqual(f.app.credentialRequest?.host, "github.com")
        return repo
    }

    func testSuccessfulSignInRetriesTheFailedFetch() async throws {
        let auth = ScriptedGitHubAuth()
        let f = try UIFixture(gitHubAuth: auth)
        defer { f.cleanup() }
        _ = try await prepareFailedFetch(f, auth: auth)
        let pending = try XCTUnwrap(f.app.credentialRequest)
        let ui = UIDriver(view: CredentialsSheet(appState: f.app, request: pending))
        try ui.fire("credentials.github")
        try await awaitUI("fetch retried") { f.app.statusText == "Fetch — done" && !f.app.isWorking }
        XCTAssertNil(f.app.credentialRequest)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("fetch-calls")), "fetch\nfetch\n")
        XCTAssertEqual(auth.calls, 1)
        XCTAssertEqual(auth.workflowRequests, [false], "Ordinary sign-in must not request workflow access")
    }

    /// Replay GitHub's reported scope rejection without contacting a remote.
    private func prepareWorkflowPushFailure(_ f: UIFixture, auth: ScriptedGitHubAuth) async throws {
        let repo = try await f.makeRepo("repo")
        await f.open(repo)
        let script = f.root.appendingPathComponent("fake-git")
        try """
        #!/bin/sh
        if [ "$3" = push ]; then
            printf '%s\\n' "$*" >> "${0%/*}/push-calls"
            if [ -f "${0%/*}/workflow-allowed" ]; then exit 0; fi
            cat >&2 <<'MESSAGE'
        To https://github.com/vubaone/SmallGit.git
         ! [remote rejected] main -> main (refusing to allow an OAuth App to create or update workflow `.github/workflows/ci.yml` without `workflow` scope)
        error: failed to push some refs to 'https://github.com/vubaone/SmallGit.git'
        MESSAGE
            exit 1
        fi
        exec /usr/bin/git "$@"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        await f.runner.setGitPath(script.path)
        let marker = f.root.appendingPathComponent("workflow-allowed")
        auth.onConnected = { try Data().write(to: marker) }
        let pushed = await f.app.push()
        XCTAssertFalse(pushed)
        XCTAssertEqual(f.app.credentialRequest?.requiresWorkflowScope, true)
        XCTAssertTrue(f.app.statusText.contains("workflow permission"))
        XCTAssertEqual(auth.calls, 0, "Authorization requires the user's button press")
        XCTAssertEqual(f.platform.pushRejectionPrompts, 0, "Scope errors must not offer force push or pull")
    }

    private func pushCalls(_ f: UIFixture) throws -> [String] {
        try String(contentsOf: f.root.appendingPathComponent("push-calls"))
            .split(separator: "\n").map(String.init)
    }

    func testWorkflowAuthorizationButtonRetriesTheSamePushAfterApproval() async throws {
        let auth = ScriptedGitHubAuth()
        let f = try UIFixture(gitHubAuth: auth)
        defer { f.cleanup() }
        try await prepareWorkflowPushFailure(f, auth: auth)
        let pending = try XCTUnwrap(f.app.credentialRequest)
        let ui = UIDriver(view: CredentialsSheet(appState: f.app, request: pending))
        XCTAssertEqual(try ui.element("credentials.github").button().labelView().text().string(),
                       "Authorize Workflow Access")
        try ui.fire("credentials.github")
        try await awaitUI("push retried after workflow approval") {
            f.app.statusText == "Push — done" && !f.app.isWorking
        }
        let calls = try pushCalls(f)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first, calls.last)
        XCTAssertFalse(calls.contains { $0.contains("--force") })
        XCTAssertEqual(auth.workflowRequests, [true])
        XCTAssertNil(f.app.credentialRequest)
    }

    func testCancellingWorkflowAuthorizationDoesNotRetryPush() async throws {
        let auth = ScriptedGitHubAuth()
        auth.shouldWait = true
        let f = try UIFixture(gitHubAuth: auth)
        defer { f.cleanup() }
        try await prepareWorkflowPushFailure(f, auth: auth)
        let pending = try XCTUnwrap(f.app.credentialRequest)
        let ui = UIDriver(view: CredentialsSheet(appState: f.app, request: pending))
        try ui.fire("credentials.github")
        try await awaitUI("workflow device code") {
            f.app.gitHubAuthState == .waitingForBrowser(code: "ABCD-1234")
        }
        try ui.fire("credentials.cancel")
        try await awaitUI("workflow authorization cancelled") { auth.cancellations == 1 }
        XCTAssertNil(f.app.credentialRequest)
        XCTAssertEqual(try pushCalls(f).count, 1)
        XCTAssertEqual(auth.workflowRequests, [true])
    }

    func testWorkflowAuthorizationFailureKeepsPushPendingUntilApproval() async throws {
        let auth = ScriptedGitHubAuth()
        auth.failure = .workflowAuthorizationFailed
        let f = try UIFixture(gitHubAuth: auth)
        defer { f.cleanup() }
        try await prepareWorkflowPushFailure(f, auth: auth)
        let pending = try XCTUnwrap(f.app.credentialRequest)
        let ui = UIDriver(view: CredentialsSheet(appState: f.app, request: pending))
        try ui.fire("credentials.github")
        try await awaitUI("workflow authorization error") {
            if case .failed = f.app.gitHubAuthState { return true }
            return false
        }
        XCTAssertTrue(try ui.element("credentials.githubError").text().string().contains("gh auth refresh"))
        XCTAssertEqual(f.app.credentialRequest, pending)
        XCTAssertEqual(try pushCalls(f).count, 1)
        auth.failure = nil
        try ui.fire("credentials.github")
        try await awaitUI("workflow authorization retried") { f.app.statusText == "Push — done" && !f.app.isWorking }
        XCTAssertEqual(try pushCalls(f).count, 2)
        XCTAssertEqual(auth.workflowRequests, [true, true])
    }

    func testSignInFailureKeepsThePendingOperationForAnotherAttempt() async throws {
        let auth = ScriptedGitHubAuth()
        auth.failure = .setupFailed
        let f = try UIFixture(gitHubAuth: auth)
        defer { f.cleanup() }
        _ = try await prepareFailedFetch(f, auth: auth)
        let pending = try XCTUnwrap(f.app.credentialRequest)
        let first = try XCTUnwrap(f.app.signInWithGitHubCLI(for: pending))
        await first.value
        XCTAssertEqual(f.app.credentialRequest, pending)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("fetch-calls")), "fetch\n")
        auth.failure = nil
        try UIDriver(view: CredentialsSheet(appState: f.app, request: pending)).fire("credentials.github")
        try await awaitUI("retry after setup failure") { f.app.statusText == "Fetch — done" && !f.app.isWorking }
        XCTAssertNil(f.app.credentialRequest)
        XCTAssertEqual(auth.calls, 2)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("fetch-calls")), "fetch\nfetch\n")
    }

    func testSwitchingRepositoryDuringSignInDoesNotRetryOnTheNewRepository() async throws {
        let auth = ScriptedGitHubAuth()
        auth.shouldWait = true
        let f = try UIFixture(gitHubAuth: auth)
        defer { f.cleanup() }
        _ = try await prepareFailedFetch(f, auth: auth)
        let pending = try XCTUnwrap(f.app.credentialRequest)
        let task = try XCTUnwrap(f.app.signInWithGitHubCLI(for: pending))
        try await awaitUI("waiting for auth") { auth.calls == 1 }
        let other = try await f.makeRepo("other")
        await f.open(other)
        auth.shouldWait = false
        await task.value
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("fetch-calls")), "fetch\n")
        XCTAssertEqual(f.app.activeRepo?.path, other.path)
        XCTAssertTrue(f.app.statusText.contains("original repository"))
    }
}
