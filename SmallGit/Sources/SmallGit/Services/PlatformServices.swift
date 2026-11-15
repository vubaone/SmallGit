import Foundation

/// How the user chose to reconcile a push that the remote rejected
/// because it has commits the local branch doesn't (non-fast-forward).
enum PushRejectionChoice: Sendable {
    case pullThenPush
    case forcePush
    case cancel
}

/// What to do when checking out a branch whose upstream is ahead of it.
enum BehindCheckoutChoice: Sendable {
    case checkOutAndFastForward
    case checkOutOnly
    case cancel
}

/// How to integrate an upstream when a requested fast-forward cannot keep
/// both sides' commits without rebasing or merging.
enum DivergedBranchChoice: Sendable {
    case rebase
    case merge
    case cancel
}

/// What to replay when rebasing onto a branch that was rewritten after the
/// current one was made from it.
enum RewrittenRebaseChoice: Sendable {
    /// Only the current branch's own commits, since it left the old base.
    case ownOnly
    /// Everything since the merge-base, old base commits included — git's
    /// plain `rebase <onto>`.
    case all
    case cancel
}

/// How to land a branch being merged into the current one — the buttons of
/// SmartGit's Merge dialog.
enum MergeChoice: Sendable {
    case fastForward
    /// Merge and commit in one go.
    case mergeCommit
    /// Merge, but stop before committing so the result can be checked first.
    case workingTree
    case cancel
}

enum RevertChoice: Sendable {
    case commit
    case workingTree
    case cancel
}

@MainActor
protocol PlatformServices {
    func pickRepositoryFolders() -> [URL]
    func confirmWarning(title: String, message: String, primaryButton: String) -> Bool
    func resolvePushRejection(branch: String, remote: String) -> PushRejectionChoice
    func resolveBehindCheckout(branch: String, upstream: String, behind: Int) -> BehindCheckoutChoice
    func resolveDivergedBranch(branch: String, upstream: String, ahead: Int, behind: Int) -> DivergedBranchChoice
    func resolveRewrittenBaseRebase(onto: String, staleSubjects: [String], ownCount: Int) -> RewrittenRebaseChoice
    /// `canFastForward` adds Fast-Forward to the choices; it is only offered
    /// when the current branch is wholly contained in `branch`.
    func resolveMerge(branch: String, into current: String, canFastForward: Bool) -> MergeChoice
    /// An existing staged change prevents an immediate revert commit.
    func resolveRevert(commit: String, canCommit: Bool) -> RevertChoice
    func revealInFinder(path: String)
    func openInFinder(path: String)
    func openInTerminal(path: String)
    /// Opens `path` in `appPath` when given and present, else the first
    /// installed app of `bundleIDs`, else the OS default opener.
    func openInEditor(path: String, appPath: String?, bundleIDs: [String])
    func copyToPasteboard(_ string: String)
}
