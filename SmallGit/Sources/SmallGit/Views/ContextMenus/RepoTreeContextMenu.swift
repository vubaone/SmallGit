import SwiftUI

/// Right-click menu for a file or folder in the sidebar's repository tree.
///
/// Deliberately short. This is a filesystem tree, not the Files panel — it has
/// no staging state to act on, so staging and committing stay over there. What
/// it can do is get you out to the places that *can* act on the path, and the
/// two ways of telling git to look away from one that only make sense here:
/// the Files panel lists files git already reports, never a folder, and never
/// a file sitting quietly unchanged.
struct RepoTreeContextMenu: View {
    let node: RepoTreeNode
    @Bindable var appState: AppState
    /// Re-reads this directory (or the file's parent) from disk. The tree is a
    /// snapshot and nothing watches for changes.
    let onRefresh: () -> Void

    var body: some View {
        Group {
            Button("Open") { appState.openInFinder(path: node.path) }
                .help(node.isDirectory
                      ? "Open this folder in Finder"
                      : "Open with the default application for this file type")

            Button("Reveal in Finder") { appState.revealInFinder(path: node.path) }

            Divider()

            Button("Open in Editor") { appState.openInEditor(path: node.path) }
            if node.isDirectory {
                Button("Open in Terminal") { appState.openInTerminal(path: node.path) }
            }

            Divider()

            Button("Copy Path") { appState.copyToPasteboard(node.path) }
            // Relative to the repository, which is the form that goes into a
            // commit message, an issue, or a `git` command.
            if let relative = relativePath {
                Button("Copy Relative Path") { appState.copyToPasteboard(relative) }
            }

            Divider()

            // Neither touches `.gitignore`. Exclude is for what git doesn't
            // track and shouldn't hear about; the flag is for tracked files
            // whose local edits should stop showing up.
            Button("Exclude Locally") {
                Task { await appState.excludeLocally(path: node.path, isDirectory: node.isDirectory) }
            }
            .help("Ignore on this machine only, through .git/info/exclude — .gitignore is left alone")
            Button("Assume Unchanged") {
                Task { await appState.setAssumeUnchanged(under: node.path, on: true) }
            }
            .help(node.isDirectory
                  ? "Stop git noticing edits to every tracked file in this folder"
                  : "Stop git noticing edits to this file")
            Button("Stop Assuming Unchanged") {
                Task { await appState.setAssumeUnchanged(under: node.path, on: false) }
            }

            Divider()

            Button(node.isDirectory ? "Refresh" : "Refresh Folder") { onRefresh() }
        }
    }

    /// Relative to the repository the tree is under, which need not be the
    /// active one.
    private var relativePath: String? {
        appState.repository(containing: node.path)
            .flatMap { AppState.relativePath(node.path, in: $0) }
    }
}
