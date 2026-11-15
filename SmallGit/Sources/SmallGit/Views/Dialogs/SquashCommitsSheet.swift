import SwiftUI

/// Confirmation dialog for a Journal range squash. Shows the combined
/// commit message (pre-filled with every selected commit's message,
/// oldest-first) for the user to edit, a "Select" menu to drop any single
/// commit's message in as a starting point, and an authorship dropdown that
/// picks which selected commit's identity + date the squashed commit
/// inherits. Confirming runs `AppState.performSquash`.
struct SquashCommitsSheet: View {
    let plan: PendingSquash
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var message: String
    @State private var authorID: String

    init(plan: PendingSquash, appState: AppState) {
        self.plan = plan
        self.appState = appState
        self._message = State(initialValue: plan.combinedMessage)
        // Default authorship to the oldest selected commit — the one git
        // keeps by default when squashing.
        self._authorID = State(initialValue: plan.pickHash)
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedAuthor: SquashAuthorOption? {
        plan.authors.first { $0.id == authorID } ?? plan.authors.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Squash multiple commits")
                .font(.title3.bold())
            Text("The selected \(plan.count) commits will be replaced by one squashed commit containing all changes of the individual commits.")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text("Commit Message:")
                    .scaledFont(11, weight: .semibold)
                Spacer()
                Menu("Select") {
                    ForEach(plan.messageOptions) { option in
                        Button(option.label) { message = option.message }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Replace the message with one commit's message")
            }

            TextEditor(text: $message)
                .scaledFont(12, design: .monospaced)
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.textDisabled.opacity(0.4), lineWidth: 0.5)
                )

            HStack(spacing: 8) {
                Text("Authorship:")
                    .scaledFont(11, weight: .semibold)
                Picker("", selection: $authorID) {
                    ForEach(plan.authors) { author in
                        Text(author.display).tag(author.id)
                    }
                }
                .labelsHidden()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Squash Commits") {
                    let msg = message
                    let author = selectedAuthor
                    dismiss()
                    Task { await appState.performSquash(plan, message: msg, author: author) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedMessage.isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 460)
        .background(Color.bgPanel)
    }
}
