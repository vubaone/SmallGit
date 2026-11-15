import SwiftUI

/// Gives a stash a message of the user's own. Starts from the part after
/// git's "On <branch>:" prefix — the prefix is kept on save, so the entry
/// still says which branch it came from.
struct RenameStashSheet: View {
    let stash: GitStash
    @Bindable var appState: AppState

    @State private var newMessage: String = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var messageFocused: Bool

    private var trimmed: String {
        newMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canRename: Bool {
        !trimmed.isEmpty && trimmed != GitService.stashSubjectDescription(stash.message)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Stash").font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("stash@{\(stash.index)}")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                Text(stash.message)
                    .scaledFont(12, design: .monospaced)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.bgPanelHeader)
                    .cornerRadius(4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("New message")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                TextField("", text: $newMessage)
                    .textFieldStyle(.roundedBorder)
                    .focused($messageFocused)
                    .onSubmit { if canRename { commit() } }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename)
            }
        }
        .padding(18)
        .frame(minWidth: 420)
        .background(Color.bgPanel)
        .onAppear {
            newMessage = GitService.stashSubjectDescription(stash.message)
            messageFocused = true
        }
    }

    private func commit() {
        Task {
            await appState.stashRename(index: stash.index, message: trimmed)
            dismiss()
        }
    }
}
