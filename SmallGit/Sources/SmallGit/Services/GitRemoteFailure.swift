import Foundation

/// A one-line explanation of a remote operation that failed over HTTP(S),
/// or nil when the output is not one.
///
/// The sibling of `GitCredentials.sshFailureHint`, for the half of the
/// remotes that speak HTTP. git says why — `The requested URL returned
/// error: 503` — but it says it in the Output panel, and the status line
/// said "Fetch — failed" and nothing more. A server having a bad afternoon
/// then reads exactly like a bug in the app, which sends whoever hit it
/// looking in the wrong place.
enum GitRemoteFailure {

    static func hint(in output: String) -> String? {
        if workflowPermissionURL(in: output) != nil {
            return "GitHub needs workflow permission — authorize workflow access and retry"
        }
        if let code = httpStatus(in: output) {
            return "\(server(in: output)) answered \(code)\(explanation(of: code))"
        }
        if let host = unresolvedHost(in: output) {
            return "no route to \(host) — check the network, and the VPN if the server is on one"
        }
        if output.contains("Connection refused") || output.contains("Failed to connect to") {
            return "the connection was refused — the server may be down, or unreachable from this network"
        }
        if output.contains("Operation timed out") || output.contains("Connection timed out") {
            return "the connection timed out — check the network, and the VPN if the server is on one"
        }
        if output.contains("SSL certificate problem") || output.contains("certificate verify failed") {
            return "the server's TLS certificate was rejected"
        }
        return nil
    }

    /// A successful login can still lack permission to change Actions files.
    /// Keep this separate from password prompts (including the Terminal's
    /// handling of those), and only claim GitHub's explicit HTTPS rejection.
    static func workflowPermissionURL(in output: String) -> String? {
        let lower = output.lowercased()
        guard lower.contains("refusing to allow an oauth app")
                || lower.contains("refusing to allow a personal access token"),
              lower.contains("without `workflow` scope") else { return nil }
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("To "),
                  var url = URLComponents(string: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)),
                  url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com",
                  url.port == nil || url.port == 443 else { continue }
            url.user = nil
            url.password = nil
            return url.string
        }
        return nil
    }

    /// What the code means, for the ones where knowing changes what you do
    /// next. The point of naming 5xx is that it is not the user's repository,
    /// their credentials or their URL — there is nothing here to fix.
    private static func explanation(of code: Int) -> String {
        switch code {
        case 500...599: return " — the server is unavailable; try again shortly"
        case 401:       return " — the credentials were not accepted"
        case 403:       return " — no access to this repository with those credentials"
        case 404:       return " — check the remote URL"
        case 407:       return " — the network proxy wants credentials"
        default:        return ""
        }
    }

    /// The host git named, so the line says which server refused. Falls back
    /// to "the server" rather than dropping the sentence: a repository can
    /// have several remotes, but only one of them just failed.
    private static func server(in output: String) -> String {
        guard let url = accessedURL(in: output),
              let host = URLComponents(string: url)?.host,
              !host.isEmpty
        else { return "the server" }
        return host
    }

    /// The URL from `fatal: unable to access '<url>': …`, which is how git
    /// names the remote it was talking to when the transport itself failed.
    /// http(s) only: this is read by the credentials wall too, and a
    /// username and password are no answer to an ssh URL.
    static func accessedURL(in output: String) -> String? {
        guard let start = output.range(of: "unable to access '") else { return nil }
        let rest = output[start.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        let url = String(rest[..<end])
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return nil }
        return url
    }

    /// Both wordings git puts a status code in: curl's, and the one the
    /// smart-HTTP transport reports when a request fails mid-negotiation
    /// (`error: RPC failed; HTTP 502 curl 22 …`).
    ///
    /// Three digits exactly — `HTTP/2` is not a status code, and the space
    /// in the marker already keeps it out.
    static func httpStatus(in output: String) -> Int? {
        for marker in ["The requested URL returned error: ", "HTTP "] {
            guard let range = output.range(of: marker) else { continue }
            let digits = output[range.upperBound...].prefix { $0.isNumber }
            if digits.count == 3, let code = Int(digits) { return code }
        }
        return nil
    }

    /// curl's wording. ssh says "Could not resolve hostname" instead, and
    /// that one belongs to `GitCredentials.sshFailureHint`, which has advice
    /// about `~/.ssh/config` that would make no sense here.
    private static func unresolvedHost(in output: String) -> String? {
        let marker = "Could not resolve host: "
        guard let start = output.range(of: marker) else { return nil }
        let host = output[start.upperBound...].prefix { !$0.isWhitespace && $0 != "\n" }
        return host.isEmpty ? nil : String(host)
    }
}
