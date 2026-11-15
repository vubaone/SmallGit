import SwiftUI

/// Presented when the dragged-in folder lives *inside* an existing
/// git repository. `git rev-parse --is-inside-work-tree` happily
/// resolves to the enclosing repo, so adding the folder silently
/// would register the parent — almost never what the user meant.
///
/// Three escapes: open the parent repo (the path git already
/// resolved), make a brand-new repo at the dropped path (delegates
/// to the same Init flow), or cancel.
struct AmbiguousFolderSheet: View {
    @Bindable var appState: AppState
    let target: AppState.AmbiguousTarget

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.folder.fill")
                    .foregroundStyle(.orange)
                Text("Folder is inside another repository")
                    .font(.title3.bold())
            }

            Text("The folder you added isn't a git repo on its own — it's a subdirectory of one. Choose what to add:")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            pathRow(label: "You added",      path: target.droppedPath)
            pathRow(label: "Enclosing repo", path: target.parentRootPath)

            Divider().padding(.vertical, 2)

            HStack {
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)

                Spacer()

                Button {
                    Task { await initHere() }
                } label: {
                    Label("Init New Repo Here", systemImage: "plus.circle")
                }
                .disabled(isWorking)
                .help("Run `git init` inside the dropped folder and register it as a new, separate repository.")

                Button {
                    Task { await openParent() }
                } label: {
                    Label("Open Parent Repo", systemImage: "arrow.up.left.circle")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
                .help("Add the enclosing repository — the one git already resolved.")
            }
        }
        .padding(18)
        .frame(width: 560)
        .background(Color.bgPanel)
    }

    private func pathRow(label: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .scaledFont(10, weight: .semibold)
                .foregroundStyle(Color.textDisabled)
            Text(path)
                .scaledFont(12, design: .monospaced)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Color.bgInput)
                )
        }
    }

    private func openParent() async {
        isWorking = true
        defer { isWorking = false }
        // Re-enter `addRepository` with the parent root — its
        // first guard now passes cleanly and the `register` branch
        // adds it without re-triggering this sheet (root == path
        // for the parent).
        await appState.addRepository(at: target.parentRootPath, group: target.group)
        dismiss()
    }

    private func initHere() async {
        // Hand off to the Init sheet so the user gets the optional
        // remote-URL field too. Dismiss this first so the sheet
        // chain doesn't try to present two sheets at once.
        let path = target.droppedPath
        let group = target.group
        dismiss()
        appState.pendingInitTarget = AppState.InitTarget(path: path, group: group)
    }
}
