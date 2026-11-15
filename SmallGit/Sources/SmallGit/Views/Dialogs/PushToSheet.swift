import SwiftUI

/// "Push To…" sheet — pick a remote and (optionally) a different remote
/// branch name, with toggles for `--force-with-lease` and `--set-upstream`.
/// Used by the branch context menu, independent of the configured upstream.
struct PushToSheet: View {
    let branch: GitBranch
    @Bindable var appState: AppState

    @State private var remotes: [String] = []
    @State private var remote: String = ""
    @State private var remoteBranchName: String = ""
    @State private var force: Bool = false
    @State private var setUpstream: Bool = false
    @State private var loading: Bool = true
    @Environment(\.dismiss) private var dismiss

    private var canPush: Bool {
        !remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Push To").font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Local branch")
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
                Text("Remote")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                if loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading remotes…")
                            .scaledFont(11)
                            .foregroundStyle(Color.textSecondary)
                    }
                } else if remotes.isEmpty {
                    Text("No remotes configured")
                        .scaledFont(11)
                        .foregroundStyle(Color.textDisabled)
                } else {
                    Picker("", selection: $remote) {
                        ForEach(remotes, id: \.self) { r in
                            Text(r).tag(r)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Remote branch")
                        .scaledFont(11)
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    Text("(blank = same name)")
                        .scaledFont(10)
                        .foregroundStyle(Color.textDisabled)
                }
                TextField(branch.name, text: $remoteBranchName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Force push (with lease)", isOn: $force)
                    .toggleStyle(.checkbox)
                    .scaledFont(11)
                Toggle("Set as upstream after push", isOn: $setUpstream)
                    .toggleStyle(.checkbox)
                    .scaledFont(11)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Push") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPush)
            }
        }
        .padding(18)
        .frame(minWidth: 460)
        .background(Color.bgPanel)
        .task {
            await loadRemotes()
        }
    }

    private func loadRemotes() async {
        guard let repo = appState.activeRepo?.path else { loading = false; return }
        let list = (try? await appState.git.remotes(repoPath: repo)) ?? []
        remotes = list
        // Preselect the upstream's remote when available, otherwise origin,
        // otherwise the first configured remote.
        if let upstream = branch.upstream,
           let firstSlash = upstream.firstIndex(of: "/"),
           list.contains(String(upstream[..<firstSlash])) {
            remote = String(upstream[..<firstSlash])
        } else if list.contains("origin") {
            remote = "origin"
        } else {
            remote = list.first ?? ""
        }
        loading = false
    }

    private func commit() {
        let trimmedRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRemoteBranch = remoteBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await appState.pushTo(
                localBranch: branch.name,
                remote: trimmedRemote,
                remoteBranch: trimmedRemoteBranch.isEmpty ? nil : trimmedRemoteBranch,
                force: force,
                setUpstream: setUpstream
            )
            dismiss()
        }
    }
}
