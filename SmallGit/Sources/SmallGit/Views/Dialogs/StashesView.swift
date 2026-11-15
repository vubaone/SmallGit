import SwiftUI

/// Browse, apply, pop, and drop stash entries. Surfaced from the toolbar
/// (Apply Stash menu → "Browse Stashes…") and the Repository menu so
/// users can see what's there before applying anything.
struct StashesView: View {
    @Bindable var appState: AppState
    /// Supplied by the window hosting this view. A window-modal sheet has no
    /// title bar to close from, so the button below is the only visible way
    /// out besides Escape.
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var selection = Set<Int>()
    /// Indices awaiting confirmation. Empty means no drop is pending.
    @State private var pendingDrop: [Int] = []

    private var stashes: [GitStash] { appState.stashList }

    /// The one selected stash, when exactly one is selected. Everything but
    /// Drop needs a single subject: applying two stashes at once is two
    /// different operations with two different outcomes, and showing the diff
    /// of two of them at once means nothing.
    private var singleSelection: Int? {
        selection.count == 1 ? selection.first : nil
    }

    private var selectedStashes: [GitStash] {
        stashes.filter { selection.contains($0.index) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Stashes").font(.title3.bold())
                Spacer()
                Text("\(stashes.count) total")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(11, weight: .semibold)
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .accessibilityLabel("Close")
            }

            if stashes.isEmpty {
                emptyState
            } else {
                Table(of: GitStash.self, selection: $selection) {
                    TableColumn("Index") { stash in
                        Text("@{\(stash.index)}")
                            .scaledFont(12, design: .monospaced)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .width(60)

                    TableColumn("Message") { stash in
                        Text(stash.message)
                            .scaledFont(12)
                            .lineLimit(1)
                    }

                    TableColumn("Branch") { stash in
                        Text(stash.branch ?? "—")
                            .scaledFont(11)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .width(140)

                    TableColumn("Date") { stash in
                        Text(stash.date.map { DateFormatters.relative(from: $0) } ?? "—")
                            .scaledFont(10)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .width(110)
                } rows: {
                    ForEach(stashes) { stash in
                        TableRow(stash)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Button("Show Diff") {
                    if let idx = singleSelection {
                        // Closed first: the stash window opens over the main
                        // window, and leaving this one up in front of it would
                        // hide what the click just asked for.
                        close()
                        appState.showStashDiff(index: idx)
                    }
                }
                .disabled(singleSelection == nil)

                Button("Apply") {
                    if let idx = singleSelection {
                        Task {
                            await appState.stashApply(index: idx)
                            await appState.refreshPanels()
                        }
                    }
                }
                .disabled(singleSelection == nil)

                Button("Pop") {
                    Task { await appState.stashPop() }
                }
                .disabled(stashes.isEmpty || (!selection.isEmpty && selection != [0]))
                .help("Pop applies the top stash and removes it. Only available for stash@{0}.")

                Button("Drop") {
                    pendingDrop = selection.sorted()
                }
                .disabled(selection.isEmpty)
                .help(dropHelp)

                Spacer()

                Button("Refresh") {
                    Task { await appState.refreshPanels() }
                }

                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.bgPanel)
        .alert(
            dropTitle,
            isPresented: Binding(
                get: { !pendingDrop.isEmpty },
                set: { if !$0 { pendingDrop = [] } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingDrop = [] }
            Button(StashDropConfirmation.buttonLabel(pendingDrop), role: .destructive) {
                let indices = pendingDrop
                pendingDrop = []
                selection = []
                Task { await appState.stashDrop(indices: indices) }
            }
        } message: {
            Text(dropWarning)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .scaledFont(28, weight: .light)
                .foregroundStyle(Color.textDisabled)
            Text("No stashes")
                .foregroundStyle(Color.textSecondary)
            Text("Use Save Stash from the toolbar to put aside in-progress work.")
                .scaledFont(10)
                .foregroundStyle(Color.textDisabled)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drop confirmation

    private var dropHelp: String {
        selection.count > 1
            ? "Drop the \(selection.count) selected stashes."
            : "Drop the selected stash. Applying and popping work on one stash at a time."
    }

    private var dropTitle: String { StashDropConfirmation.title(pendingDrop) }

    private var dropWarning: String {
        StashDropConfirmation.message(pendingDrop, stashes: stashes)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

/// Wording of the drop confirmation, shared by the Browse Stashes sheet and
/// the Branches panel so both ask the same question.
enum StashDropConfirmation {
    static func title(_ indices: [Int]) -> String {
        if indices.count == 1 {
            return "Drop stash @{\(indices[0])}?"
        }
        return "Drop \(indices.count) stashes?"
    }

    static func buttonLabel(_ indices: [Int]) -> String {
        indices.count > 1 ? "Drop \(indices.count) Stashes" : "Drop"
    }

    /// Lists the stashes by index and message. "Drop 4 stashes?" on its own
    /// asks the user to trust a selection they made by shift-clicking, and
    /// this is the one action here that nothing undoes.
    static func message(_ indices: [Int], stashes: [GitStash]) -> String {
        let listed = 8
        let entries = indices.sorted().compactMap { index in
            stashes.first { $0.index == index }
        }
        let lines = entries.prefix(listed).map { stash in
            "@{\(stash.index)}  \(stash.message)"
        }
        let remainder = entries.count - lines.count
        let list = lines.joined(separator: "\n")
            + (remainder > 0 ? "\n… and \(remainder) more" : "")

        let permanence = entries.count > 1
            ? "This permanently removes these stash entries — it cannot be undone."
            : "This permanently removes the stash entry — it cannot be undone."
        return list.isEmpty ? permanence : "\(list)\n\n\(permanence)"
    }
}
