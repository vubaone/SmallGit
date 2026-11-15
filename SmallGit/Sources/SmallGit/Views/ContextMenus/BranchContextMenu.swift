import SwiftUI

struct BranchContextMenu: View {
    let branch: GitBranch
    @Bindable var appState: AppState

    private var isCurrent: Bool {
        appState.branchesVM.currentBranch == branch.name
    }

    var body: some View {
        Group {
            Button("Check Out…") {
                Task { await appState.checkout(branch: branch.name, offerFastForward: true) }
            }
            .disabled(isCurrent)

            // Moves *this* branch, not the current one — `main` up to
            // `origin/main` without leaving the feature branch that is about
            // to rebase onto it. The current branch has Pull for that, and a
            // branch checked out in another worktree is git's to refuse.
            if !branch.isRemote, let upstream = branch.upstream {
                Button("Fast-Forward to \(upstream)") {
                    Task { await appState.fastForwardToUpstream(branch: branch.name) }
                }
                .disabled(isCurrent || branch.worktreePath != nil || branch.upstreamGone)
            }

            Divider()

            Button("Merge…") {
                Task { await appState.merge(branch: branch.name) }
            }
            .disabled(isCurrent)

            Button("Rebase…") {
                Task { await appState.rebase(onto: branch.name) }
            }
            .disabled(isCurrent)

            Button("Rebase Interactively onto Here…") {
                Task { await appState.startInteractiveRebase(onto: branch.name) }
            }
            .disabled(isCurrent)

            Divider()

            Button("Push") { Task { await appState.push() } }
                .disabled(!isCurrent || branch.isRemote)

            Button("Push To…") {
                appState.branchPendingPushTo = branch
            }
            .disabled(branch.isRemote)

            Divider()

            Button("Log") {
                Task { await appState.journalVM.setBranchFilter(branch.name) }
            }

            Divider()

            Menu("Reset Current Branch To Here") {
                Button("Soft")  { Task { await appState.resetCurrent(to: branch.name, mode: .soft) } }
                Button("Mixed") { Task { await appState.resetCurrent(to: branch.name, mode: .mixed) } }
                Button("Hard")  { Task { await appState.resetCurrent(to: branch.name, mode: .hard) } }
            }

            Divider()

            Button("New Branch from Here…") {
                appState.branchPendingNewFrom = branch
            }

            Button("Rename…") {
                appState.branchPendingRename = branch
            }
            .disabled(branch.isRemote)

            // Remote branches included: theirs is a push rather than a
            // `git branch -d`, and `requestBranchDeletion` routes it.
            Button(branch.isRemote ? "Delete from Remote…" : "Delete…") {
                Task { await appState.requestBranchDeletion(branch) }
            }
            .disabled(isCurrent)

            Divider()

            Button("Set Tracked Branch…") {
                appState.branchPendingSetUpstream = branch
            }
            .disabled(branch.isRemote)

            Button("Stop Tracking") {
                Task { await appState.unsetUpstream(branch: branch.name) }
            }
            .disabled(branch.isRemote || branch.upstream == nil)

            Divider()

            Button("Copy Name") {
                appState.copyToPasteboard(branch.name)
            }
        }
    }
}
