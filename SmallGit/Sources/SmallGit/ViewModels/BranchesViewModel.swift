import Foundation
import Observation

@MainActor
@Observable
final class BranchesViewModel {

    var localBranches: [GitBranch] = []
    var remoteBranches: [GitBranch] = []
    var tags: [String] = []
    var currentBranch: String?
    /// What the Branches panel has selected.
    ///
    /// Typed rather than a bare name because the panel lists four different
    /// kinds of thing whose names share a namespace only by accident: a branch
    /// and a tag can both be called `v1.0`, and a plain string would highlight
    /// both at once. It was previously branch-only, which is why tags, stashes
    /// and submodules could not be selected at all.
    ///
    /// A set, not one value: ⌘- and ⇧-click extend it, and the right-click
    /// menu acts on every row in it — deleting a batch of merged branches is
    /// one gesture rather than one sheet each.
    var selection: Set<SidebarSelection> = []
    /// Free-text filter applied to branch names + upstream names.
    /// Matches are case-insensitive substring containment. Tags use the
    /// raw tag string.
    var filterText: String = ""

    /// Per-section expand state for the Branches panel. Local is open
    /// by default (the user's day-to-day list); the heavier Remote
    /// and Tags sections start collapsed since big repos have
    /// thousands of each. Survives only the session — not persisted.
    var localExpanded: Bool = true
    var remoteExpanded: Bool = false
    var tagsExpanded: Bool = false
    var stashesExpanded: Bool = true
    var submodulesExpanded: Bool = true

    /// Ids of the branch folders that are open, across both trees.
    ///
    /// Held here rather than left to `OutlineGroup`, which keeps its
    /// expansion private: revealing the checked-out branch means opening the
    /// folders standing above it, and a folder nobody can open from code is a
    /// folder that hides the row we were asked to scroll to. Ids carry their
    /// tree's root, so local and remote can share one set. Session-only, like
    /// the section flags above.
    var expandedFolders: Set<String> = []

    static let localRoot = "Local Branches"
    static let remoteRoot = "Remote Branches"

    private let coordinator: CacheCoordinator
    private let git: GitService

    init(coordinator: CacheCoordinator, git: GitService = .shared) {
        self.coordinator = coordinator
        self.git = git
    }

    // MARK: - Filtered views

    var filteredLocalBranches: [GitBranch] {
        Self.filterBranches(localBranches, query: filterText)
    }

    var filteredRemoteBranches: [GitBranch] {
        Self.filterBranches(remoteBranches, query: filterText)
    }

    var filteredTags: [String] {
        Self.filterTags(tags, query: filterText)
    }

    /// Total entries hidden by the active filter (local + remote + tags).
    var hiddenCount: Int {
        let total = localBranches.count + remoteBranches.count + tags.count
        let shown = filteredLocalBranches.count + filteredRemoteBranches.count + filteredTags.count
        return max(0, total - shown)
    }

    /// Nested folder tree built from "/" segments — e.g. `feature/login`
    /// becomes `feature` → `login`. Built from the filtered list so the
    /// folder structure collapses to only paths the user is searching for.
    var localTree: BranchTreeNode {
        BranchTreeNode.build(from: filteredLocalBranches, root: Self.localRoot)
    }

    var remoteTree: BranchTreeNode {
        BranchTreeNode.build(from: filteredRemoteBranches, root: Self.remoteRoot)
    }

    /// A tree flattened to the lines actually drawn: the children of a shut
    /// folder are left out, and each row carries the depth its indentation
    /// used to come from.
    ///
    /// Flattened rather than nested `DisclosureGroup`s because a disclosure
    /// group inside a sidebar list keeps its own open/shut state and will not
    /// reopen from its binding once it has been drawn. That left the
    /// checked-out branch's row undrawn after a repository switch — and a row
    /// that isn't drawn is one `scrollTo` cannot find, which is why the panel
    /// sat wherever the previous repository had left it. Here "open" is data.
    func rows(of tree: BranchTreeNode) -> [BranchTreeRow] {
        var rows: [BranchTreeRow] = []
        func walk(_ nodes: [BranchTreeNode], depth: Int) {
            for node in nodes {
                rows.append(BranchTreeRow(node: node, depth: depth))
                if !node.children.isEmpty, expandedFolders.contains(node.id) {
                    walk(node.children, depth: depth + 1)
                }
            }
        }
        walk(tree.children, depth: 0)
        return rows
    }

    // MARK: - Resolving a selection

    /// The branch a `.branch` selection names, from either tree. Local first:
    /// a remote branch is listed under its full `origin/…` name, so the two
    /// namespaces can't collide.
    func branch(named name: String) -> GitBranch? {
        localBranches.first { $0.name == name }
            ?? remoteBranches.first { $0.name == name }
    }

    /// Every branch under a folder row, found by the row id the panel selects
    /// folders with. A folder stands for its whole subtree — the same reading
    /// its tri-state checkbox already gives it.
    func branches(underFolder id: String) -> [GitBranch] {
        // Local first and only then remote: each of these builds a tree, and
        // a repository's remote list is the long one.
        if let node = localTree.node(withID: id) { return node.branchesUnder }
        return remoteTree.node(withID: id)?.branchesUnder ?? []
    }

    /// The branches a selection covers, with folders expanded to their
    /// contents (in tree order) and duplicates dropped — a selection can hold
    /// both a folder and a branch inside it.
    func branches(in selection: Set<SidebarSelection>) -> [GitBranch] {
        var seen = Set<String>()
        var out: [GitBranch] = []
        for item in selection.sortedForMenu {
            let found: [GitBranch] = switch item {
            case .branch(let name): branch(named: name).map { [$0] } ?? []
            case .folder(let id):   branches(underFolder: id)
            case .head, .tag, .stash, .submodule: []
            }
            for branch in found where seen.insert(branch.name).inserted {
                out.append(branch)
            }
        }
        return out
    }

    /// One click on a folder's chevron.
    func toggleFolder(_ id: String) {
        if expandedFolders.contains(id) {
            expandedFolders.remove(id)
        } else {
            expandedFolders.insert(id)
        }
    }

    /// Open every folder between the Local Branches section and `branch`, and
    /// answer with the id of the row it will be drawn as.
    ///
    /// Both halves of "scroll to it": a row inside a shut folder is not drawn,
    /// so `scrollTo` would quietly do nothing.
    @discardableResult
    func revealLocalBranch(_ branch: String) -> String {
        localExpanded = true
        expandedFolders.formUnion(
            BranchTreeNode.folderIDs(above: branch, root: Self.localRoot)
        )
        return BranchTreeNode.rowID(for: branch, root: Self.localRoot)
    }

    nonisolated static func filterBranches(_ branches: [GitBranch], query: String) -> [GitBranch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return branches }
        return branches.filter { b in
            b.name.lowercased().contains(q)
                || (b.upstream?.lowercased().contains(q) ?? false)
        }
    }

    nonisolated static func filterTags(_ tags: [String], query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return tags }
        return tags.filter { $0.lowercased().contains(q) }
    }

    /// Read from cache, returning a possibly-stale value and scheduling a
    /// background refresh when past `maxAge`. The cheap path used on
    /// routine refreshes (repo switch, filesystem churn).
    func load() async {
        await reload(force: false)
    }

    /// Bypass the cache and write fresh values straight into L1+L2.
    /// Needed after branch-mutating actions (create / delete / rename /
    /// checkout): `coordinator.after` only clears L1, so a plain `load()`
    /// falls through to the stale L2 disk snapshot and merely schedules a
    /// background refresh the view never re-reads — leaving the just-made
    /// branch missing from the panel until the next interaction. Same
    /// reasoning as the Files panel's `forceRefresh`.
    func forceRefresh() async {
        await reload(force: true)
    }

    private func reload(force: Bool) async {
        async let local: [GitBranch]? = read(
            .branchList, as: [GitBranch].self, maxAge: 30, force: force
        ) { [git] repo in try await git.localBranches(repoPath: repo) }

        async let remote: [GitBranch]? = read(
            .remoteBranches, as: [GitBranch].self, maxAge: 60, force: force
        ) { [git] repo in try await git.remoteBranches(repoPath: repo) }

        async let head: String? = read(
            .currentBranch, as: String.self, maxAge: 10, force: force
        ) { [git] repo in (try await git.currentBranch(repoPath: repo)) ?? "" }

        async let tagList: [String]? = read(
            .tagList, as: [String].self, maxAge: 300, force: force
        ) { [git] repo in try await git.tags(repoPath: repo) }

        if let local = await local { self.localBranches = local }
        if let remote = await remote { self.remoteBranches = remote }
        // An empty answer means `symbolic-ref HEAD` failed, and on a repo that
        // read fine otherwise that means one thing: HEAD is detached, so there
        // is no current branch. Keeping the last one — which is what this did
        // — leaves every panel naming a branch the repo is no longer on, and
        // leaves the sidebar label stale with nothing to say why. A nil says
        // the true thing.
        if let head = await head { self.currentBranch = head.isEmpty ? nil : head }
        if let tagList = await tagList { self.tags = tagList }
    }

    private func read<T: Codable & Sendable>(
        _ key: CacheKey,
        as type: T.Type,
        maxAge: TimeInterval,
        force: Bool,
        fetcher: @escaping @Sendable (String) async throws -> T
    ) async -> T? {
        if force {
            return await coordinator.forceRefresh(key, as: type, fetcher: fetcher)
        }
        return await coordinator.get(key, as: type, maxAge: maxAge, fetcher: fetcher)
    }
}

/// One drawn line of a branch tree: a node plus how deep it sits, since a
/// flattened list has to carry the indentation the nesting used to imply.
struct BranchTreeRow: Identifiable {
    let node: BranchTreeNode
    let depth: Int
    var id: String { node.id }
}

/// Recursive tree node used by `BranchesPanel` to render nested folders.
struct BranchTreeNode: Identifiable, Hashable {
    let id: String
    let name: String
    /// Set if this node is a leaf branch (vs. a folder).
    let branch: GitBranch?
    var children: [BranchTreeNode]

    /// The node drawn as `id`, anywhere in this subtree.
    func node(withID id: String) -> BranchTreeNode? {
        if self.id == id { return self }
        for child in children {
            if let hit = child.node(withID: id) { return hit }
        }
        return nil
    }

    /// Every branch in this subtree, in the order the rows are drawn. A leaf
    /// answers with itself, so this reads the same for a branch and for the
    /// folder above it.
    var branchesUnder: [GitBranch] {
        if let branch { return [branch] }
        return children.flatMap(\.branchesUnder)
    }

    /// Every ref under this node — a folder's checkbox ticks its whole
    /// subtree, the way SmartGit's category boxes do.
    var refsUnder: [String] { branchesUnder.map(\.name) }

    /// Id `build` would give a branch's row: the path down from the root,
    /// which is the root plus the branch name's own segments.
    static func rowID(for branch: String, root: String) -> String {
        ([root] + segments(of: branch)).joined(separator: "/")
    }

    /// Ids of the folders a branch sits inside, outermost first — the ones
    /// that have to be open before its row is drawn at all.
    static func folderIDs(above branch: String, root: String) -> [String] {
        var path = root
        return segments(of: branch).dropLast().map { segment in
            path += "/" + segment
            return path
        }
    }

    private static func segments(of branch: String) -> [String] {
        branch.split(separator: "/").map(String.init)
    }

    static func build(from branches: [GitBranch], root: String) -> BranchTreeNode {
        var node = BranchTreeNode(id: root, name: root, branch: nil, children: [])
        for b in branches {
            insert(branch: b, segments: b.pathComponents, into: &node, path: root)
        }
        // Sorting each level by its own segment keeps a folder's contents in
        // order regardless of how the flat list interleaved them — "/" sorts
        // oddly against the punctuation branch names are full of.
        sortChildren(of: &node)
        return node
    }

    private static func sortChildren(of node: inout BranchTreeNode) {
        for i in node.children.indices {
            sortChildren(of: &node.children[i])
        }
        node.children.sort { lhs, rhs in
            switch lhs.name.naturalCompare(rhs.name) {
            case .orderedAscending:  return true
            case .orderedDescending: return false
            // A folder and a branch of the same name can't both exist in git,
            // but the order still has to be deterministic.
            case .orderedSame:       return lhs.branch == nil && rhs.branch != nil
            }
        }
    }

    private static func insert(
        branch: GitBranch,
        segments: [String],
        into parent: inout BranchTreeNode,
        path: String
    ) {
        guard let head = segments.first else { return }
        let rest = Array(segments.dropFirst())
        let isLeaf = rest.isEmpty
        let childPath = path + "/" + head

        if let i = parent.children.firstIndex(where: {
            $0.name == head && ($0.branch != nil) == isLeaf
        }) {
            insert(branch: branch, segments: rest, into: &parent.children[i], path: childPath)
        } else {
            var newChild = BranchTreeNode(
                id: childPath,
                name: head,
                branch: isLeaf ? branch : nil,
                children: []
            )
            insert(branch: branch, segments: rest, into: &newChild, path: childPath)
            parent.children.append(newChild)
        }
    }
}
