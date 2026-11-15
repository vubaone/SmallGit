import Foundation

/// Which refs the journal's graph is built from — the checkbox state of
/// SmartGit's Branches view, where ticking a branch adds its commits to
/// the graph and the whole view is `git log <every checked ref>`.
///
/// The default is HEAD alone, which is `git log` with no ref argument at
/// all: the history of whatever is checked out.
struct JournalRefSelection: Codable, Hashable, Sendable {
    /// HEAD's own history. Held apart from `refs` because it follows the
    /// checkout rather than naming a branch, so it stays meaningful after
    /// switching branches.
    var head: Bool
    /// Branch and tag names exactly as git accepts them on a `log`
    /// command line: "main", "origin/social/x", "v1.0".
    var refs: Set<String>

    init(head: Bool = true, refs: Set<String> = []) {
        self.head = head
        self.refs = refs
    }

    static let headOnly = JournalRefSelection(head: true, refs: [])

    /// The default view: no ref arguments, just the current checkout.
    var isHeadOnly: Bool { head && refs.isEmpty }
    /// Nothing ticked at all — an empty journal, not "everything".
    var isEmpty: Bool { !head && refs.isEmpty }

    /// Whether HEAD's history is in the graph: HEAD ticked, or the branch
    /// that is checked out ticked by name — the same commits either way.
    func graphsHead(checkedOut branch: String?) -> Bool {
        head || branch.map(refs.contains) == true
    }

    /// Revisions to hand `git log`. Empty means "no ref argument", which
    /// git reads as HEAD.
    var revisions: [String] {
        guard !isHeadOnly else { return [] }
        var out = refs.sorted()
        if head { out.insert("HEAD", at: 0) }
        return out
    }

    /// Cache identity for this selection. Head-only keeps the historical
    /// sentinel so entries written before ref selection existed still
    /// hit; anything else is hashed, because a selection can name
    /// thousands of refs and that has to survive as a filename.
    var cacheToken: String {
        if isHeadOnly { return CacheKey.currentBranchSentinel }
        if isEmpty { return "__none__" }
        return "refs_\(revisions.joined(separator: " ").stableHash)"
    }

    func contains(_ ref: String) -> Bool { refs.contains(ref) }

    mutating func set(_ ref: String, checked: Bool) {
        if checked { refs.insert(ref) } else { refs.remove(ref) }
    }

    mutating func set<S: Sequence<String>>(_ group: S, checked: Bool) {
        if checked { refs.formUnion(group) } else { refs.subtract(group) }
    }

    /// Checkbox state for a group of refs — the tri-state box SmartGit
    /// shows on "Local Branches" and on each folder.
    func state<S: Sequence<String>>(of group: S) -> CheckState {
        var seen = false
        var all = true
        for ref in group {
            seen = true
            if !refs.contains(ref) { all = false }
        }
        guard seen else { return .off }
        if all { return .on }
        return refs.isDisjoint(with: Set(group)) ? .off : .mixed
    }

    /// Drop refs that no longer exist. A selection outlives the branches
    /// in it — someone deletes a branch, and without this the next
    /// `git log` is asked for a revision git can't resolve.
    mutating func prune(keeping known: Set<String>) {
        refs.formIntersection(known)
    }

    enum CheckState: Hashable, Sendable {
        case off, mixed, on

        var isOn: Bool { self == .on }
        /// The state a click produces: anything partial or empty fills in.
        var toggled: Bool { self != .on }

        var symbolName: String {
            switch self {
            case .off:   return "square"
            case .mixed: return "minus.square.fill"
            case .on:    return "checkmark.square.fill"
            }
        }
    }
}
