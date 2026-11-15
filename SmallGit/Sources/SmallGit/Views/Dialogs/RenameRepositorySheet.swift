import SwiftUI

/// Inline editor for the sidebar alias of a registered repository.
/// Alias-only: the folder on disk keeps its original name, this just
/// changes how the repo is labeled in the Repositories panel.
struct RenameRepositorySheet: View {
    @Bindable var appState: AppState
    let target: AppState.RepoRenameTarget

    @State private var name: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Repository").font(.title3.bold())

            Text("Display alias only — the folder on disk isn't renamed.")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)

            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let repoID = target.repoID
                    Task {
                        if let repo = appState.allRepositories.first(where: { $0.id == repoID }) {
                            await appState.renameRepository(repo, to: trimmed)
                        }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
            }
        }
        .padding(18)
        .frame(minWidth: 420)
        .background(Color.bgPanel)
        .onAppear { name = target.currentName }
    }

    private var disabled: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == target.currentName
    }
}
