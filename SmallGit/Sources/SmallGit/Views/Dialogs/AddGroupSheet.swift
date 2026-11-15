import SwiftUI

struct AddGroupSheet: View {
    @Bindable var appState: AppState
    @State private var name: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Group").font(.title3.bold())

            TextField("Group name (e.g. Work, Personal)", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    appState.pendingMoveRepoId = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let pendingId = appState.pendingMoveRepoId
                    appState.pendingMoveRepoId = nil
                    Task {
                        await appState.addGroup(name: trimmed)
                        if let pendingId,
                           let repo = appState.allRepositories.first(where: { $0.id == pendingId }) {
                            await appState.moveRepository(repo, toGroup: trimmed)
                        }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 420)
        .background(Color.bgPanel)
    }
}
