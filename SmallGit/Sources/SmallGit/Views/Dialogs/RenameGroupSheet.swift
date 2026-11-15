import SwiftUI

/// Inline editor for renaming a Repositories-panel group. Mirrors the
/// `AddGroupSheet` look-and-feel so add and rename feel like one
/// family of actions.
struct RenameGroupSheet: View {
    @Bindable var appState: AppState
    let originalName: String

    @State private var name: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Group").font(.title3.bold())

            Text("Currently \"\(originalName)\"")
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
                    Task {
                        await appState.renameGroup(from: originalName, to: trimmed)
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
        .onAppear { name = originalName }
    }

    private var disabled: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == originalName
    }
}
