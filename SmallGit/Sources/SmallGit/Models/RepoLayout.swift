import Foundation

/// Where a repository keeps its metadata.
///
/// For an ordinary checkout this is the obvious thing and there is nothing to
/// look up: a work tree with a `.git` directory inside it. It comes apart for
/// the two shapes where `.git` is a *file* holding a `gitdir:` line — a linked
/// worktree (`git worktree add`) and a submodule. There, the per-worktree
/// state (`HEAD`, `index`, the paused-operation markers) lives in `gitDir`
/// somewhere else entirely, while refs, `packed-refs` and config are shared
/// with the main checkout in `commonDir`, which is somewhere else again.
///
/// Assuming `<workTree>/.git` for either of those finds nothing at all, and
/// finds it silently: `FileManager` reports no `rebase-merge` under a path
/// that is a file rather than a directory, and an FSEvents stream rooted at
/// the work tree never sees a ref change. A paused rebase then reads as no
/// operation in progress, which is how a push reaches git with HEAD detached.
struct RepoLayout: Sendable, Hashable {

    /// The checkout itself — what `CacheCoordinator` calls the repo path.
    let workTree: String
    /// Per-worktree metadata: `HEAD`, `index`, `MERGE_HEAD`, `rebase-merge`.
    let gitDir: String
    /// Metadata shared by every worktree: `refs/`, `packed-refs`, config.
    /// Equal to `gitDir` in an ordinary repository.
    let commonDir: String

    init(workTree: String, gitDir: String, commonDir: String) {
        self.workTree = Self.trimmed(workTree)
        self.gitDir = Self.trimmed(gitDir)
        self.commonDir = Self.trimmed(commonDir)
    }

    /// The shape an ordinary checkout has. Used as the answer before git has
    /// been asked, as the fallback when asking fails, and by the call sites
    /// that only ever deal in ordinary repositories.
    static func assumed(workTree: String) -> RepoLayout {
        let dotGit = (trimmed(workTree) as NSString).appendingPathComponent(".git")
        return RepoLayout(workTree: workTree, gitDir: dotGit, commonDir: dotGit)
    }

    /// `true` when this checkout's metadata is a subdirectory of a store it
    /// shares with others — i.e. `git worktree add` made it.
    ///
    /// Asked of the two directories rather than of the work-tree path,
    /// because `--absolute-git-dir` always answers with symlinks resolved:
    /// an ordinary repository opened through a symlinked path has a `gitDir`
    /// that does not spell out as `<workTree>/.git` and is not linked at all.
    /// A submodule reports the two as equal, which is the right answer here —
    /// nothing about its metadata belongs to a different checkout.
    var isLinkedWorktree: Bool { gitDir != commonDir }

    /// Absolute path of `name` inside the per-worktree metadata directory.
    func gitPath(_ name: String) -> String {
        (gitDir as NSString).appendingPathComponent(name)
    }

    /// Directories an FSEvents stream must cover to see every change this
    /// repository's caches depend on.
    ///
    /// Any path already contained in another is dropped: a stream handed both
    /// a directory and its parent reports each change under it twice, and for
    /// an ordinary repository all three collapse to the work tree — which is
    /// exactly the single root the watcher used before linked layouts were
    /// understood.
    var watchRoots: [String] {
        Self.minimalRoots([workTree, gitDir, commonDir])
    }

    /// The given paths with every one that lives inside another removed,
    /// order preserved.
    static func minimalRoots(_ paths: [String]) -> [String] {
        var unique: [String] = []
        for path in paths.map(trimmed) where !unique.contains(path) {
            unique.append(path)
        }
        return unique.filter { candidate in
            !unique.contains { $0 != candidate && candidate.hasPrefix($0 + "/") }
        }
    }

    /// Trailing slashes make prefix comparison a special case everywhere it
    /// is used, so they are removed once, here.
    private static func trimmed(_ path: String) -> String {
        var out = path
        while out.count > 1, out.hasSuffix("/") { out.removeLast() }
        return out
    }
}
