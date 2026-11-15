import SwiftUI

/// "Set Tracked Branch…" sheet — picks one of the known remote-tracking
/// refs and points the local branch's upstream at it.
/// Equivalent to `git branch --set-upstream-to=<upstream> <branch>`.
struct SetTrackedBranchSheet: View {
    let branch: GitBranch
    @Bindable var appState: AppState

    @State private var selected: String?
    @State private var query: String = ""
    @Environment(\.dismiss) private var dismiss

    private var remoteBranches: [GitBranch] {
        appState.branchesVM.remoteBranches
    }

    private var filtered: [GitBranch] {
        guard !query.isEmpty else { return remoteBranches }
        return remoteBranches.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Tracked Branch").font(.title3.bold())

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

            if let upstream = branch.upstream {
                Text("Currently tracking \(upstream)")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            } else {
                Text("No upstream configured")
                    .scaledFont(11)
                    .foregroundStyle(Color.textDisabled)
            }

            TextField("Filter remote branches", text: $query)
                .textFieldStyle(.roundedBorder)

            List(selection: $selected) {
                if filtered.isEmpty {
                    Text("No remote branches.")
                        .scaledFont(11)
                        .foregroundStyle(Color.textDisabled)
                } else {
                    ForEach(filtered) { remote in
                        HStack(spacing: 6) {
                            Image(systemName: "cloud")
                                .scaledFont(11)
                                .foregroundStyle(Color.textSecondary)
                            Text(remote.name).scaledFont(12)
                            Spacer()
                        }
                        .tag(remote.name as String?)
                    }
                }
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set Upstream") {
                    if let upstream = selected {
                        Task {
                            await appState.setUpstream(branch: branch.name, upstream: upstream)
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(18)
        .frame(minWidth: 460, minHeight: 360)
        .background(Color.bgPanel)
        .onAppear {
            selected = branch.upstream
        }
    }
}
