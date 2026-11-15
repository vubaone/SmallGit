import SwiftUI

struct AddTagSheet: View {
    let target: AppState.TagTarget
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var message = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Tag")
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 3) {
                Text(target.subject)
                    .scaledFont(12, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(target.shortHash)
                    .scaledFont(11, design: .monospaced)
                    .foregroundStyle(Color.textSecondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .scaledFont(11, weight: .semibold)
                TextField("v1.0.0", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Message")
                    .scaledFont(11, weight: .semibold)
                TextEditor(text: $message)
                    .scaledFont(12, design: .monospaced)
                    .frame(minHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.textDisabled.opacity(0.4), lineWidth: 0.5)
                    )
                Text("Leave empty to create a lightweight tag.")
                    .scaledFont(10)
                    .foregroundStyle(Color.textSecondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Tag") {
                    let finalName = trimmedName
                    let finalMessage = trimmedMessage.isEmpty ? nil : trimmedMessage
                    dismiss()
                    Task {
                        await appState.createTag(
                            name: finalName,
                            message: finalMessage,
                            at: target.hash
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 420)
        .background(Color.bgPanel)
    }
}
