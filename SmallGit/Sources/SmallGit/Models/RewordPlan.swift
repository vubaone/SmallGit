import Foundation

/// Everything `RewordCommitSheet` needs to let the user rewrite one
/// commit's message. Built by `AppState.prepareReword` from the Journal's
/// context menu; consumed by `AppState.performReword`.
///
/// Rewording is a history rewrite like a squash, not an edit in place:
/// the commit gets a new hash and every commit after it is replayed onto
/// it. That is what makes the published-commit question matter — see
/// `rewritesPublishedCommits`.
struct PendingReword: Identifiable, Sendable {
    let id = UUID()
    /// The commit whose message is being rewritten.
    let hash: String
    /// Abbreviated hash, for labels and the status line.
    let shortHash: String
    /// The ref the rebase replays onto — the commit's parent (`<hash>^`),
    /// or `--root` when it has none.
    let onto: String
    /// The commit's current message (`%B`), pre-filled into the editor.
    let originalMessage: String
    /// How many commits sit on top of this one and will be replayed onto
    /// the reworded commit — each of them gets a new hash too. Zero when
    /// the commit is HEAD itself.
    let commitsReplayedOnTop: Int
    /// True when the commit is already reachable from the branch's
    /// upstream, i.e. it has been pushed. The sheet warns and the user
    /// confirms before the rewrite. The remote stays unchanged until the
    /// user explicitly chooses how to publish the new history.
    let rewritesPublishedCommits: Bool
}
