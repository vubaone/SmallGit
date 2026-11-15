import XCTest
@testable import SmallGit

/// Answering the credentials dialog, as far as somewhere git can read the
/// answer back from.
///
/// The helper is a repo-local `store --file=…` rather than the macOS
/// keychain: it is the same `git credential approve` path with somewhere to
/// look afterwards, and it leaves the keychain of whoever runs the suite
/// alone.
@MainActor
final class CredentialSubmissionTests: XCTestCase {

    private struct Sandbox {
        let repo: String
        let store: URL
        let root: URL
    }

    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-credentials-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "repo"])
        let store = root.appendingPathComponent("credentials")
        // A helper configured here is one `submitCredentials` will find, so
        // it never reaches for the global config of the machine running the
        // suite to install the keychain one.
        _ = try await runner.run(
            in: repo,
            args: ["config", "credential.helper", "store --file=\(store.path)"]
        )
        return Sandbox(repo: repo, store: store, root: root)
    }

    private func request(repo: String) -> CredentialRequest {
        CredentialRequest(
            action: "Fetch",
            url: "https://git.example.invalid",
            scheme: "https",
            host: "git.example.invalid",
            suggestedUsername: nil,
            repoPath: repo
        )
    }

    /// The dialog is presented with `.sheet(item: $appState.credentialRequest)`,
    /// so dismissing it clears the request before the answer is submitted.
    /// Storing has to survive that — otherwise the password goes nowhere and
    /// the next fetch asks for it again.
    func testAnswerIsStoredAfterTheSheetHasClearedTheRequest() async throws {
        let sandbox = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let app = makeIsolatedAppState()
        let pending = request(repo: sandbox.repo)

        app.credentialRequest = pending   // dialog on screen
        app.credentialRequest = nil       // …and dismissed, which clears it

        await app.submitCredentials(for: pending, username: "someone", password: "s3cret")

        let stored = try String(contentsOf: sandbox.store, encoding: .utf8)
        XCTAssertTrue(
            stored.contains("https://someone:s3cret@git.example.invalid"),
            "the answer never reached git's credential helper — file holds: \(stored)"
        )
        XCTAssertEqual(app.statusText, "Saved credentials for git.example.invalid")
    }

    /// What the whole exchange exists for: git can answer its own question
    /// afterwards, without a terminal to ask on.
    func testGitFillsTheCredentialItWasGiven() async throws {
        let sandbox = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let app = makeIsolatedAppState()

        await app.submitCredentials(
            for: request(repo: sandbox.repo),
            username: "someone",
            password: "s3cret"
        )

        let filled = try await ProcessRunner().run(
            in: sandbox.repo,
            args: ["credential", "fill"],
            stdin: "protocol=https\nhost=git.example.invalid\n\n",
            env: ["GIT_TERMINAL_PROMPT": "0"]
        )
        XCTAssertTrue(filled.succeeded, filled.combinedOutput)
        XCTAssertTrue(filled.stdout.contains("username=someone"), filled.stdout)
        XCTAssertTrue(filled.stdout.contains("password=s3cret"), filled.stdout)
    }
}
