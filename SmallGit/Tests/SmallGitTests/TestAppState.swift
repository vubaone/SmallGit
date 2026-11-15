import Foundation
@testable import SmallGit

/// An `AppState` whose config writes land in a throwaway directory.
///
/// `AppState()` defaults to `ConfigService.shared`, which points at the real
/// `~/Library/Application Support/SmallGit`. Any test that nudges a setting
/// — a zoom bump persists on every press — then writes a default-constructed
/// `AppConfig` over the preferences of whoever ran the suite, and does it
/// while their copy of the app may be running and reading the same file.
/// Build test states through this rather than calling `AppState()` directly.
@MainActor
func makeIsolatedAppState(
    git: GitService = .shared,
    platform: (any PlatformServices)? = nil
) -> AppState {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SmallGitTests-\(UUID().uuidString)", isDirectory: true)
    // Defaults to the recording double rather than `MacPlatformServices`:
    // a test that reaches a confirmation would otherwise put a real modal
    // alert on screen and wedge the suite waiting for a click.
    return AppState(
        git: git,
        config: ConfigService(supportDirectory: dir),
        platform: platform ?? RecordingPlatformServices()
    )
}

/// A `PlatformServices` that answers dialogs from a script and records what
/// it was asked, so a test can assert on the wording a user would have read
/// — and, for the confirmations that gate a dangerous command, that the
/// command doesn't run when the answer is no.
///
/// Every method is inert otherwise: the default is to decline, which is the
/// safe answer for a test that didn't expect to be asked at all.
@MainActor
final class RecordingPlatformServices: PlatformServices {
    struct Warning {
        let title: String
        let message: String
        let primaryButton: String
    }

    /// Answer handed to the next `confirmWarning`.
    var confirmWarningAnswer = false
    /// Answer handed to the next `resolvePushRejection`.
    var pushRejectionAnswer: PushRejectionChoice = .cancel
    private(set) var warnings: [Warning] = []
    private(set) var pushRejections: [(branch: String, remote: String)] = []

    var repositoryFoldersToPick: [URL] = []
    func pickRepositoryFolders() -> [URL] { repositoryFoldersToPick }

    func confirmWarning(title: String, message: String, primaryButton: String) -> Bool {
        warnings.append(Warning(title: title, message: message, primaryButton: primaryButton))
        return confirmWarningAnswer
    }

    func resolvePushRejection(branch: String, remote: String) -> PushRejectionChoice {
        pushRejections.append((branch, remote))
        return pushRejectionAnswer
    }

    /// Answer handed to the next `resolveBehindCheckout`.
    var behindCheckoutAnswer: BehindCheckoutChoice = .cancel
    private(set) var behindCheckouts: [(branch: String, upstream: String, behind: Int)] = []

    func resolveBehindCheckout(branch: String, upstream: String, behind: Int) -> BehindCheckoutChoice {
        behindCheckouts.append((branch, upstream, behind))
        return behindCheckoutAnswer
    }

    var divergedBranchAnswer: DivergedBranchChoice = .cancel
    private(set) var divergedBranches: [(branch: String, upstream: String, ahead: Int, behind: Int)] = []

    func resolveDivergedBranch(branch: String, upstream: String, ahead: Int, behind: Int) -> DivergedBranchChoice {
        divergedBranches.append((branch, upstream, ahead, behind))
        return divergedBranchAnswer
    }

    /// Answer handed to the next `resolveRewrittenBaseRebase`.
    var rewrittenRebaseAnswer: RewrittenRebaseChoice = .cancel
    private(set) var rewrittenRebases: [(onto: String, staleSubjects: [String], ownCount: Int)] = []

    func resolveRewrittenBaseRebase(
        onto: String,
        staleSubjects: [String],
        ownCount: Int
    ) -> RewrittenRebaseChoice {
        rewrittenRebases.append((onto, staleSubjects, ownCount))
        return rewrittenRebaseAnswer
    }

    /// Answer handed to the next `resolveMerge`.
    var mergeAnswer: MergeChoice = .cancel
    private(set) var merges: [(branch: String, current: String, canFastForward: Bool)] = []

    func resolveMerge(branch: String, into current: String, canFastForward: Bool) -> MergeChoice {
        merges.append((branch, current, canFastForward))
        return mergeAnswer
    }

    var revertAnswer: RevertChoice = .cancel
    private(set) var reverts: [(commit: String, canCommit: Bool)] = []

    func resolveRevert(commit: String, canCommit: Bool) -> RevertChoice {
        reverts.append((commit, canCommit))
        return revertAnswer
    }

    func revealInFinder(path: String) {}
    func openInFinder(path: String) {}
    func openInTerminal(path: String) {}
    func openInEditor(path: String, appPath: String?, bundleIDs: [String]) {}
    func copyToPasteboard(_ string: String) {}
}
