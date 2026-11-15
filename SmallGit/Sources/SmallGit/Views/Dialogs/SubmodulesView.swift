import SwiftUI

/// Repository ▸ Submodules… — the full list, with the operations that need
/// more than a context menu.
///
/// The sidebar section is where submodules are *read*; this is where they are
/// managed. Add in particular needs two fields, which a sidebar row has no
/// room for. Modelled on the Worktrees sheet, which solves the same shape of
/// problem: a set of related checkouts with add and remove.
struct SubmodulesView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    @State private var isAdding = false
    @State private var newURL = ""
    @State private var newPath = ""
    @State private var isBusy = false

    private var selected: GitSubmodule? {
        appState.submodules.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if appState.submodules.isEmpty && !isAdding {
                emptyState
            } else {
                table
            }

            if isAdding { addForm }

            footer
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 420)
        .task { await appState.refreshSubmodules() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Submodules").font(.title3.bold())
                Text("Repositories this one pins to a specific commit")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            if !appState.submodules.isEmpty {
                Text("\(appState.submodules.count)")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "shippingbox")
                .scaledFont(26, weight: .light)
                .foregroundStyle(Color.textDisabled)
            Text("No submodules")
                .scaledFont(12, weight: .semibold)
            Text("A submodule pins another repository at a specific commit inside this one. Add one below to get started.")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        Table(of: GitSubmodule.self, selection: $selection) {
            TableColumn("Name") { module in
                Text(module.name).scaledFont(12).lineLimit(1)
            }
            TableColumn("Path") { module in
                Text(module.path)
                    .scaledFont(11, design: .monospaced)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TableColumn("Commit") { module in
                Text(module.describe ?? module.shortSHA)
                    .scaledFont(11, design: .monospaced)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            .width(150)
            TableColumn("State") { module in
                Text(module.state.label)
                    .scaledFont(11)
                    .foregroundStyle(module.state == .current ? Color.textSecondary : .orange)
            }
            .width(110)
        } rows: {
            ForEach(appState.submodules) { module in
                TableRow(module)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let module = appState.submodules.first(where: { ids.contains($0.id) }) {
                SubmoduleContextMenu(submodule: module, appState: appState)
            }
        } primaryAction: { ids in
            guard let module = appState.submodules.first(where: { ids.contains($0.id) }) else { return }
            Task { await appState.openSubmoduleAsRepository(module) }
        }
        .frame(minHeight: 180)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Add Submodule").scaledFont(12, weight: .semibold)
            TextField("Repository URL", text: $newURL)
                .textFieldStyle(.roundedBorder)
            TextField("Path inside this repository (e.g. vendor/lib)", text: $newPath)
                .textFieldStyle(.roundedBorder)
            Text("The path must not already exist. git clones the repository there and records the commit it lands on.")
                .scaledFont(10)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isAdding {
                Button("Cancel") {
                    isAdding = false
                    newURL = ""
                    newPath = ""
                }
                Button("Add Submodule") {
                    Task {
                        isBusy = true
                        await appState.addSubmodule(url: newURL, path: newPath)
                        isBusy = false
                        isAdding = false
                        newURL = ""
                        newPath = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy
                          || newURL.trimmingCharacters(in: .whitespaces).isEmpty
                          || newPath.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button("Add…") { isAdding = true }

                Button("Update All") {
                    Task {
                        isBusy = true
                        await appState.updateSubmodules()
                        isBusy = false
                    }
                }
                .disabled(isBusy || appState.submodules.isEmpty)
                .help("git submodule update --init --recursive")

                Button("Sync URLs") {
                    Task {
                        isBusy = true
                        await appState.syncSubmodules()
                        isBusy = false
                    }
                }
                .disabled(isBusy || appState.submodules.isEmpty)
            }

            if isBusy { ProgressView().controlSize(.small) }

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
