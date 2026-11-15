import XCTest
@testable import SmallGit

/// The status line a failed network operation leaves behind.
///
/// The Output panel has git's whole message; this one line is what someone
/// reads first, so the test that matters is that it stops saying only
/// "failed" when git has told us something more useful than that.
@MainActor
final class FailureStatusTests: XCTestCase {

    private func failure(_ stderr: String) -> GitCommandResult {
        GitCommandResult(command: "git clone …", exitCode: 128,
                         stdout: "", stderr: stderr, duration: 0.5)
    }

    func testSSHKeyWithoutAccessSaysSo() {
        // The reported failure, verbatim. "Repository not found" over SSH
        // means the key that answered belongs to an account that cannot see
        // the repo — usually the URL naming the wrong ~/.ssh/config host.
        let status = AppState.failureStatus("Clone", result: failure("""
        ERROR: Repository not found.
        fatal: Could not read from remote repository.
        """))
        XCTAssertTrue(status.hasPrefix("Clone — "), status)
        XCTAssertTrue(status.contains("ssh/config"), status)
    }

    /// A representative failure: a Git server having a bad
    /// afternoon. Nothing about it is the user's repository, credentials or
    /// URL, and the status line used to say only "Fetch — failed" — which
    /// reads as a bug in the app.
    func testServerErrorNamesTheServerAndTheCode() {
        let status = AppState.failureStatus("Fetch", result: failure(
            "fatal: unable to access 'https://git.example.invalid/team/project.git/': "
            + "The requested URL returned error: 503"
        ))
        XCTAssertTrue(status.contains("git.example.invalid"), status)
        XCTAssertTrue(status.contains("503"), status)
        XCTAssertTrue(status.contains("unavailable"), status)
    }

    func testStatusCodesThatMeanSomethingElseSaySomethingElse() {
        func hint(_ code: Int) -> String {
            AppState.failureStatus("Push", result: failure(
                "fatal: unable to access 'https://git.example.com/x.git/': "
                + "The requested URL returned error: \(code)"
            ))
        }
        XCTAssertTrue(hint(403).contains("no access"), hint(403))
        XCTAssertTrue(hint(404).contains("remote URL"), hint(404))
        // No advice to give for this one, but the code is still the answer.
        XCTAssertTrue(hint(418).hasSuffix("answered 418"), hint(418))
    }

    func testCodeFromTheSmartHTTPWording() {
        // The other place git puts a status code, when the request fails
        // mid-negotiation rather than on the first hit.
        let status = AppState.failureStatus("Push", result: failure(
            "error: RPC failed; HTTP 502 curl 22 The requested URL returned error: 502"
        ))
        XCTAssertTrue(status.contains("502"), status)
        XCTAssertTrue(status.contains("unavailable"), status)
    }

    func testUnreachableServerIsNotReportedAsAnSSHAliasProblem() {
        // curl's wording, not ssh's — the ~/.ssh/config advice would be
        // nonsense for an https remote.
        let status = AppState.failureStatus("Fetch", result: failure(
            "fatal: unable to access 'https://git.example.invalid/team/project.git/': "
            + "Could not resolve host: git.example.invalid"
        ))
        XCTAssertTrue(status.contains("git.example.invalid"), status)
        XCTAssertTrue(status.contains("VPN"), status)
        XCTAssertFalse(status.contains("ssh/config"), status)
    }

    func testOrdinaryFailureKeepsTheShortForm() {
        // No hint to add, no words to spend: the panel says the rest.
        XCTAssertEqual(
            AppState.failureStatus("Push", result: failure("error: failed to push some refs")),
            "Push — failed"
        )
    }

    private func workflowRejection(url: String = "https://github.com/vubaone/SmallGit.git") -> String {
        """
        To \(url)
         ! [remote rejected] main -> main (refusing to allow an OAuth App to create or update workflow `.github/workflows/ci.yml` without `workflow` scope)
        error: failed to push some refs to '\(url)'
        """
    }

    func testWorkflowScopeRejectionExplainsTheMissingPermission() {
        let output = workflowRejection()
        XCTAssertEqual(GitRemoteFailure.workflowPermissionURL(in: output), "https://github.com/vubaone/SmallGit.git")
        XCTAssertEqual(AppState.failureStatus("Push", result: failure(output)),
                       "Push — GitHub needs workflow permission — authorize workflow access and retry")
    }

    func testWorkflowScopeRejectionRecognizesClassicTokensAndRemovesURLCredentials() {
        let output = workflowRejection(url: "https://name:secret@github.com/vubaone/SmallGit.git")
            .replacingOccurrences(of: "an OAuth App", with: "a Personal Access Token")
        XCTAssertEqual(GitRemoteFailure.workflowPermissionURL(in: output), "https://github.com/vubaone/SmallGit.git")
    }

    func testWorkflowScopeRecoveryRequiresGitHubHTTPSAndTheSpecificRejection() {
        for url in ["https://github.com.example.org/a/b.git", "http://github.com/a/b.git",
                    "git@github.com:a/b.git", "ssh://git@github.com/a/b.git",
                    "https://github.com:8443/a/b.git", "https://example.com/a/b.git"] {
            XCTAssertNil(GitRemoteFailure.workflowPermissionURL(in: workflowRejection(url: url)), url)
        }
        XCTAssertNil(GitRemoteFailure.workflowPermissionURL(in:
            "To https://github.com/a/b.git\n ! [rejected] main -> main (fetch first)"))
        XCTAssertNil(GitRemoteFailure.workflowPermissionURL(in:
            "To https://github.com/a/b.git\nerror: workflow failed"))
    }

    func testHintReadsGitsStdoutToo() {
        // git writes some of this to stdout, and which stream a line lands on
        // is not something the status line should depend on.
        let split = GitCommandResult(
            command: "git clone …", exitCode: 128,
            stdout: "Cloning into 'private-example'...\nERROR: Repository not found.",
            stderr: "fatal: Could not read from remote repository.", duration: 0.5
        )
        XCTAssertNotEqual(AppState.failureStatus("Clone", result: split), "Clone — failed")
    }
}
