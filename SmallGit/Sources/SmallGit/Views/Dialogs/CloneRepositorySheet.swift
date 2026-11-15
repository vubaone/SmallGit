import SwiftUI
import AppKit

struct CloneRepositorySheet: View {
    @Bindable var appState: AppState

    @State private var remoteURL: String = ""
    @State private var destinationParent: String = ""
    @State private var folderName: String = ""
    @State private var groupSelection: String = ""
    @Environment(\.dismiss) private var dismiss

    private static let ungroupedTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone Repository").font(.title3.bold())

            VStack(alignment: .leading, spacing: 4) {
                Text("Remote URL").scaledFont(11, weight: .medium)
                TextField("https://github.com/owner/repo.git", text: $remoteURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: remoteURL) { _, new in
                        let suggested = Self.suggestedFolderName(from: new)
                        if !suggested.isEmpty { folderName = suggested }
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Clone Into").scaledFont(11, weight: .medium)
                HStack(spacing: 6) {
                    TextField("Parent folder", text: $destinationParent)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") { pickParentFolder() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Folder Name").scaledFont(11, weight: .medium)
                TextField("repo", text: $folderName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Add to Group").scaledFont(11, weight: .medium)
                Picker("", selection: $groupSelection) {
                    Text("Other (ungrouped)").tag(Self.ungroupedTag)
                    ForEach(appState.repositoriesConfig.groups, id: \.name) { group in
                        Text(group.name).tag(group.name)
                    }
                }
                .labelsHidden()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clone") {
                    let urlValue = remoteURL
                    let parentValue = destinationParent
                    let folderValue = folderName
                    let group = groupSelection.isEmpty ? nil : groupSelection
                    Task {
                        await appState.cloneRepository(
                            remoteURL: urlValue,
                            destinationParent: parentValue,
                            folderName: folderValue,
                            groupName: group
                        )
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(18)
        .frame(minWidth: 520)
        .background(Color.bgPanel)
        .onAppear {
            if let preselected = appState.pendingCloneGroup {
                groupSelection = preselected
            }
        }
        .onDisappear {
            appState.pendingCloneGroup = nil
        }
    }

    private var canSubmit: Bool {
        !remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !destinationParent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    /// Derives a sensible default folder name from a git URL.
    /// `https://github.com/foo/bar.git` → `bar`.
    /// `git@github.com:foo/bar` → `bar`.
    static func suggestedFolderName(from url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lastSegment = trimmed
            .split(whereSeparator: { $0 == "/" || $0 == ":" })
            .last
            .map(String.init) ?? ""
        if lastSegment.hasSuffix(".git") {
            return String(lastSegment.dropLast(4))
        }
        return lastSegment
    }
}
