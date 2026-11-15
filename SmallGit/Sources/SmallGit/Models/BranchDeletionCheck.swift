import Foundation

/// The answer to "is this branch safe to delete?", asked of git before the
/// delete runs so the confirmation dialog can describe the consequences
/// instead of reporting an error afterwards.
struct BranchDeletionCheck: Sendable, Hashable {
    /// Ref that already contains the branch ("main", "origin/feature"), or
    /// nil when nothing does — the case `git branch -d` refuses.
    let mergedInto: String?
    /// Commits on the branch that aren't reachable from `comparedTo`.
    let unmergedCount: Int
    /// Ref `unmergedCount` was measured against — normally the current branch.
    let comparedTo: String

    /// True when `git branch -d` will accept the delete without `-D`.
    var isFullyMerged: Bool { mergedInto != nil }

    /// True when the branch is contained in its upstream but not in the
    /// current branch — safe to delete, yet still carrying work the branch
    /// you're standing on has never seen.
    var isMergedElsewhere: Bool {
        isFullyMerged && mergedInto != comparedTo
    }
}
