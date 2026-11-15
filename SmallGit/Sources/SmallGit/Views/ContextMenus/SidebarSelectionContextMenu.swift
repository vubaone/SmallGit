import SwiftUI

/// Right-click menu for a batch of Branches-panel rows: several selected
/// rows, or one folder standing for everything under it.
///
/// Only the actions that still mean something done many times over. Most of
/// the single-row menu is "…onto the current branch" — merging five branches
/// is five decisions, not one — so what is left is the graph checkboxes, the
/// delete, and the names.
///
/// Stashes get their own drop: a selection of nothing but stashes shows only
/// that, since none of the ref actions apply to one.
struct SidebarSelectionContextMenu: View {
    let items: Set<SidebarSelection>
    @Bindable var appState: AppState

    private var viewModel: BranchesViewModel { appState.branchesVM }

    /// Branches the selection covers, with folders expanded to their contents.
    private var branches: [GitBranch] { viewModel.branches(in: items) }

    private var tags: [String] {
        items.sortedForMenu.compactMap {
            if case .tag(let name) = $0 { name } else { nil }
        }
    }

    /// Refs the graph can be given. HEAD is held apart: it isn't a name
    /// `git log` takes from a list of refs.
    private var refs: [String] { branches.map(\.name) + tags }

    private var includesHead: Bool { items.contains(.head) }

    /// What `git branch -d` can be pointed at — local branches other than the
    /// one checked out.
    private var deletable: [GitBranch] {
        branches.filter { !$0.isRemote && $0.name != viewModel.currentBranch }
    }

    private var copyList: [String] { branches.map(\.name) + tags }

    private var stashIndices: [Int] {
        items.compactMap {
            if case .stash(let index) = $0 { index } else { nil }
        }.sorted()
    }

    private var onlyStashes: Bool { stashIndices.count == items.count }

    var body: some View {
        if onlyStashes {
            Section(selectionLabel) {
                dropStashesButton
            }
        } else {
            refActions
        }
    }

    private var dropStashesButton: some View {
        Button(StashDropConfirmation.buttonLabel(stashIndices) + "…", role: .destructive) {
            appState.pendingStashDrop = stashIndices
        }
    }

    private var refActions: some View {
        Group {
            Section(selectionLabel) {
                Button("Add to Graph") { setGraph(true) }
                Button("Remove from Graph") { setGraph(false) }
            }
            .disabled(refs.isEmpty && !includesHead)

            Divider()

            Button(deleteLabel, role: .destructive) {
                Task { await appState.requestBranchDeletion(deletable) }
            }
            .disabled(deletable.isEmpty)

            if !stashIndices.isEmpty {
                dropStashesButton
            }

            Divider()

            Button("Copy Names") {
                appState.copyToPasteboard(copyList.joined(separator: "\n"))
            }
            .disabled(copyList.isEmpty)
        }
    }

    /// Menu title, so a batch action says what it is about to act on — a
    /// folder's row count and its branch count are rarely the same number.
    private var selectionLabel: String {
        var parts: [String] = []
        if !branches.isEmpty { parts.append(plural(branches.count, "branch", "branches")) }
        if !tags.isEmpty { parts.append(plural(tags.count, "tag", "tags")) }
        if !stashIndices.isEmpty { parts.append(plural(stashIndices.count, "stash", "stashes")) }
        guard !parts.isEmpty else { return "\(plural(items.count, "row", "rows")) selected" }
        return "\(parts.joined(separator: ", ")) selected"
    }

    private var deleteLabel: String {
        switch deletable.count {
        case 0:  "Delete Branches…"
        case 1:  "Delete Branch…"
        default: "Delete \(deletable.count) Branches…"
        }
    }

    private func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    private func setGraph(_ on: Bool) {
        Task {
            if !refs.isEmpty { await appState.setJournalRefs(refs, checked: on) }
            if includesHead { await appState.setJournalHeadSelected(on) }
        }
    }
}
