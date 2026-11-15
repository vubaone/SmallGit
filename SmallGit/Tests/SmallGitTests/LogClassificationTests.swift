import XCTest
@testable import SmallGit

/// Covers how a git invocation is filed, and what is stripped out of it first.
///
/// Both halves are load-bearing. If the classifier is wrong, "is it the
/// network or the disk?" — the first question anyone asks of a slow app — is
/// answered wrongly. If the redaction is wrong, a log the user is invited to
/// read and share carries their credentials out with it.
final class LogClassificationTests: XCTestCase {

    // MARK: - Finding the subcommand

    /// Every invocation from `ProcessRunner` is prefixed with `-C <repo>`, and
    /// `-C` swallows the path after it. A scan that missed that would classify
    /// every command by the repository path instead.
    func testSubcommandIsFoundPastTheRepositoryPrefix() {
        XCTAssertEqual(
            GitCommandKind.subcommand(of: ["-C", "/Users/me/repo", "status", "--porcelain=v2"]),
            "status"
        )
    }

    func testSubcommandIsFoundPastOtherGlobalOptions() {
        XCTAssertEqual(
            GitCommandKind.subcommand(of: ["-c", "core.pager=cat", "-C", "/repo", "log", "-n", "20"]),
            "log"
        )
        XCTAssertEqual(
            GitCommandKind.subcommand(of: ["--no-pager", "-C", "/repo", "diff"]),
            "diff"
        )
    }

    /// `--git-dir=x` carries its value; `--git-dir x` does not. Getting this
    /// backwards eats the subcommand.
    func testAttachedOptionValuesDoNotEatTheSubcommand() {
        XCTAssertEqual(GitCommandKind.subcommand(of: ["--git-dir=/repo/.git", "fetch"]), "fetch")
        XCTAssertEqual(GitCommandKind.subcommand(of: ["--git-dir", "/repo/.git", "fetch"]), "fetch")
    }

    func testAllOptionsAndNoSubcommandIsNil() {
        XCTAssertNil(GitCommandKind.subcommand(of: ["--version"]))
        XCTAssertNil(GitCommandKind.subcommand(of: []))
    }

    // MARK: - Network vs local

    func testRemoteOperationsAreNetwork() {
        for subcommand in ["fetch", "pull", "push", "clone", "ls-remote"] {
            XCTAssertTrue(
                GitCommandKind.isNetwork(args: ["-C", "/repo", subcommand]),
                "\(subcommand) talks to a remote"
            )
        }
    }

    func testLocalOperationsAreNotNetwork() {
        for subcommand in ["status", "log", "diff", "commit", "checkout", "rebase", "stash", "blame"] {
            XCTAssertFalse(
                GitCommandKind.isNetwork(args: ["-C", "/repo", subcommand]),
                "\(subcommand) never leaves the machine"
            )
        }
    }

    /// The subcommands that go either way. `git remote -v` prints a config
    /// file; `git remote update` opens a connection. Filing both as network
    /// would make an idle app look like it was talking to the internet.
    func testSubcommandsThatAreOnlySometimesNetwork() {
        XCTAssertFalse(GitCommandKind.isNetwork(args: ["-C", "/repo", "remote", "-v"]))
        XCTAssertTrue(GitCommandKind.isNetwork(args: ["-C", "/repo", "remote", "update"]))
        XCTAssertFalse(GitCommandKind.isNetwork(args: ["-C", "/repo", "submodule", "status"]))
        XCTAssertTrue(GitCommandKind.isNetwork(args: ["-C", "/repo", "submodule", "update", "--init"]))
    }

    /// A repository whose path happens to contain "push" must not be read as
    /// a push — the classifier has to be looking at the subcommand position,
    /// not scanning the whole argument vector.
    func testARepositoryPathIsNotMistakenForASubcommand() {
        XCTAssertFalse(GitCommandKind.isNetwork(args: ["-C", "/Users/me/push", "status"]))
        XCTAssertEqual(GitCommandKind.subcommand(of: ["-C", "/Users/me/fetch", "status"]), "status")
    }

    // MARK: - Redaction

    /// The one that matters. An HTTPS remote carries its token in the URL, so
    /// an unscrubbed log hands it out the moment it is shared.
    func testHTTPSCredentialsAreStripped() {
        XCTAssertEqual(
            LogRedaction.strippingURLCredentials(in: "git push https://vubl:ghp_secret123@github.com/org/repo.git main"),
            "git push https://vubl:***@github.com/org/repo.git main"
        )
    }

    /// The username stays: it is rarely the secret, and it is exactly what
    /// you need when diagnosing "why is it authenticating as someone else".
    func testTheUsernameIsKept() {
        let scrubbed = LogRedaction.strippingURLCredentials(in: "https://vubl:token@host/x")
        XCTAssertTrue(scrubbed.contains("vubl"))
        XCTAssertFalse(scrubbed.contains("token"))
    }

    func testURLsWithoutASecretAreLeftAlone() {
        let ssh = "git fetch git@github.com:org/repo.git"
        XCTAssertEqual(LogRedaction.strippingURLCredentials(in: ssh), ssh)

        let plain = "https://github.com/org/repo.git"
        XCTAssertEqual(LogRedaction.strippingURLCredentials(in: plain), plain)

        let userOnly = "https://vubl@github.com/org/repo.git"
        XCTAssertEqual(LogRedaction.strippingURLCredentials(in: userOnly), userOnly)
    }

    /// An `@` after the authority is part of a path, not a credential
    /// separator, and treating it as one would mangle the URL.
    func testAnAtSignInThePathIsNotACredential() {
        let url = "https://github.com/org/repo/blob/main/@types/index.d.ts"
        XCTAssertEqual(LogRedaction.strippingURLCredentials(in: url), url)
    }

    func testMultipleURLsOnOneLineAreAllScrubbed() {
        let scrubbed = LogRedaction.strippingURLCredentials(
            in: "https://a:1@x.com/r https://b:2@y.com/r"
        )
        XCTAssertEqual(scrubbed, "https://a:***@x.com/r https://b:***@y.com/r")
        XCTAssertFalse(scrubbed.contains("1@"))
        XCTAssertFalse(scrubbed.contains("2@"))
    }

    func testTextWithoutAURLIsUntouched() {
        let text = "git -C /repo status --porcelain=v2"
        XCTAssertEqual(LogRedaction.strippingURLCredentials(in: text), text)
    }

    func testHomeDirectoryIsAbbreviated() {
        let path = NSHomeDirectory() + "/Work/repo"
        XCTAssertEqual(LogRedaction.abbreviatingHome(in: path), "~/Work/repo")
    }

    /// The full scrub does both, and does not lose the rest of the line.
    func testScrubAppliesBothRules() {
        let text = "push https://u:tok@host/r from \(NSHomeDirectory())/repo"
        let scrubbed = LogRedaction.scrub(text)
        XCTAssertFalse(scrubbed.contains("tok@"))
        XCTAssertTrue(scrubbed.contains("~/repo"))
        XCTAssertTrue(scrubbed.hasPrefix("push "))
    }
}
