import Foundation

/// One entry from `git submodule status`, joined with its `.gitmodules` record.
///
/// A submodule is two things at once, and keeping that straight is what makes
/// the difference between a usable submodule UI and a confusing one. There is
/// the *pointer* — a gitlink the parent repository stores, which can be staged
/// and committed like any other change — and there is the *repository* sitting
/// at `path`, with its own branches and history. This model carries the
/// pointer's state; opening the repository is a separate act.
struct GitSubmodule: Codable, Identifiable, Hashable, Sendable {
    /// Repo-relative path. The identity: `.gitmodules` allows a name that
    /// differs from the path, but the path is what git keys the gitlink on and
    /// what the user sees in the tree.
    var id: String { path }

    let path: String
    /// Name from `.gitmodules`. Usually the same as `path`, and falls back to
    /// it when the submodule is present in the index but absent from
    /// `.gitmodules` — which happens to a half-removed submodule.
    let name: String
    /// Clone URL from `.gitmodules`, `nil` when there is no record for it.
    let url: String?
    /// Commit the parent repository points at.
    let sha: String
    /// What `git describe` made of that commit, when git offered it —
    /// `v1.2-3-gabc1234` or `heads/main`. Nil for an uninitialised submodule,
    /// since there is no clone to describe it from.
    let describe: String?
    let state: State

    /// Leading marker of a `git submodule status` line.
    enum State: String, Codable, Sendable {
        /// Cloned and sitting on exactly the commit the parent records.
        case current
        /// Not initialised — the directory is empty and nothing is cloned yet.
        case uninitialized
        /// Cloned, but checked out at a different commit than the parent
        /// records. Committing the parent now would move the pointer.
        case modified
        /// Merge conflict on the gitlink itself: two branches moved the
        /// submodule to different commits.
        case conflicted

        var label: String {
            switch self {
            case .current:       return "up to date"
            case .uninitialized: return "not initialized"
            case .modified:      return "moved"
            case .conflicted:    return "conflicted"
            }
        }
    }

    var shortSHA: String { String(sha.prefix(7)) }

    /// Absolute path of the submodule's working tree, for opening it as a
    /// repository of its own.
    func absolutePath(in repoPath: String) -> String {
        (repoPath as NSString).appendingPathComponent(path)
    }

    /// Whether there is a working tree to open. An uninitialised submodule is
    /// an empty directory — opening it would add a broken repository entry.
    var isCloned: Bool { state != .uninitialized }
}
