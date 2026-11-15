import SwiftUI

struct RenameBranchSheet: View {
    let branch: GitBranch
    @Bindable var appState: AppState

    @State private var newName: String = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    private var trimmed: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canRename: Bool {
        !trimmed.isEmpty && trimmed != branch.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Branch").font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Current name")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                Text(branch.name)
                    .scaledFont(12, design: .monospaced)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.bgPanelHeader)
                    .cornerRadius(4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("New name")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                TextField("", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
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
            newName = branch.name
            nameFocused = true
        }
    }

    private func commit() {
        Task {
            await appState.renameBranch(from: branch.name, to: trimmed)
            dismiss()
        }
    }
}
