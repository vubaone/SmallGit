import Foundation

/// git asking for a username and password, and the answer.
///
/// git has no way to ask a GUI for credentials: it prompts on a terminal
/// that a `.app` does not have, which is why the failure arrives as
/// `could not read Username for 'https://…': Device not configured` rather
/// than as a prompt. This turns that message back into a question the app
/// can put on screen, and puts the answer where git's own credential helper
/// will find it next time.
enum GitCredentials {

    /// The URL git could not authenticate to, if `output` says so.
    ///
    /// Deliberately http(s) only. `Permission denied (publickey)` is also an
    /// authentication failure, but a username and password cannot fix it —
    /// asking for them would be a dialog that leads nowhere. SSH keys are
    /// configured outside this app.
    static func urlNeedingCredentials(in output: String) -> String? {
        let markers = [
            "could not read Username for '",
            "could not read Password for '",
            "Authentication failed for '"
        ]
        for marker in markers {
            guard let start = output.range(of: marker) else { continue }
            let rest = output[start.upperBound...]
            guard let end = rest.firstIndex(of: "'") else { continue }
            let url = String(rest[..<end])
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }
            return url
        }
        // Some servers answer the request rather than letting git ask its
        // own question, and git passes the status code straight through:
        // `fatal: unable to access '<url>': The requested URL returned
        // error: 401`. A 401 *is* the server asking who you are, so it gets
        // the same dialog — the way SmartGit puts one up for it.
        //
        // 403 does not. There the server knows who you are and is saying no,
        // and a password box would be a dead end dressed as a way out; the
        // status line explains that one instead.
        if GitRemoteFailure.httpStatus(in: output) == 401 {
            return GitRemoteFailure.accessedURL(in: output)
        }
        return nil
    }

    /// A one-line explanation of an SSH authentication failure, or nil when
    /// the output is not one.
    ///
    /// SSH failures are the ones a password dialog cannot fix, and they are
    /// also the ones whose wording hides what actually went wrong: GitHub
    /// answers "Repository not found" to a key that authenticated fine but
    /// belongs to an account without access, which reads as "the repo is
    /// gone" when it means "wrong key". A `.app` makes two of these more
    /// likely than they are in a terminal — ssh cannot ask about an unknown
    /// host key with nowhere to ask, and a passphrase that a terminal would
    /// prompt for has to already be in the agent.
    static func sshFailureHint(in output: String) -> String? {
        if output.contains("Permission denied (publickey)") {
            return "no SSH key was accepted — check ~/.ssh/config and that the key is in ssh-agent"
        }
        // GitHub prefixes the SSH-side message with "ERROR:"; over HTTPS the
        // same words arrive as "remote: Repository not found." and mean what
        // they say, so only the SSH form is claimed here.
        if output.contains("ERROR: Repository not found") {
            return "that SSH key has no access to the repository — check the host in the URL matches the right ~/.ssh/config entry"
        }
        if output.contains("Host key verification failed") {
            return "unknown SSH host key — connect once from Terminal to accept it"
        }
        if let host = unresolvedHost(in: output) {
            return "no host \"\(host)\" — if it is a ~/.ssh/config alias, check the Host entry exists"
        }
        return nil
    }

    /// The hostname ssh could not resolve, if that is why it failed. A
    /// mistyped `~/.ssh/config` alias lands here rather than anywhere that
    /// mentions ssh, because to ssh it is just a name that does not exist.
    private static func unresolvedHost(in output: String) -> String? {
        let marker = "Could not resolve hostname "
        guard let start = output.range(of: marker) else { return nil }
        let rest = output[start.upperBound...]
        let host = rest.prefix { !$0.isWhitespace && $0 != ":" }
        return host.isEmpty ? nil : String(host)
    }

    /// Host and scheme, which is the granularity git stores credentials at
    /// unless `credential.useHttpPath` says otherwise. The user part of a
    /// URL like `https://me@host/repo` is dropped: it is a *hint* about the
    /// account, not part of the identity of the server.
    static func components(of url: String) -> (scheme: String, host: String, username: String?)? {
        guard let parsed = URLComponents(string: url),
              let scheme = parsed.scheme,
              let host = parsed.host,
              !host.isEmpty
        else { return nil }
        return (scheme, host, parsed.user.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The block `git credential` speaks on stdin.
    static func credentialInput(
        scheme: String,
        host: String,
        username: String,
        password: String
    ) -> String {
        // Built by joining rather than as a multi-line literal: the protocol
        // is terminated by a blank line — "…password=x\n\n" — and a literal
        // swallows the second newline, which leaves git waiting for the end
        // of a request that already looks complete.
        [
            "protocol=\(scheme)",
            "host=\(host)",
            "username=\(username)",
            "password=\(password)",
            ""
        ].joined(separator: "\n") + "\n"
    }
}
