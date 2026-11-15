import SwiftUI

/// Reflog browser. Surfaced from the Repository menu and the repo
/// right-click as "Browse Reflog…". Shows every move HEAD has made
/// (commits, checkouts, resets, rebases, merges, …) and lets the user
/// jump back to any of them via `git reset`. Recovery UX, basically.
struct ReflogBrowserView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    @State private var query: String = ""
    @State private var pendingReset: PendingReset?

    private struct PendingReset: Identifiable {
        let id = UUID()
        let selector: String
        let summary: String
        let mode: ResetMode
    }

    private var entries: [GitReflogEntry] { appState.reflogEntries }

    private var filteredEntries: [GitReflogEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.subject.localizedCaseInsensitiveContains(query)
                || $0.shortHash.localizedCaseInsensitiveContains(query)
                || $0.action.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedEntry: GitReflogEntry? {
        entries.first { $0.selector == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)

            if entries.isEmpty {
                emptyState
            } else {
                Table(of: GitReflogEntry.self, selection: $selection) {
                    TableColumn("@") { entry in
                        Text("@{\(entry.index)}")
                            .scaledFont(11, design: .monospaced)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .width(58)

                    TableColumn("Action") { entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.action.symbolName)
                                .scaledFont(11)
                                .foregroundStyle(Color.textSecondary)
                                .frame(width: 14)
                            Text(entry.action.displayName)
                                .scaledFont(11)
                        }
                    }
                    .width(110)

                    TableColumn("Message") { entry in
                        Text(entry.message)
                            .scaledFont(12)
                            .lineLimit(1)
                    }

                    TableColumn("Hash") { entry in
                        Text(entry.shortHash)
                            .scaledFont(11, design: .monospaced)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .width(80)

                    TableColumn("When") { entry in
                        Text(entry.date.map { DateFormatters.relative(from: $0) } ?? "—")
                            .scaledFont(10)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .width(110)
                } rows: {
                    ForEach(filteredEntries) { entry in
                        TableRow(entry)
                    }
                }
                .frame(minHeight: 280)
            }

            footer
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 440)
        .background(Color.bgPanel)
        .task { await appState.loadReflog() }
        .alert(item: $pendingReset) { reset in
            Alert(
                title: Text("\(reset.mode.displayLabel) reset to \(reset.selector)?"),
                message: Text(resetWarningMessage(for: reset)),
                primaryButton: .destructive(Text("Reset")) {
                    Task {
                        await appState.resetCurrent(to: reset.selector, mode: reset.mode)
                        dismiss()
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Reflog: HEAD").font(.title3.bold())
            Spacer()
            Text("\(entries.count) entr\(entries.count == 1 ? "y" : "ies")")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var footer: some View {
        HStack {
            Menu("Reset HEAD to Selected") {
                Button("Soft (keep working tree + index)") {
                    queueReset(mode: .soft)
                }
                Button("Mixed (keep working tree)") {
                    queueReset(mode: .mixed)
                }
                Button("Hard (discard everything)") {
                    queueReset(mode: .hard)
                }
            }
            .disabled(selectedEntry == nil)

            Button("Copy Hash") {
                if let entry = selectedEntry {
                    appState.copyToPasteboard(entry.hash)
                }
            }
            .disabled(selectedEntry == nil)

            Spacer()

            Button("Refresh") {
                Task { await appState.loadReflog() }
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .scaledFont(28, weight: .light)
                .foregroundStyle(Color.textDisabled)
            Text("Reflog is empty")
                .foregroundStyle(Color.textSecondary)
            Text("Once HEAD moves (commit, checkout, reset, …) entries will appear here.")
                .scaledFont(10)
                .foregroundStyle(Color.textDisabled)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func queueReset(mode: ResetMode) {
        guard let entry = selectedEntry else { return }
        pendingReset = PendingReset(
            selector: entry.selector,
            summary: entry.subject,
            mode: mode
        )
    }

    private func resetWarningMessage(for reset: PendingReset) -> String {
        let trailing: String
        switch reset.mode {
        case .soft:
            trailing = "Working tree and index are kept; only HEAD moves."
        case .mixed:
            trailing = "Index is reset to that point; working tree is kept."
        case .hard:
            trailing = "Working tree, index, and HEAD are all reset. Uncommitted work will be lost — but the reflog itself remains, so this is reversible from the previous reflog entry."
        case .keep, .merge:
            trailing = "Reset mode: \(reset.mode.rawValue)."
        }
        return "Target: \(reset.summary)\n\n\(trailing)"
    }
}

private extension ResetMode {
    var displayLabel: String {
        switch self {
        case .soft:  return "Soft"
        case .mixed: return "Mixed"
        case .hard:  return "Hard"
        case .keep:  return "Keep"
        case .merge: return "Merge"
        }
    }
}
