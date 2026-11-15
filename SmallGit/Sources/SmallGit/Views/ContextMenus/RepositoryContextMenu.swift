import SwiftUI

struct RepositoryContextMenu: View {
    let repo: RepositoryEntry
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            // For a folder that isn't a git repo yet, lead with the action
            // that fixes that — running `git init` here (via the same sheet
            // the drag-in flow uses, so the user can also wire up a remote).
            if appState.availability(for: repo) == .notRepository {
                Button("Init Git Here") {
                    Task { await appState.initRepositoryInPlace(repo) }
                }
                Divider()
            }

            Button("Open Repository") {
                Task { await appState.selectRepo(repo) }
            }

            Divider()

            Menu("Open") {
                Button("Reveal in Finder") { appState.revealInFinder(path: repo.path) }
                Button("Open in Terminal") { appState.openInTerminal(path: repo.path) }
                Button("Open in Editor") { appState.openInEditor(path: repo.path) }
            }

            Button("Close Repository") {
                appState.closeActiveRepo()
            }
            .disabled(appState.activeRepo?.id != repo.id)

            Divider()

            Button("Commit…") {
                appState.showCommitDialog = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(appState.activeRepo?.id != repo.id)

            Button("Pull (Merge)") { Task { await appState.pull(rebase: false) } }
                .disabled(appState.activeRepo?.id != repo.id)
            Button("Pull (Rebase)") { Task { await appState.pull(rebase: true) } }
                .disabled(appState.activeRepo?.id != repo.id)
            Button("Push") { Task { await appState.push() } }
                .disabled(appState.activeRepo?.id != repo.id)
            Button("Synchronize") { Task { await appState.sync() } }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(appState.activeRepo?.id != repo.id)

            Divider()

            // SmartGit opens the Log straight from a repository's context
            // menu, and it's the one window you want for a repo you
            // aren't currently in — so instead of being disabled off the
            // active repo like the actions above, it switches to the
            // clicked one first.
            Button("Log") {
                Task {
                    if appState.activeRepo?.id != repo.id {
                        await appState.selectRepo(repo)
                    }
                    openWindow(id: "log")
                }
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!appState.availability(for: repo).isAvailable)

            Button("Refresh") {
                Task { await appState.refreshAllForced() }
            }
            .disabled(appState.activeRepo?.id != repo.id)

            Button("Browse Reflog…") {
                appState.showReflogSheet = true
            }
            .disabled(appState.activeRepo?.id != repo.id)

            Button("Worktrees…") {
                appState.showWorktreesSheet = true
            }
            .disabled(appState.activeRepo?.id != repo.id)

            Button("Clean Up…") {
                Task { await appState.cleanUpRepository() }
            }
            .disabled(appState.activeRepo?.id != repo.id)
            .help("Prune dead remote-tracking refs and stale worktree records, then git gc --prune=now to repack and shrink the repository.")

            Menu("Move To") {
                let current = appState.groupName(for: repo)
                ForEach(appState.repositoriesConfig.groups) { group in
                    Button("Group ‘\(group.name)’") {
                        Task { await appState.moveRepository(repo, toGroup: group.name) }
                    }
                    .disabled(group.name == current)
                }
                Button("No Group") {
                    Task { await appState.moveRepository(repo, toGroup: nil) }
                }
                .disabled(current == nil)

                Divider()

                Button("New Group…") {
                    appState.pendingMoveRepoId = repo.id
                    appState.showAddGroupSheet = true
                }
            }

            Button(repo.isFavorite ? "Unmark Favorite" : "Mark as Favorite") {
                Task { await appState.toggleFavorite(repo) }
            }

            // Alias-only rename — does not touch the working-tree
            // folder name, just the sidebar label. Wedged here
            // alongside Favorite since both are "presentation"
            // settings on the entry rather than git operations.
            Button("Rename…") {
                appState.pendingRepoRename = AppState.RepoRenameTarget(
                    repoID: repo.id,
                    currentName: repo.name
                )
            }
            .keyboardShortcut(.return, modifiers: [])

            Divider()

            Button("Remove…") {
                Task { await appState.removeRepository(repo) }
            }

            Divider()

            Button("Copy Path") {
                appState.copyToPasteboard(repo.path)
            }

            Divider()

            Button("Settings…") {
                appState.pendingRepoSettings = repo
            }
        }
    }
}
