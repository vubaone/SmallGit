import Foundation

/// Everything `SquashCommitsSheet` needs to let the user review and edit a
/// pending range-squash before it runs. Built by `AppState.prepareSquash`
/// from a contiguous Journal multi-selection; consumed by
/// `AppState.performSquash`.
struct PendingSquash: Identifiable, Sendable {
    let id = UUID()
    /// The ref the rebase replays onto — the parent of the oldest selected
    /// commit (`<pickHash>^`).
    let onto: String
    /// Oldest selected commit. Kept as `pick`; everything else in the range
    /// folds into it.
    let pickHash: String
    /// Newest selected commit. The amend step is inserted right after this
    /// row so it rewrites the freshly-squashed commit.
    let lastSelectedHash: String
    /// Every selected commit's hash — used to decide which rows become
    /// `fixup` while building the rebase todo.
    let selectedHashes: Set<String>
    /// How many commits are being combined (for labels).
    let count: Int
    /// True when at least one selected commit is already reachable from
    /// the branch upstream. A successful squash rewrites public history,
    /// so the user should be offered a force-with-lease push afterward.
    let rewritesPublishedCommits: Bool
    /// Pre-filled combined message: each commit's full message stacked
    /// oldest-first. The user can edit this freely.
    let combinedMessage: String
    /// Authorship choices — one per selected commit. The sheet's dropdown
    /// picks which identity (and author date) the squashed commit inherits.
    let authors: [SquashAuthorOption]
    /// Individual commit messages, offered in the "Select" menu so the user
    /// can drop one in as the basis for the combined message.
    let messageOptions: [SquashMessageOption]
}

/// One authorship option in the squash dialog's dropdown.
struct SquashAuthorOption: Identifiable, Hashable, Sendable {
    /// Commit hash — stable id for the picker selection.
    let id: String
    /// Human-readable label, e.g. "2026-05-29 16:14 - VUBA".
    let display: String
    let name: String
    let email: String
    /// Strict-ISO author date (`%aI`), suitable for `git commit --date`.
    let dateISO: String
}

/// One commit's full message, offered in the "Select" menu.
struct SquashMessageOption: Identifiable, Hashable, Sendable {
    /// Commit hash — stable id.
    let id: String
    /// Short label shown in the menu (the commit subject).
    let label: String
    /// The full commit message to drop into the editor.
    let message: String
}
