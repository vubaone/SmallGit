import SwiftUI

struct StashMessageSheet: View {
    @Bindable var appState: AppState
    @State private var message: String = ""
    @State private var includeUntracked: Bool = false
    @State private var keepIndex: Bool = false
    @State private var keepWorkingTree: Bool = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var messageFocused: Bool

    /// Non-nil when the dialog was opened from the Files context menu's
    /// "Stash Selected…" — the stash is then limited to these paths.
    private var scope: AppState.PendingStashScope? { appState.pendingStashScope }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(scope == nil ? "Save Stash" : "Stash Selected Files")
                .font(.title3.bold())

            if let scope {
                Text("Only the \(scope.paths.count) selected file\(scope.paths.count == 1 ? "" : "s") will be stashed — other changes stay in the working tree.")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Stash message (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
                .focused($messageFocused)

            Toggle("Include untracked files", isOn: $includeUntracked)
                .toggleStyle(.checkbox)
                .scaledFont(11)

            Toggle("Keep staged changes in the index (--keep-index)", isOn: $keepIndex)
                .toggleStyle(.checkbox)
                .scaledFont(11)
                .disabled(keepWorkingTree)
                .help("Stashes the changes but leaves anything already staged in the index — useful for testing exactly what you're about to commit.")

            Toggle("Leave the working tree as it is (snapshot)", isOn: $keepWorkingTree)
                .toggleStyle(.checkbox)
                .scaledFont(11)
                .disabled(scope != nil)
                .help(scope == nil
                      ? "Records the stash without reverting anything: staged, unstaged and untracked changes all stay exactly where they are, so the entry is a point to come back to rather than a way to clear the decks."
                      : "A snapshot always covers the whole working tree, so it cannot be limited to the selected files.")

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(keepWorkingTree ? "Snapshot" : "Stash") {
                    let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    let paths = scope?.paths ?? []
                    let untracked = includeUntracked
                    let keep = keepIndex
                    let snapshot = keepWorkingTree
                    Task {
                        if snapshot {
                            await appState.stashSnapshot(
                                message: msg.isEmpty ? nil : msg,
                                includeUntracked: untracked
                            )
                        } else {
                            await appState.stashSave(
                                message: msg.isEmpty ? nil : msg,
                                includeUntracked: untracked,
                                keepIndex: keep,
                                paths: paths
                            )
                        }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 420)
        .background(Color.bgPanel)
        .onAppear {
            // Untracked selections need -u or git silently skips them.
            if let scope, scope.includesUntracked {
                includeUntracked = true
            }
            if let preset = appState.pendingStashPreset {
                includeUntracked = includeUntracked || preset.includeUntracked
                keepWorkingTree = preset.snapshot && scope == nil
            }
            messageFocused = true
        }
        .onDisappear {
            appState.pendingStashScope = nil
            appState.pendingStashPreset = nil
        }
    }
}
