import SwiftUI

/// Generic branch picker used by Merge and Rebase. The title and confirm
/// label adapt to the operation; the underlying selection is just a branch
/// name handed to the supplied `onSelect` closure.
struct BranchPickerSheet: View {
    let title: String
    let confirmLabel: String
    @Bindable var appState: AppState
    let onSelect: (String) -> Void

    @State private var selectedBranch: String?
    @State private var query: String = ""
    @Environment(\.dismiss) private var dismiss

    private var localBranches: [GitBranch] {
        appState.branchesVM.localBranches.filter { branch in
            branch.name != appState.branchesVM.currentBranch
        }
    }

    private var remoteBranches: [GitBranch] {
        appState.branchesVM.remoteBranches
    }

    private var filteredLocal: [GitBranch] {
        guard !query.isEmpty else { return localBranches }
        return localBranches.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var filteredRemote: [GitBranch] {
        guard !query.isEmpty else { return remoteBranches }
        return remoteBranches.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())

            if let current = appState.branchesVM.currentBranch {
                Text("Currently on \(current)")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }

            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)

            List(selection: $selectedBranch) {
                if !filteredLocal.isEmpty {
                    Section("Local") {
                        ForEach(filteredLocal) { branch in
                            BranchPickerRow(branch: branch)
                                .tag(branch.name as String?)
                        }
                    }
                }
                if !filteredRemote.isEmpty {
                    Section("Remote") {
                        ForEach(filteredRemote) { branch in
                            BranchPickerRow(branch: branch)
                                .tag(branch.name as String?)
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) {
                    if let selected = selectedBranch {
                        onSelect(selected)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedBranch == nil)
            }
        }
        .padding(18)
        .frame(minWidth: 460, minHeight: 360)
        .background(Color.bgPanel)
    }
}

private struct BranchPickerRow: View {
    let branch: GitBranch
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: branch.isRemote ? "cloud" : "arrow.triangle.branch")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
            Text(branch.name).scaledFont(12)
            if let upstream = branch.upstream {
                Text("→ \(upstream)")
                    .scaledFont(10)
                    .foregroundStyle(Color.textDisabled)
            }
            Spacer()
        }
    }
}
