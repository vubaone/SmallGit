import SwiftUI

struct BranchesPanel: View {
    @Bindable var appState: AppState
    @Bindable var viewModel: BranchesViewModel

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Branches") {
                HStack(spacing: 8) {
                    if appState.canUseActiveRepo {
                        if viewModel.hiddenCount > 0 {
                            Text("\(viewModel.hiddenCount) hidden")
                                .scaledFont(10)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        } else {
                            Text("\(viewModel.localBranches.count)")
                                .scaledFont(10)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        TextField("Filter", text: $viewModel.filterText)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 80, idealWidth: 130, maxWidth: 180)
                            .scaledFont(11)
                    }
                }
            }

            if appState.activeRepo == nil {
                EmptyPanelState(
                    icon: "arrow.triangle.branch",
                    title: "No repository open",
                    message: "Pick a repository to list its branches and tags."
                )
            } else if let issue = appState.activeRepositoryIssue,
                      let repo = appState.activeRepo {
                EmptyPanelState(
                    icon: issue.emptyStateIcon,
                    title: issue.emptyStateTitle,
                    message: issue.emptyStateMessage(path: repo.path)
                )
            } else {
                branchesContent
            }
        }
        .background(Color.bgPanel)
    }

    /// The journal's ref selection, which the checkboxes edit.
    private var refSelection: JournalRefSelection { appState.journalVM.refSelection }

    @ViewBuilder
    private var branchesContent: some View {
        ScrollViewReader { proxy in
            List(selection: $viewModel.selection) {
                // HEAD's own history, which is the default graph and the
                // one entry that isn't a named ref: it follows the
                // checkout instead of pinning to a branch.
                HStack(spacing: 6) {
                    RefCheckbox(state: refSelection.head ? .on : .off) {
                        Task { await appState.setJournalHeadSelected(!refSelection.head) }
                    }
                    Text("HEAD")
                        .scaledFont(11, weight: .semibold)
                    if let current = viewModel.currentBranch {
                        Text("(\(current))")
                            .scaledFont(10)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help("Graph the checked-out branch's history")
                .tag(SidebarSelection.head)

                DisclosureGroup(isExpanded: $viewModel.localExpanded) {
                    branchRows(of: viewModel.localTree, currentBranch: viewModel.currentBranch)
                } label: {
                    sectionLabel(
                        "Local Branches",
                        count: viewModel.localBranches.count,
                        refs: viewModel.localBranches.map(\.name)
                    )
                }

                if !viewModel.remoteBranches.isEmpty {
                    DisclosureGroup(isExpanded: $viewModel.remoteExpanded) {
                        // No current branch to mark: HEAD is always local, so
                        // nothing in this tree can be the checked-out one.
                        branchRows(of: viewModel.remoteTree, currentBranch: nil)
                    } label: {
                        sectionLabel(
                            "Remote Branches",
                            count: viewModel.remoteBranches.count,
                            refs: viewModel.remoteBranches.map(\.name)
                        )
                    }
                }

                if !viewModel.tags.isEmpty {
                    DisclosureGroup(isExpanded: $viewModel.tagsExpanded) {
                        ForEach(viewModel.filteredTags, id: \.self) { tag in
                            HStack(spacing: 6) {
                                RefCheckbox(state: refSelection.contains(tag) ? .on : .off) {
                                    toggle([tag])
                                }
                                Label(tag, systemImage: "tag")
                                    .scaledFont(12)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .help(tag)
                                .toolTip(tag)
                                .tag(SidebarSelection.tag(tag))
                        }
                    } label: {
                        sectionLabel("Tags", count: viewModel.tags.count, refs: viewModel.tags)
                    }
                }

                // Hidden entirely when the repository has none, which is
                // nearly all of them — the same call Sourcetree and GitKraken
                // make. A permanently empty section is clutter in a panel that
                // already carries four.
                if !appState.submodules.isEmpty {
                    DisclosureGroup(isExpanded: $viewModel.submodulesExpanded) {
                        ForEach(appState.submodules) { submodule in
                            SubmoduleRow(submodule: submodule)
                                .tag(SidebarSelection.submodule(submodule.path))
                        }
                    } label: {
                        sectionLabel("Submodules", count: appState.submodules.count)
                    }
                }

                if !appState.stashList.isEmpty {
                    DisclosureGroup(isExpanded: $viewModel.stashesExpanded) {
                        ForEach(appState.stashList) { stash in
                            StashRow(stash: stash)
                                .tag(SidebarSelection.stash(stash.index))
                        }
                    } label: {
                        sectionLabel("Stashes", count: appState.stashList.count)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // One menu for the whole list rather than one per row, which is
            // what makes a batch action possible: SwiftUI hands this the rows
            // the click applies to — the selection when the click landed
            // inside it, that one row when it didn't, which is the rule
            // Finder and Mail follow.
            .contextMenu(forSelectionType: SidebarSelection.self) { items in
                menu(for: items)
            }
            // Double-click actions come from the table underneath rather than
            // from per-row tap recognisers.
            //
            // A SwiftUI double-tap on a row competes with the List's own
            // click handling for the mouse-down the table needs to select
            // with — even declared `simultaneousGesture`, which was the
            // previous attempt at this. The symptom is a single click that
            // sometimes does nothing at all, which is what a click that lost
            // the race looks like. `doubleAction` is fired by AppKit *after*
            // selection has happened, so it cannot interfere with it.
            .background(TableDoubleClickBridge { _ in openSelection() })
            // Switching repository is the one moment the list is guaranteed to
            // be showing the wrong part of itself: it opens at the top, and the
            // branch the user came here for is somewhere down a list of dozens.
            // Only that flow sets the target — a refresh, a fetch or a checkout
            // leaves the list where it was, since a panel that scrolls itself
            // while you are reading it is worse than one that never scrolls.
            .onChange(of: appState.branchRevealTarget) { _, target in
                guard let target else { return }
                // Cleared at once: it is a request to scroll, not a record of
                // where the list is.
                appState.branchRevealTarget = nil
                // The folders standing above the branch are already open: the
                // switch opened them before this render, so the row exists.
                let rowID = BranchTreeNode.rowID(for: target, root: BranchesViewModel.localRoot)
                // Next tick, so the rows for the new repository have had a
                // layout pass — `scrollTo` no-ops on a row not yet drawn.
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(rowID, anchor: .center)
                    }
                }
            }
        }
    }

    /// The rows of one tree, in the order they are drawn.
    ///
    /// Every row carries a tag, folders included: an untagged row is one
    /// `List` refuses to select, so clicking a folder used to leave the
    /// selection on whichever branch was clicked before it — and a
    /// double-click there would then check that branch out.
    @ViewBuilder
    private func branchRows(of tree: BranchTreeNode, currentBranch: String?) -> some View {
        ForEach(viewModel.rows(of: tree)) { row in
            BranchRow(
                row: row,
                isCurrent: row.node.branch?.name == currentBranch,
                isExpanded: viewModel.expandedFolders.contains(row.id),
                checkState: refSelection.state(of: row.node.refsUnder),
                onToggle: { toggle(row.node.refsUnder) },
                onToggleFolder: { viewModel.toggleFolder(row.id) }
            )
            .tag(row.node.branch.map { SidebarSelection.branch($0.name) }
                 ?? SidebarSelection.folder(row.id))
        }
    }

    /// Right-click menu for the rows the click applies to. One row gets the
    /// menu for its kind; a folder or a batch gets the actions that still
    /// read the same done many times over.
    @ViewBuilder
    private func menu(for items: Set<SidebarSelection>) -> some View {
        if items.count == 1, let item = items.first {
            switch item {
            case .head:
                Button(refSelection.head ? "Remove from Graph" : "Add to Graph") {
                    Task { await appState.setJournalHeadSelected(!refSelection.head) }
                }
            case .branch(let name):
                if let branch = viewModel.branch(named: name) {
                    BranchContextMenu(branch: branch, appState: appState)
                }
            case .tag(let tag):
                TagContextMenu(tag: tag, appState: appState)
            case .stash(let index):
                if let stash = appState.stashList.first(where: { $0.index == index }) {
                    StashContextMenu(stash: stash, appState: appState)
                }
            case .submodule(let path):
                if let submodule = appState.submodules.first(where: { $0.path == path }) {
                    SubmoduleContextMenu(submodule: submodule, appState: appState)
                }
            case .folder:
                SidebarSelectionContextMenu(items: items, appState: appState)
            }
        } else if !items.isEmpty {
            SidebarSelectionContextMenu(items: items, appState: appState)
        }
    }

    /// Double-click behaviour, resolved from the selection the table just
    /// made: check out a local branch, open or shut a folder, show a stash's
    /// diff, open a submodule as its own repository.
    ///
    /// Single rows only. A double-click collapses a multi-row selection to the
    /// row under the pointer anyway, so a set with several rows in it here
    /// means the click landed somewhere that doesn't select — and acting on
    /// the leftover selection would be acting on a row nobody pointed at.
    private func openSelection() {
        guard viewModel.selection.count == 1,
              let item = viewModel.selection.first else { return }
        switch item {
        case .branch(let name):
            // Local only. A remote branch has no single obvious meaning for
            // "open" — checking one out means creating a tracking branch,
            // which is a decision, not a shortcut.
            guard viewModel.localBranches.contains(where: { $0.name == name }) else { return }
            Task { await appState.checkout(branch: name, offerFastForward: true) }
        case .folder(let id):
            viewModel.toggleFolder(id)
        case .stash(let index):
            appState.showStashDiff(index: index)
        case .submodule(let path):
            guard let submodule = appState.submodules.first(where: { $0.path == path }) else { return }
            Task { await appState.openSubmoduleAsRepository(submodule) }
        case .head, .tag:
            break
        }
    }

    /// Section label used inside each DisclosureGroup. Mirrors the
    /// SmartGit look — bold-ish section name plus a small grey count
    /// of the unfiltered total — so the user knows how many entries
    /// are hiding inside a collapsed section.
    private func sectionLabel(_ title: String, count: Int, refs: [String] = []) -> some View {
        HStack(spacing: 6) {
            if !refs.isEmpty {
                RefCheckbox(state: refSelection.state(of: refs)) { toggle(refs) }
            }
            Text(title)
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(Color.textPrimary)
            Text("\(count)")
                .scaledFont(10)
                .foregroundStyle(Color.textSecondary)
        }
    }

    /// One click on a box: a group that isn't fully ticked fills in,
    /// a fully ticked one clears.
    private func toggle(_ refs: [String]) {
        guard !refs.isEmpty else { return }
        let checked = refSelection.state(of: refs).toggled
        Task { await appState.setJournalRefs(refs, checked: checked) }
    }
}

/// Tri-state checkbox in front of a ref. Ticking one adds its commits
/// to the journal's graph; a folder or section box covers everything
/// under it and shows `mixed` when only some of those are ticked.
///
/// A Button rather than a `Toggle`: SwiftUI's checkbox toggle has no
/// third state, and inside a `List` row its own hit area competes with
/// the row's selection.
private struct RefCheckbox: View {
    let state: JournalRefSelection.CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state.symbolName)
                .scaledFont(11)
                .foregroundStyle(state == .off ? Color.textDisabled : Color.accentColor)
                // A 11pt glyph is a small target; the padding is the
                // clickable area, not decoration.
                .padding(.vertical, 2)
                .padding(.trailing, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(state.isOn ? "Remove from the graph" : "Add to the graph")
    }
}

/// Row inside the Branches panel's Stashes section. Shows the short
/// message and a relative timestamp, matching SmartGit's compact style.
private struct StashRow: View {
    let stash: GitStash

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray")
                .scaledFont(10)
                .foregroundStyle(Color.textSecondary)
            Text(stash.message)
                .scaledFont(12)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                // Middle, not tail: stashes from one branch all begin
                // "On social/ZSOC-1256-…", so cutting the end removes the
                // only part that distinguishes them from each other.
                .truncationMode(.middle)
            if let date = stash.date {
                Text(DateFormatters.relative(from: date))
                    .scaledFont(10)
                    .foregroundStyle(Color.textDisabled)
            }
            Spacer(minLength: 0)
        }
        // The whole row is the target, not just the glyphs: a stash message is
        // truncated to the panel width, so most of the row is empty space that
        // was not clickable.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Stash messages are long — `On social/ZSOC-1256-revamp-ep-music…` —
        // and the panel is narrow, so the part that identifies one is exactly
        // the part that gets truncated. Hover gives it back.
        .help(helpText)
        .toolTip(helpText)
    }

    private var helpText: String {
        var lines = [stash.message]
        if let branch = stash.branch { lines.append("Branch: \(branch)") }
        if let date = stash.date {
            lines.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        return lines.joined(separator: "\n")
    }
}

/// Right-click actions for a stash row in the Branches panel. Mirrors
/// what the Browse Stashes sheet already offers but inline, so the user
/// doesn't need to open a separate window for the common operations.
private struct StashContextMenu: View {
    let stash: GitStash
    @Bindable var appState: AppState

    var body: some View {
        Button("Show Diff") {
            appState.showStashDiff(index: stash.index)
        }
        Divider()
        Button("Apply") {
            Task {
                await appState.stashApply(index: stash.index)
                await appState.refreshPanels()
            }
        }
        if stash.index == 0 {
            Button("Pop") {
                Task { await appState.stashPop() }
            }
        }
        Divider()
        Button("Rename…") {
            appState.stashPendingRename = stash
        }
        // Confirmed, as it is in Browse Stashes: nothing undoes a drop.
        Button("Drop…", role: .destructive) {
            appState.pendingStashDrop = [stash.index]
        }
        Divider()
        Button("Create Patch…") {
            appState.patchSource = .stash(index: stash.index, message: stash.message)
        }
        Button("Browse Stashes…") {
            appState.showStashesSheet = true
        }
    }
}

private struct BranchRow: View {
    let row: BranchTreeRow
    let isCurrent: Bool
    let isExpanded: Bool
    let checkState: JournalRefSelection.CheckState
    let onToggle: () -> Void
    let onToggleFolder: () -> Void

    private var node: BranchTreeNode { row.node }

    var body: some View {
        HStack(spacing: 6) {
            RefCheckbox(state: checkState, action: onToggle)
            // The chevron a `DisclosureGroup` used to draw. A branch gets the
            // same width as empty space so names line up down the column.
            if node.children.isEmpty {
                Color.clear.frame(width: 12, height: 12)
            } else {
                Button(action: onToggleFolder) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .scaledFont(9, weight: .semibold)
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let branch = node.branch {
                Image(systemName: isCurrent ? "circle.fill" : "circle")
                    .scaledFont(8)
                    .foregroundStyle(isCurrent ? .green : Color.textDisabled)
                Text(node.name)
                    .scaledFont(12, weight: isCurrent ? .semibold : .regular)
                if let remote = branch.upstreamRemote {
                    if branch.upstreamGone {
                        // Tracking branch deleted on the remote: flag it in red
                        // instead of pretending the upstream still exists.
                        Text("? \(remote)")
                            .scaledFont(10)
                            .foregroundStyle(.red)
                    } else {
                        // Short `= origin` marker rather than the full
                        // `origin/social/...` path, which is too long to read.
                        Text("= \(remote)")
                            .scaledFont(10)
                            .foregroundStyle(Color.textDisabled)
                    }
                }
                if branch.worktreePath != nil {
                    Image(systemName: "smallcircle.filled.circle")
                        .scaledFont(9)
                        .foregroundStyle(.green.opacity(0.7))
                        .help("Checked out in a worktree")
                }
            } else {
                Image(systemName: "folder")
                    .scaledFont(10)
                    .foregroundStyle(Color.textSecondary)
                Text(node.name)
                    .scaledFont(12, weight: .medium)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
        // One step in per level, which the flattened list has to draw itself
        // now that no disclosure group is nesting the rows.
        .padding(.leading, CGFloat(row.depth) * 13)
        // Same reasoning as the stash rows: the panel is narrow and a branch
        // like `social/ZSOC-1256-bug-1825927-missmp3button` is truncated to
        // exactly the part that distinguishes it, so hover restores the full
        // name — and the empty right-hand end of the row is a click target
        // rather than dead space.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(helpText)
        .toolTip(helpText)
    }

    private var helpText: String {
        guard let branch = node.branch else { return node.name }
        var lines = [branch.name]
        if let remote = branch.upstreamRemote {
            lines.append(branch.upstreamGone
                         ? "Upstream \(remote) no longer exists"
                         : "Tracks \(remote)")
        }
        if let worktree = branch.worktreePath {
            lines.append("Checked out in worktree: \(worktree)")
        }
        return lines.joined(separator: "\n")
    }
}
