import Foundation

/// Where a commit ended up: the branches whose tip descends from it and
/// the nearest tag that contains it.
///
/// This is the question a SHA on its own can't answer — has this shipped,
/// and which lines of work carry it. SmartGit prints it as the
/// "closest tags …" / "on branches …" pair above the commit's refs, and
/// it's distinct from `GitCommit.refs`: refs are what points *at* this
/// commit, containment is everything that has it in its history.
struct CommitContainment: Sendable, Equatable {
    /// Local and remote branch names, in git's ref order.
    let branches: [String]
    /// Nearest tag containing the commit, without `git describe`'s
    /// distance suffix. Nil when no tag contains it yet.
    let closestTag: String?

    static let empty = CommitContainment(branches: [], closestTag: nil)

    var isEmpty: Bool { branches.isEmpty && closestTag == nil }
}
