import Foundation
import Observation

/// One entry in a repository's on-disk tree.
struct RepoTreeNode: Identifiable, Hashable, Sendable {
    /// Absolute path — the identity, since two directories can hold files of
    /// the same name and the flattened row list mixes them freely.
    let path: String
    let name: String
    let isDirectory: Bool
    /// Levels below the repository row, so the renderer can indent without
    /// walking back up the tree for every row it draws.
    let depth: Int

    var id: String { path }
}

/// Backs the folder tree under each repository in the sidebar.
///
/// Everything here is lazy and cached, because the alternative does not scale:
/// a repository like a large iOS app holds tens of thousands of files, and
/// walking it eagerly — or re-walking it on every SwiftUI update pass — would
/// stall the sidebar for a tree the user may never open. Directories are read
/// only when first expanded, and the result is kept until it is explicitly
/// refreshed.
@MainActor
@Observable
final class RepoTreeStore {

    /// Listings by parent path. A present-but-empty array means "read, and
    /// genuinely empty", which is why this is not merged with `loading`.
    private(set) var children: [String: [RepoTreeNode]] = [:]
    private(set) var expanded: Set<String> = []
    /// Directories with a read in flight, so the row can show progress and a
    /// second click can't start the same scan twice.
    private(set) var loading: Set<String> = []

    /// Cap on retained listings.
    ///
    /// Listings are kept after a directory is collapsed so re-opening it is
    /// instant, and they were kept for every directory ever opened in every
    /// repository in the sidebar — pruned only when a repository was removed.
    /// Browsing around a few large projects therefore accumulated tens of
    /// thousands of nodes that nothing was going to read again.
    private let maxCachedListings: Int
    /// Directory paths in least-recently-read order.
    private var recency: [String] = []

    init(maxCachedListings: Int = 400) {
        self.maxCachedListings = max(1, maxCachedListings)
    }

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }
    func isLoading(_ path: String) -> Bool { loading.contains(path) }

    /// `nil` while a directory has never been read — the row uses this to tell
    /// "not looked yet" from "looked, nothing there".
    func loadedChildren(of path: String) -> [RepoTreeNode]? { children[path] }

    // MARK: - Expansion

    func toggle(_ path: String, depth: Int = 0) {
        if expanded.contains(path) {
            collapse(path)
        } else {
            expand(path, depth: depth)
        }
    }

    func expand(_ path: String, depth: Int = 0) {
        expanded.insert(path)
        // Only on a first look. Re-reading on every expand would make
        // collapsing and reopening a large directory cost a full scan each
        // time; `refresh` is there for when the disk has actually changed.
        if children[path] == nil { load(path, depth: depth) }
    }

    func collapse(_ path: String) {
        expanded.remove(path)
    }

    /// Forget a directory's listing and read it again.
    ///
    /// The tree is a snapshot of the filesystem, and nothing here watches for
    /// changes — a build or a branch switch can leave it stale, and this is
    /// the way back without closing and reopening the app.
    func refresh(_ path: String, depth: Int = 0) {
        children[path] = nil
        recency.removeAll { $0 == path }
        // Descendants are dropped too: their rows are unreachable once the
        // parent's listing is replaced, and keeping them would leave entries
        // cached for directories that may no longer exist.
        // Snapshotted before mutating: `children.keys` is a live view onto the
        // dictionary, so removing through it while iterating is undefined.
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for key in Array(children.keys) where key.hasPrefix(prefix) {
            children[key] = nil
            recency.removeAll { $0 == key }
        }
        for key in Array(expanded) where key.hasPrefix(prefix) {
            expanded.remove(key)
        }
        if expanded.contains(path) { load(path, depth: depth) }
    }

    /// Forget anything not inside one of `repoPaths`.
    ///
    /// Removing a repository from the sidebar would otherwise leave its
    /// listings cached for the rest of the session — and someone who expanded
    /// a `node_modules` before removing the repo is holding tens of thousands
    /// of nodes for a tree that no longer has a row.
    func prune(keepingUnder repoPaths: [String]) {
        let roots = repoPaths.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        func isKept(_ path: String) -> Bool {
            repoPaths.contains(path) || roots.contains { path.hasPrefix($0) }
        }
        for key in Array(children.keys) where !isKept(key) { children[key] = nil }
        recency.removeAll { !isKept($0) }
        for key in Array(expanded) where !isKept(key) { expanded.remove(key) }
        for key in Array(loading) where !isKept(key) { loading.remove(key) }
    }

    // MARK: - Rows

    /// The visible descendants of `repoPath`, in display order.
    ///
    /// Flat rather than nested so the sidebar's `LazyVStack` can realize one
    /// row at a time. Handing SwiftUI a nested structure would make an entire
    /// repository a single lazy element, and expanding one large directory
    /// would build every row in it in the same layout pass.
    func rows(under repoPath: String) -> [RepoTreeNode] {
        guard expanded.contains(repoPath) else { return [] }
        var out: [RepoTreeNode] = []
        appendChildren(of: repoPath, into: &out)
        return out
    }

    private func appendChildren(of path: String, into out: inout [RepoTreeNode]) {
        guard let nodes = children[path] else { return }
        for node in nodes {
            out.append(node)
            if node.isDirectory, expanded.contains(node.path) {
                appendChildren(of: node.path, into: &out)
            }
        }
    }

    // MARK: - Loading

    private func load(_ path: String, depth: Int) {
        guard !loading.contains(path) else { return }
        loading.insert(path)
        Task { [weak self] in
            // Off the main actor: reading a directory is a synchronous
            // filesystem call, and `node_modules` or a build folder can hold
            // tens of thousands of entries.
            let nodes = await Task.detached(priority: .userInitiated) {
                RepoTreeStore.scan(path: path, depth: depth)
            }.value
            guard let self else { return }
            self.children[path] = nodes
            self.loading.remove(path)
            self.recency.removeAll { $0 == path }
            self.recency.append(path)
            self.evictIfNeeded()
        }
    }

    /// Drops the least-recently-read listings once over the cap.
    ///
    /// Only listings for *collapsed* directories are eligible. An expanded
    /// directory's listing is load-bearing — `rows` reads it to render the
    /// children on screen — so evicting one would silently empty a folder the
    /// user is looking at. Those stay until the user collapses them, which
    /// bounds the exception to what is actually visible.
    private func evictIfNeeded() {
        guard children.count > maxCachedListings else { return }
        var index = 0
        while children.count > maxCachedListings, index < recency.count {
            let path = recency[index]
            if expanded.contains(path) {
                index += 1
                continue
            }
            recency.remove(at: index)
            children[path] = nil
        }
    }

    /// Directory names never worth showing in a repository tree.
    ///
    /// `.git` is the repository's own plumbing — thousands of loose objects
    /// and refs — so expanding it accidentally buries the tree in noise. Other
    /// dotfiles are kept: `.github`, `.agents` and friends are ordinary
    /// project content that people do go looking for.
    nonisolated static let hiddenNames: Set<String> = [".git", ".DS_Store"]

    /// Lists one directory.
    ///
    /// Child paths are built by appending to `path` rather than taken from the
    /// URLs `FileManager` hands back, and that is load-bearing: the URL-based
    /// listing returns *resolved* paths, so a repository at `/var/…` comes
    /// back with children under `/private/var/…`. The tree is keyed by path,
    /// so a parent and its children would then disagree about who they are,
    /// and expanding a folder would silently splice its rows in nowhere. It
    /// also keeps `Copy Path` reporting the path the user configured instead
    /// of a resolved form they never typed.
    nonisolated static func scan(path: String, depth: Int) -> [RepoTreeNode] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            // Unreadable directories come back empty rather than erroring: a
            // permission-denied folder should render as empty, not break the
            // sidebar around it.
            return []
        }

        let nodes = names.compactMap { name -> RepoTreeNode? in
            guard !hiddenNames.contains(name) else { return nil }
            let childPath = (path as NSString).appendingPathComponent(name)
            // Follows symlinks, so a symlinked source directory expands like
            // the real thing — which is what Finder does.
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: childPath, isDirectory: &isDirectory)
            return RepoTreeNode(
                path: childPath,
                name: name,
                isDirectory: isDirectory.boolValue,
                depth: depth
            )
        }

        return nodes.sorted(by: displayOrder)
    }

    /// Folders first, then case-insensitive by name — the ordering every file
    /// tree uses, and the one that makes a deep hierarchy scannable.
    /// Ties break on the raw name so the sort is total and stable across runs.
    nonisolated static func displayOrder(_ left: RepoTreeNode, _ right: RepoTreeNode) -> Bool {
        if left.isDirectory != right.isDirectory { return left.isDirectory }
        let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return left.name < right.name
    }
}
