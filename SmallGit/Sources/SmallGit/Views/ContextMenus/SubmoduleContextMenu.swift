import SwiftUI

/// Right-click menu for a submodule row.
///
/// Ordered by what a submodule actually needs day to day: get it onto the
/// recorded commit, then go work inside it, then the rarer registration
/// operations.
struct SubmoduleContextMenu: View {
    let submodule: GitSubmodule
    @Bindable var appState: AppState

    var body: some View {
        Group {
            Button(submodule.state == .uninitialized ? "Initialize and Clone" : "Update") {
                Task { await appState.updateSubmodules(paths: [submodule.path]) }
            }
            .help("git submodule update --init — checks this submodule out at the commit this repository records")

            Button("Open as Repository") {
                Task { await appState.openSubmoduleAsRepository(submodule) }
            }
            .disabled(!submodule.isCloned)
            .help(submodule.isCloned
                  ? "Add it to the sidebar so its own branches and history are available"
                  : "Nothing to open until it has been cloned")

            Divider()

            Button("Sync URLs from .gitmodules") {
                Task { await appState.syncSubmodules() }
            }
            .help("git submodule sync — after the upstream URL changes")

            Button("Remove Working Tree…", role: .destructive) {
                Task { await appState.deinitSubmodule(submodule) }
            }
            .disabled(!submodule.isCloned)
            .help("git submodule deinit — empties the checkout but keeps the submodule registered")

            Divider()

            Button("Reveal in Finder") {
                if let repo = appState.activeRepo?.path {
                    appState.revealInFinder(path: submodule.absolutePath(in: repo))
                }
            }
            .disabled(!submodule.isCloned)
            Button("Copy Path") { appState.copyToPasteboard(submodule.path) }
            if let url = submodule.url {
                Button("Copy URL") { appState.copyToPasteboard(url) }
            }
        }
    }
}
