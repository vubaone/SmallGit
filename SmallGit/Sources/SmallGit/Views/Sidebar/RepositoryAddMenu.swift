import SwiftUI

/// Repository creation controls, shared by the sidebar and view-level tests.
struct RepositoryAddMenu: View {
    @Bindable var appState: AppState

    var body: some View {
        Menu {
            Button("Add Group…") { appState.showAddGroupSheet = true }
                .accessibilityIdentifier("repositories.addGroup")
            AddRepositoryButton(appState: appState)
            Button("Clone…") { appState.showCloneSheet = true }
                .accessibilityIdentifier("repositories.clone")
        } label: {
            Image(systemName: "plus")
                .scaledFont(11, weight: .semibold)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add repository")
    }
}

struct AddRepositoryButton: View {
    @Bindable var appState: AppState
    var targetGroup: String? = nil
    var identifier = "repositories.add"

    var body: some View {
        Button("Add Existing Folders…") {
            appState.presentOpenRepository(targetGroup: targetGroup)
        }
        .accessibilityIdentifier(identifier)
    }
}
