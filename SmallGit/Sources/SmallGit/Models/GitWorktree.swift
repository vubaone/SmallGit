import Foundation

/// One linked working tree from `git worktree list --porcelain`.
/// The first entry git prints is always the main worktree.
struct GitWorktree: Codable, Identifiable, Hashable, Sendable {
    var id: String { path }
    /// Absolute path of the worktree's root folder.
    let path: String
    /// SHA the worktree's HEAD points at. Empty for a bare entry.
    let headSHA: String
    /// Checked-out branch (short name, `refs/heads/` stripped);
    /// nil when the worktree is on a detached HEAD or bare.
    let branch: String?
    /// `true` for the repository's main worktree (listed first; it
    /// cannot be removed).
    let isMain: Bool
    /// `true` when the worktree is locked (`git worktree lock`) —
    /// remove requires `--force` and we surface the reason if given.
    let isLocked: Bool
    /// Lock reason, when git reported one.
    let lockReason: String?
    /// `true` when git flags the entry prunable (its folder is gone).
    let isPrunable: Bool
    /// `true` for a bare repository entry.
    let isBare: Bool

    var shortSHA: String { String(headSHA.prefix(7)) }
    /// Last path component — what users recognise the worktree by.
    var name: String {
        (path as NSString).lastPathComponent
    }
}
