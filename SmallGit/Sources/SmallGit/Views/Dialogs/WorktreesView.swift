import SwiftUI
import AppKit

/// Browse and manage linked working trees. Surfaced from the Repository
/// menu ("Worktrees…", ⌘⇧T) and the repository context menu. Lists every
/// worktree with its branch and HEAD, and offers add / remove / prune,
/// plus "Open as Repository" — registering the worktree in the sidebar,
/// which is how you switch SmallGit to work inside it.
struct WorktreesView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    @State private var pendingRemovePath: String?
    @State private var showAddForm: Bool = false

    // Add-form state
    @State private var destinationParent: String = ""
    @State private var folderName: String = ""
    @State private var branchMode: BranchMode = .newBranch
    @State private var newBranchName: String = ""
    @State private var startPoint: String = ""
    @State private var existingBranch: String = ""

    enum BranchMode: String, CaseIterable {
        case newBranch = "New branch"
        case existing  = "Existing branch"
    }

    private var worktrees: [GitWorktree] { appState.worktreeList }
    private var selected: GitWorktree? {
        worktrees.first { $0.path == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Worktrees").font(.title3.bold())
                Spacer()
                Text("\(worktrees.count) total")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }

            worktreeTable

            if showAddForm {
                addForm
            }

            HStack {
                Button(showAddForm ? "Hide Add Form" : "Add Worktree…") {
                    if !showAddForm { prefillAddForm() }
                    showAddForm.toggle()
                }

                Button("Remove") {
                    pendingRemovePath = selection
                }
                .disabled(selected == nil || selected?.isMain == true)
                .help("Removes the worktree folder and git's bookkeeping. The main worktree cannot be removed.")

                Button("Prune") {
                    Task { await appState.pruneWorktrees() }
                }
                .disabled(!worktrees.contains(where: \.isPrunable))
                .help("Drop bookkeeping for worktrees whose folders were deleted manually.")

                Spacer()

                Button("Reveal in Finder") {
                    if let wt = selected { appState.revealInFinder(path: wt.path) }
                }
                .disabled(selected == nil)

                Button("Open as Repository") {
                    if let wt = selected {
                        Task {
                            await appState.openWorktreeAsRepository(wt)
                            dismiss()
                        }
                    }
                }
                .disabled(selected == nil || selected?.isMain == true)
                .help("Add this worktree to the repository list and switch to it.")

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 340)
        .background(Color.bgPanel)
        .task { await appState.loadWorktrees() }
        .alert(
            "Remove worktree?",
            isPresented: Binding(
                get: { pendingRemovePath != nil },
                set: { if !$0 { pendingRemovePath = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingRemovePath = nil }
            Button("Remove", role: .destructive) {
                if let path = pendingRemovePath {
                    pendingRemovePath = nil
                    selection = nil
                    Task { await appState.removeWorktree(path: path) }
                }
            }
        } message: {
            Text("This deletes the worktree's folder. Git refuses if the worktree has uncommitted changes (nothing is lost — check the Output panel and commit or stash first). Its branch is kept.")
        }
    }

    // MARK: - Table

    @ViewBuilder
    private var worktreeTable: some View {
        if worktrees.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .scaledFont(28, weight: .light)
                    .foregroundStyle(Color.textDisabled)
                Text("No worktrees listed")
                    .foregroundStyle(Color.textSecondary)
                Text("Add a worktree to work on two branches side by side without stashing.")
                    .scaledFont(10)
                    .foregroundStyle(Color.textDisabled)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            Table(of: GitWorktree.self, selection: $selection) {
                TableColumn("Folder") { wt in
                    HStack(spacing: 6) {
                        Text(wt.name)
                            .scaledFont(12)
                            .lineLimit(1)
                        if wt.isMain {
                            WorktreeBadge(text: "main", color: .accentColor)
                        }
                        if wt.isLocked {
                            WorktreeBadge(text: "locked", color: .orange)
                                .help(wt.lockReason ?? "Locked")
                        }
                        if wt.isPrunable {
                            WorktreeBadge(text: "prunable", color: .red)
                        }
                    }
                    .help(wt.path)
                }

                TableColumn("Branch") { wt in
                    Text(wt.branch ?? (wt.isBare ? "(bare)" : "(detached)"))
                        .scaledFont(11)
                        .foregroundStyle(wt.branch == nil ? Color.textSecondary : Color.textPrimary)
                        .lineLimit(1)
                }
                .width(160)

                TableColumn("HEAD") { wt in
                    Text(wt.shortSHA)
                        .scaledFont(11, design: .monospaced)
                        .foregroundStyle(Color.textSecondary)
                }
                .width(80)

                TableColumn("Path") { wt in
                    Text(wt.path)
                        .scaledFont(10)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } rows: {
                ForEach(worktrees) { wt in
                    TableRow(wt)
                }
            }
            .frame(minHeight: 160)
        }
    }

    // MARK: - Add form

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Parent folder", text: $destinationParent)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { pickParentFolder() }
                TextField("Folder name", text: $folderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }

            HStack(spacing: 6) {
                Picker("", selection: $branchMode) {
                    ForEach(BranchMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                switch branchMode {
                case .newBranch:
                    TextField("New branch name", text: $newBranchName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Start point (default: HEAD)", text: $startPoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                case .existing:
                    // Only branches not already checked out in another
                    // worktree are eligible — git enforces it; we filter
                    // upfront so the picker doesn't offer guaranteed
                    // failures.
                    Picker("", selection: $existingBranch) {
                        Text("Choose branch…").tag("")
                        ForEach(eligibleBranches, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                }

                Spacer()

                Button("Create") { submitAdd() }
                    .disabled(!canSubmitAdd)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.06)))
    }

    private var eligibleBranches: [String] {
        let checkedOut = Set(worktrees.compactMap(\.branch))
        return appState.branchesVM.localBranches
            .map(\.name)
            .filter { !checkedOut.contains($0) }
    }

    private var canSubmitAdd: Bool {
        let hasDestination =
            !destinationParent.trimmingCharacters(in: .whitespaces).isEmpty &&
            !folderName.trimmingCharacters(in: .whitespaces).isEmpty
        switch branchMode {
        case .newBranch:
            return hasDestination &&
                !newBranchName.trimmingCharacters(in: .whitespaces).isEmpty
        case .existing:
            return hasDestination && !existingBranch.isEmpty
        }
    }

    private func submitAdd() {
        let path = (destinationParent as NSString)
            .appendingPathComponent(folderName.trimmingCharacters(in: .whitespaces))
        let mode = branchMode
        let newName = newBranchName.trimmingCharacters(in: .whitespaces)
        let start = startPoint.trimmingCharacters(in: .whitespaces)
        let existing = existingBranch
        showAddForm = false
        Task {
            switch mode {
            case .newBranch:
                await appState.addWorktree(
                    path: path,
                    newBranch: newName,
                    startPoint: start.isEmpty ? nil : start
                )
            case .existing:
                await appState.addWorktree(path: path, checkoutBranch: existing)
            }
        }
    }

    /// Suggest `<repo-parent>` + `<repo>-<something>` — the common
    /// sibling-folder convention (`myrepo` → `myrepo-fix`).
    private func prefillAddForm() {
        guard let repo = appState.activeRepo else { return }
        let repoURL = URL(fileURLWithPath: repo.path)
        destinationParent = repoURL.deletingLastPathComponent().path
        if folderName.isEmpty {
            folderName = repoURL.lastPathComponent + "-wt"
        }
    }

    private func pickParentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            destinationParent = url.path
        }
    }
}

/// Tiny capsule badge used in the worktree table (main / locked / prunable).
private struct WorktreeBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .scaledFont(9, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}
