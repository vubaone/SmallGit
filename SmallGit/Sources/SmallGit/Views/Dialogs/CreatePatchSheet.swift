import SwiftUI
import AppKit

/// Two-field sheet for "Create Patch…" actions. Captures a filename
/// + destination directory; the actual `git diff` / `git format-patch`
/// run happens in `AppState.writePatch`. Source is determined by what
/// invoked the sheet (file selection, journal commit or stash).
struct CreatePatchSheet: View {
    @Bindable var appState: AppState
    let source: AppState.PatchSource

    @Environment(\.dismiss) private var dismiss

    @State private var fileName: String = ""
    @State private var directoryURL: URL?
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Patch")
                .font(.title3.bold())

            Text(summary)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("File name")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                TextField("name.patch", text: $fileName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Location")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                HStack(spacing: 8) {
                    Text(directoryURL?.path ?? "Choose a directory…")
                        .scaledFont(12, design: .monospaced)
                        .foregroundStyle(directoryURL == nil
                                         ? Color.textDisabled
                                         : Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Browse…") { browseForDirectory() }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .scaledFont(11)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(18)
        .frame(width: 480)
        .background(Color.bgPanel)
        .onAppear {
            fileName = source.suggestedFileName
            // Default the directory to the active repo's parent so the
            // user can drop the patch alongside the repo it came from
            // — most teams collect patches in a sibling folder.
            if let repo = appState.activeRepo {
                directoryURL = URL(fileURLWithPath: repo.path).deletingLastPathComponent()
            }
        }
    }

    private var summary: String {
        switch source {
        case .files(let paths, _):
            let n = paths.count
            return "Captures working-tree changes for \(n) file\(n == 1 ? "" : "s") vs. HEAD."
        case .commit(let hash, let subject):
            return "Captures commit \(hash.prefix(7)) — \(subject)"
        case .stash(let index, let message):
            return "Captures stash@{\(index)} — \(message)"
        }
    }

    private var canCreate: Bool {
        !fileName.trimmingCharacters(in: .whitespaces).isEmpty
        && directoryURL != nil
        && !isCreating
    }

    private func browseForDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = directoryURL
        if panel.runModal() == .OK, let url = panel.url {
            directoryURL = url
        }
    }

    private func create() async {
        guard let dir = directoryURL else { return }
        var name = fileName.trimmingCharacters(in: .whitespaces)
        if !name.lowercased().hasSuffix(".patch") && !name.lowercased().hasSuffix(".diff") {
            name += ".patch"
        }
        let destination = dir.appendingPathComponent(name)

        if FileManager.default.fileExists(atPath: destination.path) {
            let alert = NSAlert()
            alert.messageText = "Overwrite \(name)?"
            alert.informativeText = "A file with this name already exists in \(dir.path)."
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        isCreating = true
        defer { isCreating = false }
        await appState.writePatch(source: source, to: destination)
        dismiss()
    }
}
