import SwiftUI

/// Dialog for changing one commit's message — SmartGit's "Change Message".
///
/// Opens on the commit's current message so the user edits rather than
/// retypes, and says plainly what the change costs: the commit is rewritten
/// under a new hash and everything above it is replayed. When the commit has
/// already been pushed, the local and remote histories will diverge.
/// `AppState.performReword` asks for confirmation before rewriting published
/// history and leaves publishing the result as a separate user action.
struct RewordCommitSheet: View {
    let plan: PendingReword
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var message: String

    init(plan: PendingReword, appState: AppState) {
        self.plan = plan
        self.appState = appState
        self._message = State(initialValue: plan.originalMessage)
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nothing to do when the message hasn't actually changed — rewriting
    /// history to arrive at the same message costs the user a new hash and
    /// a force push for no gain.
    private var isUnchanged: Bool {
        trimmedMessage == plan.originalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var replayNote: String {
        switch plan.commitsReplayedOnTop {
        case 0:
            return "Commit \(plan.shortHash) will be rewritten and gets a new ID."
        case 1:
            return "Commit \(plan.shortHash) will be rewritten and gets a new ID. The 1 commit on top of it is replayed onto it and gets a new ID too."
        default:
            return "Commit \(plan.shortHash) will be rewritten and gets a new ID. The \(plan.commitsReplayedOnTop) commits on top of it are replayed onto it and get new IDs too."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change commit message")
                .font(.title3.bold())
            Text(replayNote)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if plan.rewritesPublishedCommits {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("This commit has already been pushed. Changing its message rewrites local history and leaves the remote unchanged. The graph will show both versions; you can force push or create a new branch afterward.")
                        .scaledFont(11)
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Text("Commit Message:")
                .scaledFont(11, weight: .semibold)

            TextEditor(text: $message)
                .scaledFont(12, design: .monospaced)
                .frame(minHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.textDisabled.opacity(0.4), lineWidth: 0.5)
                )

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Change Message") {
                    let msg = message
                    dismiss()
                    Task { await appState.performReword(plan, message: msg) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedMessage.isEmpty || isUnchanged)
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 420)
        .background(Color.bgPanel)
    }
}
