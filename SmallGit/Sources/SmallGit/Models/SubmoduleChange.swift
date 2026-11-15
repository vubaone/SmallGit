import Foundation

/// What a moved submodule pointer actually means, in commits.
///
/// The parent repository records one SHA; the checkout is at another. On
/// its own that is two opaque hashes — which is exactly what `git diff`
/// shows for a gitlink, and exactly why it tells nobody anything. The
/// commits between them are the answer to "what changed in there", and
/// they are what this carries.
struct SubmoduleChange: Identifiable, Sendable {
    var id: String { path }

    /// Repo-relative path of the submodule.
    let path: String
    /// Commit the parent repository's index records.
    let recorded: String
    /// Commit the submodule is actually checked out at. Nil when it has no
    /// working tree — an uninitialized submodule has nothing to be at.
    let current: String?

    /// The recorded commit itself — author, date, subject. Nil when the
    /// submodule's object store does not have it, which happens to a
    /// pointer that was never fetched.
    let recordedCommit: GitCommit?
    /// The checked-out commit itself.
    let currentCommit: GitCommit?

    /// Commits in `current` that are not in `recorded` — the `>` lines of
    /// `git diff --submodule=log`. Newest first.
    let added: [GitCommit]
    /// Commits in `recorded` that are not in `current` — the `<` lines.
    /// Non-empty when the checkout went *backwards*, or sideways onto a
    /// branch that diverged.
    let removed: [GitCommit]

    /// Uncommitted work inside the submodule, as its own status rows.
    /// What SmartGit surfaces by listing those files in the parent's Files
    /// view; here they belong to the submodule, and say so.
    let dirtyFiles: [GitFileStatus]

    /// Tracked files modified inside the submodule, uncommitted.
    let hasModifiedContent: Bool
    /// Untracked files inside the submodule.
    let hasUntrackedContent: Bool

    /// True when the recorded and checked-out commits are the same. The
    /// pointer has not moved; anything showing here is uncommitted work
    /// inside the submodule instead.
    var pointerIsUnchanged: Bool { current == nil || current == recorded }

    var isDirty: Bool { hasModifiedContent || hasUntrackedContent }

    /// Short summary for the sheet's header: what committing the parent
    /// right now would actually record.
    var summary: String {
        if current == nil { return "Not initialized" }
        if pointerIsUnchanged {
            if isDirty { return "Uncommitted changes inside" }
            return "At the recorded commit"
        }
        var parts: [String] = []
        if !added.isEmpty { parts.append("\(added.count) ahead") }
        if !removed.isEmpty { parts.append("\(removed.count) behind") }
        if parts.isEmpty { parts.append("moved") }
        return parts.joined(separator: ", ")
    }

    func shortSHA(_ sha: String) -> String { String(sha.prefix(7)) }
}
