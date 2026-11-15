import XCTest
@testable import SmallGit

/// Recognising git's "I need a password" failures.
///
/// This is pattern-matching on human-readable output, which is fragile by
/// nature — so the cases that matter are pinned here, including the ones
/// that must *not* match. A false positive puts a password dialog in front
/// of someone whose problem is something else entirely.
final class GitCredentialsTests: XCTestCase {

    func testCouldNotReadUsername() {
        // A representative failure: a .app has no
        // terminal for git to prompt on, so the read fails outright.
        let output = """
        fatal: could not read Username for 'https://git.example.invalid': Device not configured
        """
        XCTAssertEqual(
            GitCredentials.urlNeedingCredentials(in: output),
            "https://git.example.invalid"
        )
    }

    func testCouldNotReadPassword() {
        let output = "fatal: could not read Password for 'https://me@example.com': terminal prompts disabled"
        XCTAssertEqual(
            GitCredentials.urlNeedingCredentials(in: output),
            "https://me@example.com"
        )
    }

    func testAuthenticationFailed() {
        let output = """
        remote: Invalid username or password.
        fatal: Authentication failed for 'https://example.com/team/repo.git/'
        """
        XCTAssertEqual(
            GitCredentials.urlNeedingCredentials(in: output),
            "https://example.com/team/repo.git/"
        )
    }

    /// Not every server lets git ask its own question. Some answer the
    /// request, and git passes the code through — a 401 is still the server
    /// asking who you are, and SmartGit shows a login dialog for it.
    func testBare401AsksForCredentials() {
        XCTAssertEqual(
            GitCredentials.urlNeedingCredentials(in:
                "fatal: unable to access 'https://git.example.com/team/app.git/': "
                + "The requested URL returned error: 401"
            ),
            "https://git.example.com/team/app.git/"
        )
    }

    /// The codes that are not a question. A server that is down, or one that
    /// knows exactly who you are and is refusing anyway, must not produce a
    /// password box: it would blame the person for something they cannot fix
    /// and hide what actually happened.
    func testServerErrorsDoNotAskForCredentials() {
        for code in [403, 404, 500, 502, 503] {
            XCTAssertNil(
                GitCredentials.urlNeedingCredentials(in:
                    "fatal: unable to access 'https://git.example.invalid/team/project.git/': "
                    + "The requested URL returned error: \(code)"
                ),
                "HTTP \(code) should not open the credentials dialog"
            )
        }
    }

    func testSSHFailuresAreNotCredentialPrompts() {
        // A username and password cannot fix a missing SSH key, so a dialog
        // asking for them would lead nowhere. These stay unhandled.
        XCTAssertNil(GitCredentials.urlNeedingCredentials(
            in: "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository."
        ))
        XCTAssertNil(GitCredentials.urlNeedingCredentials(
            in: "fatal: Authentication failed for 'ssh://git@example.com/repo.git'"
        ))
    }

    func testSSHKeyWithoutAccessIsExplained() {
        // Verbatim from the report: a clone of a private repo with the URL's
        // host spelled `github.com` instead of the ~/.ssh/config alias, so
        // the personal key answered and GitHub said the repo does not exist.
        let output = """
        Cloning into 'private-example'...
        ERROR: Repository not found.
        fatal: Could not read from remote repository.
        """
        let hint = GitCredentials.sshFailureHint(in: output)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("ssh/config"), hint ?? "")
        // Nothing a username and password can fix, so no dialog either.
        XCTAssertNil(GitCredentials.urlNeedingCredentials(in: output))
    }

    func testHTTPSRepositoryNotFoundIsNotAnSSHHint() {
        // Over HTTPS the same words are literal, and claiming an SSH key is
        // at fault would send someone to the wrong file entirely.
        let output = """
        remote: Repository not found.
        fatal: repository 'https://github.com/owner/gone.git/' not found
        """
        XCTAssertNil(GitCredentials.sshFailureHint(in: output))
    }

    func testOtherSSHFailuresAreExplained() {
        XCTAssertEqual(
            GitCredentials.sshFailureHint(
                in: "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository."
            ),
            "no SSH key was accepted — check ~/.ssh/config and that the key is in ssh-agent"
        )
        XCTAssertEqual(
            GitCredentials.sshFailureHint(in: "Host key verification failed.\nfatal: Could not read from remote repository."),
            "unknown SSH host key — connect once from Terminal to accept it"
        )
        // A ~/.ssh/config alias that does not exist reaches ssh as a plain
        // unknown name — the hint has to name it to be worth anything.
        let unresolved = GitCredentials.sshFailureHint(
            in: "ssh: Could not resolve hostname github-privat: nodename nor servname provided"
        )
        XCTAssertEqual(
            unresolved,
            "no host \"github-privat\" — if it is a ~/.ssh/config alias, check the Host entry exists"
        )
    }

    func testSuccessfulOutputCarriesNoHint() {
        XCTAssertNil(GitCredentials.sshFailureHint(in: ""))
        XCTAssertNil(GitCredentials.sshFailureHint(in: "Cloning into 'repo'...\nReceiving objects: 100%"))
    }

    func testOrdinaryFailuresAreNotCredentialPrompts() {
        XCTAssertNil(GitCredentials.urlNeedingCredentials(in: "error: failed to push some refs"))
        XCTAssertNil(GitCredentials.urlNeedingCredentials(in: ""))
        XCTAssertNil(GitCredentials.urlNeedingCredentials(in: "fatal: not a git repository"))
    }

    func testComponentsSplitTheURLTheWayGitStoresIt() {
        let parts = GitCredentials.components(of: "https://me@example.com/team/repo.git")
        XCTAssertEqual(parts?.scheme, "https")
        XCTAssertEqual(parts?.host, "example.com")
        // The user in the URL is a hint about which account, not part of the
        // server's identity — git keys on protocol and host.
        XCTAssertEqual(parts?.username, "me")

        let bare = GitCredentials.components(of: "https://git.example.invalid")
        XCTAssertEqual(bare?.host, "git.example.invalid")
        XCTAssertNil(bare?.username)
    }

    func testCredentialInputIsTheBlockGitSpeaks() {
        let input = GitCredentials.credentialInput(
            scheme: "https", host: "example.com", username: "me", password: "s3cret"
        )
        XCTAssertEqual(input, "protocol=https\nhost=example.com\nusername=me\npassword=s3cret\n\n")
        // The trailing blank line is not cosmetic: it terminates the
        // request, and git waits for it before doing anything.
        XCTAssertTrue(input.hasSuffix("\n\n"))
    }
}
