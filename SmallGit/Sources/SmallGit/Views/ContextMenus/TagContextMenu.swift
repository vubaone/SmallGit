import SwiftUI

/// Right-click actions for a tag row in the Branches sidebar.
struct TagContextMenu: View {
    let tag: String
    @Bindable var appState: AppState

    var body: some View {
        Group {
            Button("Push Tag") {
                Task { await appState.pushTag(tag) }
            }

            Button("Delete…") {
                Task { await appState.deleteTag(tag) }
            }

            Divider()

            Button("Copy Name") {
                appState.copyToPasteboard(tag)
            }
        }
    }
}
