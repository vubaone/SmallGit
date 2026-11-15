import SwiftUI

struct JournalContextMenu: View {
    let commit: GitCommit
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    /// Local branch names, for picking the label a decorated commit should
    /// wear. See `GitCommit.branchLabel(knownLocal:)`.
    private var localBranchNames: Set<String> {
        Set(appState.branchesVM.localBranches.map(\.name))
    }

    var body: some View {
        Group {
            Button("Log") {
                // Select the right-clicked commit so the dedicated Log
                // window opens already focused on it.
                appState.journalVM.selectedCommitID = commit.id
                openWindow(id: "log")
            }
            .keyboardShortcut("l", modifiers: .command)

            // Range squash: offered once the user has multi-selected a run
            // of commits (cmd / shift click) that includes the one they
            // right-clicked. When the run can't be folded the row is still
            // drawn, disabled, saying which of the three conditions it
            // fails — see `JournalViewModel.squashAvailability`.
            switch appState.journalVM.squashAvailability(rightClicked: commit) {
            case .ready(let range):
                Divider()
                Button("Squash \(range.count) Commits…") {
                    Task { await appState.prepareSquash(range) }
                }
            case .blocked(let reason):
                Divider()
                Button(reason) {}
                    .disabled(true)
            case .unavailable:
                EmptyView()
            }

            // Change Message rewrites HEAD, so it is offered only where that
            // is what it would do — see `JournalViewModel.canChangeMessage`.
            if appState.journalVM.canChangeMessage(of: commit) {
                Divider()

                Button("Change Message…") {
                    Task { await appState.prepareReword(commit) }
                }
            }

            Divider()

            Button("Cherry-Pick") {
                Task { await appState.cherryPick(commit.hash) }
            }

            Button("Revert…") {
                Task { await appState.revertCommit(commit) }
            }

            // Fixup workflow — HEAD's own history only, for the reasons in
            // `JournalViewModel.canFixup`.
            if appState.journalVM.canFixup(commit) {
                Divider()

                Button("Commit Staged as Fixup of \(commit.shortHash)") {
                    Task { await appState.commitFixup(of: commit.hash) }
                }

                Button("Autosquash Fixups from Here") {
                    Task { await appState.autosquashFixups(from: commit) }
                }
            }

            Divider()

            Menu("Reset Current Branch To Here") {
                Button("Soft")  { Task { await appState.resetCurrent(to: commit.hash, mode: .soft) } }
                Button("Mixed") { Task { await appState.resetCurrent(to: commit.hash, mode: .mixed) } }
                Button("Hard")  { Task { await appState.resetCurrent(to: commit.hash, mode: .hard) } }
            }

            Divider()

            Button("Create Patch…") {
                appState.patchSource = .commit(
                    hash: commit.hash,
                    subject: commit.subject
                )
            }

            Divider()

            Button("Add Tag Here…") {
                appState.pendingTagTarget = AppState.TagTarget(
                    hash: commit.hash,
                    subject: commit.subject
                )
            }

            // `git rebase -i <commit>`: the clicked commit is the new base
            // and stays put; what gets replayed onto it goes through the
            // planner sheet, one pick / squash / fixup / drop per commit.
            //
            // Two wordings for the one command, because the range it replays
            // depends on where the commit sits and the difference is the whole
            // point of the click. "From Here" reorders your own recent work.
            // "Onto Here" moves your branch onto another line of history —
            // that branch becomes the base and your commits land on its end.
            // Drawn disabled with the reason when the range isn't one git can
            // replay — see `JournalViewModel.interactiveRebaseAvailability`.
            switch appState.journalVM.interactiveRebaseAvailability(from: commit) {
            case .fromHere:
                Button("Rebase Interactive From Here…") {
                    Task { await appState.startInteractiveRebase(onto: commit.hash, display: commit.shortHash) }
                }
                .help("Keep this commit as the base and replay everything after it.")
            case .onto:
                Button("Rebase Interactive Onto Here…") {
                    // The hash is still what git gets — a branch name can go
                    // ambiguous, a SHA never does — but the sheet and the log
                    // say the branch, which is what the user pointed at.
                    let label = commit.branchLabel(knownLocal: localBranchNames) ?? commit.shortHash
                    Task { await appState.startInteractiveRebase(onto: commit.hash, display: label) }
                }
                .help("Take this commit as the base and replay your commits since the two lines diverged on top of it.")
            case .blocked(let reason):
                Button(reason) {}
                    .disabled(true)
            }

            Divider()

            Button("Use Message for Commit") {
                appState.copyToPasteboard(commit.subject)
            }

            Button("Copy ID") {
                appState.copyToPasteboard(commit.hash)
            }
        }
    }
}
