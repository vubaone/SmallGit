import Foundation

/// A pending request for credentials or additional GitHub permissions.
struct CredentialRequest: Identifiable, Hashable, Sendable {
    /// The operation that hit the wall — "Pull", "Push", "Fetch" — so the
    /// dialog can say what is waiting on the answer.
    let action: String
    /// The server URL, shown so the user can check who is asking before
    /// signing in. Workflow-rejection URLs have embedded credentials removed.
    let url: String
    let scheme: String
    let host: String
    /// Account git already knew about, from a `https://me@host` remote.
    let suggestedUsername: String?
    /// Repository the answer should be stored through, or nil for a clone —
    /// which has no repository yet, and whose credentials therefore belong
    /// to global config rather than to whichever repo happens to be
    /// selected behind the dialog.
    let repoPath: String?
    /// Requested only after GitHub explicitly refuses a workflow-file push.
    var requiresWorkflowScope = false

    var id: String { "\(action):\(url)" + (requiresWorkflowScope ? ":workflow" : "") }

    /// Other Git servers keep their existing credential flow. Never infer
    /// GitHub support from a substring of an untrusted remote hostname.
    var supportsGitHubCLI: Bool {
        scheme.lowercased() == "https" && host.lowercased() == "github.com"
    }
}
