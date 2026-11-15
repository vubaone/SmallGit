import SwiftUI

/// Presented when the user drags / opens a folder that isn't yet a
/// git repository. Offers to run `git init` on the folder and,
/// optionally, link it to a remote (`git remote add origin <url>`)
/// so a brand-new local repo can push to a hosted bare repo in one
/// step instead of dropping into the terminal.
struct InitRepositorySheet: View {
    @Bindable var appState: AppState
    let target: AppState.InitTarget

    @Environment(\.dismiss) private var dismiss

    @State private var remoteURL: String = ""
    @State private var isWorking: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.folder")
                    .foregroundStyle(.orange)
                Text("Initialize Git Repository")
                    .font(.title3.bold())
            }

            Text("The folder below isn't a git repository yet. Run `git init` to make it one — and optionally point its `origin` remote at a hosted URL so push/pull just work.")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Folder")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                Text(target.path)
                    .scaledFont(12, design: .monospaced)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.bgInput)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Remote URL")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                TextField(
                    "git@github.com:org/repo.git  —  leave blank to skip",
                    text: $remoteURL
                )
                .textFieldStyle(.roundedBorder)
                .scaledFont(12, design: .monospaced)
                .disableAutocorrection(true)
                Text("Sets `origin` to this URL after init. You can add or change remotes later from the repository menu.")
                    .scaledFont(10)
                    .foregroundStyle(Color.textDisabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button {
                    Task { await initialize() }
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Initialize")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }
        }
        .padding(18)
        .frame(width: 520)
        .background(Color.bgPanel)
    }

    private func initialize() async {
        isWorking = true
        defer { isWorking = false }
        await appState.initAndAddRepository(
            path: target.path,
            group: target.group,
            remoteURL: remoteURL
        )
        dismiss()
    }
}
