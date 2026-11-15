import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

/// Payload dragged inside the Repositories panel. The identifier
/// travels as a plain `String`: a custom UTI would need to be exported
/// in Info.plist for Launch Services to register it, otherwise drop
/// destinations silently reject the drag. Using `public.utf8-plain-text`
/// sidesteps that. The receiver looks the entry up in
/// `repositoriesConfig` so a stale snapshot can't poison a move.
///
/// A single payload type carries both repositories and groups so one
/// `.dropDestination` per target can disambiguate (move a repo into a
/// group vs. reorder a group) — SwiftUI doesn't reliably support two
/// drop destinations of different types on the same view. The `repo:` /
/// `group:` prefix lets the importer reject the wrong kind.
enum SidebarDragItem: Transferable {
    case repo(UUID)
    case group(UUID)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(
            exporting: { (item: SidebarDragItem) in
                switch item {
                case .repo(let id):  return "repo:" + id.uuidString
                case .group(let id): return "group:" + id.uuidString
                }
            },
            importing: { (string: String) in
                if string.hasPrefix("repo:"),
                   let id = UUID(uuidString: String(string.dropFirst(5))) {
                    return .repo(id)
                }
                if string.hasPrefix("group:"),
                   let id = UUID(uuidString: String(string.dropFirst(6))) {
                    return .group(id)
                }
                throw CocoaError(.formatting)
            }
        )
    }
}

struct RepositoriesPanel: View {
    @Bindable var appState: AppState
    @State private var isDropTargeted: Bool = false
    @State private var hoveredGroup: GroupTarget?
    @State private var showFavoritesOnly: Bool = false
    /// When on, group headers become draggable (so groups can be
    /// reordered) and every row shows a drag handle. Repo rows are
    /// always draggable; this mode is what surfaces the affordance and
    /// unlocks group-level reordering.
    @State private var isRearranging: Bool = false
    /// The repo row currently under a drag — drawn with an insertion
    /// line at its top edge so "drop before this row" reads clearly.
    @State private var dropBeforeRepo: UUID?
    /// The group header currently under a drag while rearranging — drawn
    /// with an insertion line at its top edge ("drop the group before
    /// this one"). Kept separate from `hoveredGroup` (the whole-group
    /// wash used when dropping a *repo* into a group) because a header's
    /// `isTargeted` only reports a Bool, not which kind is being dragged.
    @State private var dropBeforeGroup: GroupTarget?
    /// Folder tree under each repository row. Lives here rather than in
    /// `AppState` because it is pure sidebar presentation — nothing else in
    /// the app needs to know which directories are open.
    @State private var tree = RepoTreeStore()
    /// The file or folder the user last clicked in a repository tree.
    ///
    /// Purely a reading aid — nothing else in the app consumes it. Without it
    /// a click gives no feedback at all, so there is no way to tell which row
    /// a subsequent double-click or right-click will act on.
    @State private var selectedTreePath: String?
    /// The repository row the user last clicked without opening it.
    ///
    /// Only reachable when `singleClickOpensRepo` is off: a click then means
    /// "this is the one I mean" rather than "switch the app to this", and the
    /// row has to say so, since the accent-blue active row is a different
    /// thing entirely and already taken.
    @State private var selectedRepoID: UUID?

    /// `nil` represents the "Other" (ungrouped) bucket so we can compare
    /// hover state without sentinel strings.
    enum GroupTarget: Hashable {
        case named(String)
        case ungrouped

        /// The group name to pass to `AppState`, where `nil` means the
        /// ungrouped "Other" bucket.
        var groupName: String? {
            switch self {
            case .named(let name): return name
            case .ungrouped:       return nil
            }
        }
    }

    /// One line in the scrolling list: a repository, or an entry in the tree
    /// beneath one.
    ///
    /// Flattened into a single sequence rather than nested view builders so
    /// the enclosing `LazyVStack` can realize rows one at a time. Nesting the
    /// tree inside each repository's row would make a whole repository one
    /// lazy element, and expanding a directory with thousands of entries would
    /// build every one of them in the same layout pass.
    private enum SidebarRow: Identifiable {
        case repository(RepositoryEntry)
        case entry(RepoTreeNode)

        var id: String {
            switch self {
            case .repository(let repo): return Self.id(forRepository: repo.id)
            case .entry(let node):      return "node:" + node.path
            }
        }

        /// A repository row's scroll id from its id alone — what a reveal
        /// has to work from, holding a `UUID` rather than the entry.
        static func id(forRepository repo: UUID) -> String {
            "repo:" + repo.uuidString
        }
    }

    private func sidebarRows(for repositories: [RepositoryEntry]) -> [SidebarRow] {
        repositories.flatMap { repo in
            [SidebarRow.repository(repo)] + tree.rows(under: repo.path).map(SidebarRow.entry)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Repositories") {
                Button {
                    showFavoritesOnly.toggle()
                    if showFavoritesOnly { isRearranging = false }
                    hoveredGroup = nil
                } label: {
                    Image(systemName: showFavoritesOnly ? "star.fill" : "star")
                        .scaledFont(11, weight: .semibold)
                        .foregroundStyle(showFavoritesOnly ? Color.yellow : Color.textSecondary)
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help(showFavoritesOnly ? "Show all repositories" : "Show favorite repositories")

                // Three-bar handle toggles "rearrange mode" — drag rows
                // to reorder them within or across groups, and drag group
                // headers to reorder the groups themselves.
                Button {
                    isRearranging.toggle()
                    if isRearranging { showFavoritesOnly = false }
                    hoveredGroup = nil
                    dropBeforeRepo = nil
                    dropBeforeGroup = nil
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .scaledFont(11, weight: .semibold)
                        .foregroundStyle(isRearranging ? Color.accentBlue : Color.textSecondary)
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help(isRearranging ? "Done rearranging" : "Rearrange repositories and groups")

                RepositoryAddMenu(appState: appState)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if showFavoritesOnly {
                            ForEach(sidebarRows(for: favoriteRepositories)) { item in
                                switch item {
                                case .repository(let repo): flatRow(for: repo)
                                case .entry(let node):      treeRow(node)
                                }
                            }
                            if favoriteRepositories.isEmpty {
                                Text("No favorite repositories")
                                    .foregroundStyle(Color.textDisabled)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                            }
                        } else {
                            ForEach(appState.repositoriesConfig.groups) { group in
                                groupHeader(
                                    label: group.name,
                                    systemImage: "folder",
                                    target: .named(group.name),
                                    groupID: group.id,
                                    isExpanded: group.expanded
                                )
                                if group.expanded {
                                    ForEach(sidebarRows(for: group.repositories)) { item in
                                        switch item {
                                        case .repository(let repo):
                                            row(for: repo, target: .named(group.name))
                                        case .entry(let node):
                                            treeRow(node)
                                        }
                                    }
                                }
                            }
                            if !appState.repositoriesConfig.ungrouped.isEmpty
                                || !appState.repositoriesConfig.groups.isEmpty {
                                groupHeader(
                                    label: "Other",
                                    systemImage: nil,
                                    target: .ungrouped,
                                    groupID: nil,
                                    isExpanded: appState.repositoriesConfig.ungroupedExpanded
                                )
                                if appState.repositoriesConfig.ungroupedExpanded {
                                    ForEach(sidebarRows(for: appState.repositoriesConfig.ungrouped)) { item in
                                        switch item {
                                        case .repository(let repo):
                                            row(for: repo, target: .ungrouped)
                                        case .entry(let node):
                                            treeRow(node)
                                        }
                                    }
                                }
                            }
                            if appState.allRepositories.isEmpty {
                                Text("No repositories yet")
                                    .foregroundStyle(Color.textDisabled)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                // "Open as Repository" hands the main window a repository whose
                // row may be far outside the visible part of a long list — or
                // brand new to it. Only that flow sets the target: scrolling on
                // every change of active repository would move the list under
                // someone reading it.
                .onChange(of: appState.sidebarRevealTarget) { _, target in
                    guard let target else { return }
                    // Cleared at once — it is a request to scroll, not a record
                    // of where the list is, and asking for the same repository
                    // again has to count as a new request.
                    appState.sidebarRevealTarget = nil
                    // Next tick: a repository that was added a moment ago has no
                    // row yet in the pass that carried the request.
                    Task { @MainActor in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(SidebarRow.id(forRepository: target), anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color.bgPanel)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentBlue, lineWidth: isDropTargeted ? 2 : 0)
                .padding(2)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        // Keyed on the paths, not the array: a repository being renamed or
        // reordered leaves its tree alone, while one being removed drops it.
        .onChange(of: appState.allRepositories.map(\.path)) { _, paths in
            tree.prune(keepingUnder: paths)
        }
        // A click-selection means "this row, which I have not opened". Once
        // something *is* opened — from here, from the context menu, from
        // anywhere — that mark is stale, and leaving it behind would put a
        // grey row and a blue row on screen claiming to be the same answer.
        .onChange(of: appState.activeRepo?.id) { _, _ in
            selectedRepoID = nil
        }
    }

    private var favoriteRepositories: [RepositoryEntry] {
        appState.allRepositories.filter(\.isFavorite)
    }

    @ViewBuilder
    private func row(for repo: RepositoryEntry, target: GroupTarget) -> some View {
        let isActive = repo.id == appState.activeRepo?.id
        HStack(spacing: 4) {
            if isRearranging {
                Image(systemName: "line.3.horizontal")
                    .scaledFont(10)
                    .foregroundStyle(Color.textDisabled)
                    .frame(width: 12)
            }
            disclosure(for: repo)
            RepoRow(
                repo: repo,
                active: isActive,
                availability: appState.availability(for: repo)
            )
        }
            .padding(.leading, isRearranging ? 8 : 10)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(background(
                active: isActive,
                selected: selectedRepoID == repo.id,
                target: target
            ))
            // Insertion line at the top edge marks "drop before this row".
            .overlay(alignment: .top) {
                insertionLine(visible: dropBeforeRepo == repo.id)
            }
            .onTapGesture { click(repo) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { doubleClick(repo) })
            .contextMenu {
                RepositoryContextMenu(repo: repo, appState: appState)
            }
            .draggable(SidebarDragItem.repo(repo.id)) {
                DragPreview(repo: repo)
            }
            .dropDestination(for: SidebarDragItem.self) { items, _ in
                handleRowDrop(items: items, target: target, before: repo.id)
            } isTargeted: { hovering in
                dropBeforeRepo = hovering ? repo.id : (dropBeforeRepo == repo.id ? nil : dropBeforeRepo)
            }
    }

    @ViewBuilder
    private func flatRow(for repo: RepositoryEntry) -> some View {
        let isActive = repo.id == appState.activeRepo?.id
        HStack(spacing: 4) {
            disclosure(for: repo)
            RepoRow(
                repo: repo,
                active: isActive,
                availability: appState.availability(for: repo)
            )
        }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(background(
                active: isActive,
                selected: selectedRepoID == repo.id,
                target: nil
            ))
            .onTapGesture { click(repo) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { doubleClick(repo) })
            .contextMenu {
                RepositoryContextMenu(repo: repo, appState: appState)
            }
            .draggable(SidebarDragItem.repo(repo.id)) {
                DragPreview(repo: repo)
            }
    }

    /// One click on a repository row: it opens the repository, or only marks
    /// it, depending on what the user asked for in Settings. Both readings of
    /// a click are reasonable and they do not cost the same — opening reloads
    /// every panel around a repository you may not have meant, while marking
    /// one costs a second click.
    ///
    /// A plain tap plus a *simultaneous* double-tap, rather than two
    /// `onTapGesture(count:)` recognizers on one view: sharing them makes
    /// SwiftUI hold the single tap for the system double-click interval to
    /// disambiguate, which delays the highlight visibly. Same pattern as the
    /// tree rows below.
    private func click(_ repo: RepositoryEntry) {
        guard appState.appConfig.singleClickOpensRepo else {
            selectedRepoID = repo.id
            return
        }
        // Nothing to mark in this mode: the row is about to be the active
        // one, and painting it grey on the way there is a flash of an answer
        // that was never true.
        Task { await appState.selectRepo(repo) }
    }

    /// Two clicks open the repository. In single-click mode the first click
    /// already did, so this stays out of the way rather than asking for the
    /// same load twice.
    private func doubleClick(_ repo: RepositoryEntry) {
        guard !appState.appConfig.singleClickOpensRepo else { return }
        Task { await appState.selectRepo(repo) }
    }

    /// Twist-down for a repository's folder tree.
    ///
    /// Hidden for a repository whose folder is missing — there is nothing to
    /// browse — but kept for a folder that isn't a git repository yet, since
    /// looking inside is exactly how you decide whether to init it.
    @ViewBuilder
    private func disclosure(for repo: RepositoryEntry) -> some View {
        if appState.availability(for: repo) == .missingPath {
            // Empty spacer of the same width, so names stay aligned down the
            // column instead of stepping left around the missing control.
            Color.clear.frame(width: 12, height: 12)
        } else {
            Button {
                tree.toggle(repo.path, depth: 0)
            } label: {
                Image(systemName: tree.isExpanded(repo.path) ? "chevron.down" : "chevron.right")
                    .scaledFont(9, weight: .semibold)
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tree.isExpanded(repo.path) ? "Hide files" : "Show files")
        }
    }

    /// One file or folder beneath a repository.
    @ViewBuilder
    private func treeRow(_ node: RepoTreeNode) -> some View {
        let isSelected = selectedTreePath == node.path
        HStack(spacing: 4) {
            if node.isDirectory {
                Button {
                    tree.toggle(node.path, depth: node.depth + 1)
                } label: {
                    Image(systemName: tree.isExpanded(node.path) ? "chevron.down" : "chevron.right")
                        .scaledFont(9, weight: .semibold)
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }

            Image(systemName: node.isDirectory ? "folder" : "doc")
                .scaledFont(10)
                .foregroundStyle(isSelected ? Color.white : Color.textSecondary)

            Text(node.name)
                .scaledFont(11)
                .foregroundStyle(isSelected ? Color.white : Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            if tree.isLoading(node.path) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            }
            Spacer(minLength: 0)
        }
        // Indent one step per level, from where a repository's own name sits.
        .padding(.leading, 26 + CGFloat(node.depth) * 13)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `bgSelected`, not `accentBlue`. The bright accent means "this is the
        // active repository" — real state that drives the Files, Diff and
        // Journal panels — and painting a clicked file the same way made the
        // two read as one multi-row selection, which is neither what happened
        // nor something this list supports. `bgSelected` is the app's
        // list-row-selection colour (the Journal already uses it), so the
        // clicked row now reads as subordinate to the active repository above
        // it rather than as a peer of it.
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 3).fill(Color.bgSelected)
            }
        }
        .contentShape(Rectangle())
        // Single click selects — and, for a folder, also toggles, since a
        // twist-down is cheap to undo and expanding is what you nearly always
        // want from a folder. Opening a file is not cheap to undo: it launches
        // an application, so it waits for a double-click, the way Finder and
        // every file tree behave.
        //
        // A plain tap plus a *simultaneous* double-tap, rather than two
        // `onTapGesture(count:)` recognizers on one view: sharing them makes
        // SwiftUI hold the single tap for the system double-click interval to
        // disambiguate, which delays selection visibly. Same pattern as the
        // diff and journal rows.
        .onTapGesture {
            selectedTreePath = node.path
            if node.isDirectory {
                tree.toggle(node.path, depth: node.depth + 1)
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                selectedTreePath = node.path
                if !node.isDirectory {
                    appState.openInFinder(path: node.path)
                }
            }
        )
        .contextMenu {
            RepoTreeContextMenu(node: node, appState: appState) {
                // A file has nothing of its own to re-read, so refreshing one
                // refreshes the folder holding it — which is what "this is
                // out of date" actually means when you right-click a file.
                if node.isDirectory {
                    tree.refresh(node.path, depth: node.depth + 1)
                } else {
                    tree.refresh(
                        (node.path as NSString).deletingLastPathComponent,
                        depth: node.depth
                    )
                }
            }
        }
    }

    /// Plain view inside a `LazyVStack` rather than a `List` section
    /// header — `List(.sidebar)` is backed by `NSOutlineView` on macOS,
    /// and its drag machinery starves custom `.dropDestination`
    /// modifiers on rows and headers of hover events.
    @ViewBuilder
    private func groupHeader(
        label: String,
        systemImage: String?,
        target: GroupTarget,
        groupID: UUID?,
        isExpanded: Bool
    ) -> some View {
        let base = HStack(spacing: 4) {
            if isRearranging {
                Image(systemName: "line.3.horizontal")
                    .scaledFont(10)
                    .foregroundStyle(Color.textDisabled)
                    .frame(width: 12)
            }
            // Chevron rotates rather than swapping symbols so the
            // expand/collapse reads as a continuous motion the way
            // SmartGit / Finder sidebars handle it.
            Image(systemName: "chevron.right")
                .scaledFont(9, weight: .semibold)
                .foregroundStyle(Color.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
                .animation(.easeOut(duration: 0.12), value: isExpanded)
            if let systemImage {
                Image(systemName: systemImage)
                    .scaledFont(11)
                    .foregroundStyle(Color.textGroupHeader)
            }
            Text(label)
                .scaledFont(11, weight: .bold)
                .foregroundStyle(Color.textGroupHeader)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(background(active: false, target: target))
        // While rearranging, a header shows a thin "insert before this
        // group" line rather than the whole-group wash, so reordering
        // reads like the repo rows do.
        .overlay(alignment: .top) {
            insertionLine(visible: isRearranging && dropBeforeGroup == target)
        }
        .onTapGesture {
            Task { await appState.toggleGroupExpansion(target.groupName) }
        }
        .contextMenu {
            let contextGroup: String? = target.groupName
            AddRepositoryButton(appState: appState, targetGroup: contextGroup,
                                identifier: "repositories.addToGroup.\(contextGroup ?? "ungrouped")")
            Button("Clone…") {
                appState.pendingCloneGroup = contextGroup
                appState.showCloneSheet = true
            }
            // Only named groups get rename/delete — "Other" is the
            // catch-all bucket and there's no meaningful rename or
            // delete operation for it.
            if case .named(let name) = target {
                Divider()
                Button("Rename Group…") {
                    appState.pendingGroupRename = AppState.GroupRenameTarget(name: name)
                }
                Divider()
                Button("Delete Group", role: .destructive) {
                    let count = appState.repositoriesConfig.groups
                        .first(where: { $0.name == name })?.repositories.count ?? 0
                    appState.pendingGroupDelete = AppState.GroupDeleteTarget(
                        name: name,
                        repoCount: count
                    )
                }
            }
        }
        .dropDestination(for: SidebarDragItem.self) { items, _ in
            handleHeaderDrop(items: items, target: target, groupID: groupID)
        } isTargeted: { hovering in
            // Rearranging: feed the thin insertion line. Otherwise: the
            // whole-group wash that signals "drop this repo into here".
            if isRearranging {
                dropBeforeGroup = hovering ? target : (dropBeforeGroup == target ? nil : dropBeforeGroup)
            } else {
                hoveredGroup = hovering ? target : (hoveredGroup == target ? nil : hoveredGroup)
            }
        }

        // A group is only draggable (for reordering) in rearrange mode,
        // and only named groups reorder — the trailing "Other" bucket is
        // a fixed catch-all, so it has no `groupID` and stays put.
        if isRearranging, let groupID {
            base.draggable(SidebarDragItem.group(groupID)) {
                GroupDragPreview(label: label)
            }
        } else {
            base
        }
    }

    @ViewBuilder
    private func background(
        active: Bool,
        selected: Bool = false,
        target: GroupTarget?
    ) -> some View {
        if let target, hoveredGroup == target {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentBlue.opacity(0.18))
        } else if active {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentBlue)
        } else if selected {
            // `bgSelected`, not the accent: the accent means "this is the
            // active repository", and a row that is merely clicked is
            // subordinate to that, not a second one of it. The tree rows
            // below draw a click the same way.
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.bgSelected)
        }
    }

    @ViewBuilder
    private func insertionLine(visible: Bool) -> some View {
        if visible {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentBlue)
                .frame(height: 2)
                .padding(.horizontal, 8)
        }
    }

    /// Drop landing on a repo row: a dragged repo is inserted *before*
    /// this row (reorder within the group or move in from another group).
    /// A dragged group is meaningless here, so it's rejected.
    private func handleRowDrop(
        items: [SidebarDragItem],
        target: GroupTarget,
        before repoID: UUID
    ) -> Bool {
        // Clear the hover feedback regardless of outcome — SwiftUI's
        // `isTargeted` callback is racy when overlapping drop
        // destinations hand off, and stale state otherwise leaves a
        // second highlight painted under the cursor.
        dropBeforeRepo = nil
        dropBeforeGroup = nil
        hoveredGroup = nil
        guard case .repo(let id) = items.first,
              let entry = appState.allRepositories.first(where: { $0.id == id })
        else { return false }
        Task { await appState.moveRepository(entry, toGroup: target.groupName, before: repoID) }
        return true
    }

    /// Drop landing on a group header. A dragged repo is appended to the
    /// group (handy for collapsed or empty groups); a dragged group is
    /// reordered to land before this header's group — or to the end when
    /// dropped on the trailing "Other" bucket (`groupID == nil`).
    private func handleHeaderDrop(
        items: [SidebarDragItem],
        target: GroupTarget,
        groupID: UUID?
    ) -> Bool {
        hoveredGroup = nil
        dropBeforeRepo = nil
        dropBeforeGroup = nil
        switch items.first {
        case .repo(let id):
            guard let entry = appState.allRepositories.first(where: { $0.id == id })
            else { return false }
            Task { await appState.moveRepository(entry, toGroup: target.groupName) }
            return true
        case .group(let draggedGroupID):
            Task { await appState.moveGroup(draggedGroupID, before: groupID) }
            return true
        case nil:
            return false
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        hoveredGroup = nil
        var accepted = false
        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    await appState.addRepository(at: url.path)
                }
            }
        }
        return accepted
    }
}

private struct RepoRow: View {
    let repo: RepositoryEntry
    let active: Bool
    let availability: RepositoryAvailability

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .scaledFont(11)
                .foregroundStyle(iconColor)
            Text(repo.name)
                .scaledFont(12, weight: active ? .semibold : .regular)
                .foregroundStyle(active ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if availability.isAvailable, let branch = repo.currentBranch {
                metadataText("(\(branch))")
            } else if availability.isAvailable, active {
                // No branch on the repository the app is looking at means a
                // detached HEAD — it was just read to find that out. Saying so
                // beats an empty space where every other row has a name, and
                // it is the state that makes the next pull fail. Only for the
                // active row: the others carry the name last seen, and a
                // blank one there means "not looked at yet".
                metadataText("(detached)")
            } else if !availability.isAvailable {
                metadataText("(\(availability.sidebarBadge))")
            }
            Spacer(minLength: 0)
        }
    }

    private var iconName: String {
        switch availability {
        case .available:
            return active ? "book" : "book.closed"
        case .missingPath:
            return "questionmark.folder"
        case .notRepository:
            return "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        if active { return .white }
        switch availability {
        case .available:     return Color.textSecondary
        case .missingPath:   return Color.red.opacity(0.9)
        case .notRepository: return Color.orange.opacity(0.9)
        }
    }

    private func metadataText(_ text: String) -> some View {
        Text(text)
            .scaledFont(10)
            .foregroundStyle(active ? Color.white.opacity(0.75) : metadataColor)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var metadataColor: Color {
        switch availability {
        case .available:     return Color.textSecondary
        case .missingPath:   return Color.red.opacity(0.9)
        case .notRepository: return Color.orange.opacity(0.9)
        }
    }
}

/// Compact pill shown under the cursor while dragging a repo row.
/// Without an explicit preview SwiftUI snapshots the source row, which
/// looks misaligned against the sidebar background.
private struct DragPreview: View {
    let repo: RepositoryEntry

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "book.closed")
            Text(repo.name)
                .lineLimit(1)
        }
        .scaledFont(12, weight: .medium)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.bgPanelHeader)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.borderColor, lineWidth: 0.5)
                )
        )
    }
}

/// Compact pill shown under the cursor while dragging a group header to
/// reorder it. Mirrors `DragPreview` so a dragged group reads the same
/// as a dragged repo, just with a folder glyph.
private struct GroupDragPreview: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(label)
                .lineLimit(1)
        }
        .scaledFont(12, weight: .medium)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.bgPanelHeader)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.borderColor, lineWidth: 0.5)
                )
        )
    }
}
