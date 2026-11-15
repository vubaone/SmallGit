import Foundation

/// A single entry in HEAD's reflog. The list is ordered newest-first
/// (matching `git reflog show` default order). The selector `HEAD@{N}`
/// is git's stable way to refer to "where HEAD was N moves ago" — N
/// matches `index` here.
struct GitReflogEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String { selector }
    /// Sequence in the reflog. 0 is the most recent move; higher numbers
    /// are older. Used to render `HEAD@{N}` and to feed `git reset HEAD@{N}`.
    let index: Int
    /// Full reflog selector, e.g. `HEAD@{0}`. Stored verbatim so we
    /// don't have to rebuild it for downstream git invocations.
    let selector: String
    let hash: String
    let shortHash: String
    /// The raw reflog subject from `%gs`: `"commit: <msg>"`,
    /// `"checkout: moving from main to feature"`, `"reset: moving to HEAD~3"`,
    /// etc. The action category is parsed out into `action` for filtering.
    let subject: String
    let action: ReflogAction
    let date: Date?

    /// Pulls the part after the first `:` (if any) — the human message
    /// that follows the action keyword. Falls back to the full subject.
    var message: String {
        if let colon = subject.firstIndex(of: ":") {
            return subject[subject.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return subject
    }
}

/// What "Undo Last Operation" should do for a given reflog entry.
/// Derived, not stored — see `GitReflogEntry.undoPlan`.
enum UndoPlan: Equatable, Sendable {
    /// `git reset --keep <ref>`: rewind the current branch (and working
    /// tree) but refuse to overwrite uncommitted local changes.
    case resetKeep(ref: String)
    /// The last move was a checkout — undoing means checking the
    /// previous ref back out, *not* resetting the current branch.
    case checkout(ref: String)
    /// We can't safely determine an inverse (branch creation, unknown
    /// verbs, unparseable checkout subjects).
    case unsupported
}

extension GitReflogEntry {

    /// The safe inverse of this reflog entry, used by the one-click Undo:
    ///
    /// - Single-commit ops (commit / amend / cherry-pick / revert) rewind
    ///   one reflog step: `reset --keep HEAD@{1}`.
    /// - Multi-step ops (merge / rebase / pull) and resets go back to
    ///   `ORIG_HEAD` — git's own "where HEAD was before the dangerous
    ///   operation" marker, which spans all of a rebase's intermediate
    ///   reflog entries. Stepping to `HEAD@{1}` would only unwind the
    ///   last pick.
    /// - Checkouts are position changes, not history changes: undo by
    ///   checking the previous ref back out.
    var undoPlan: UndoPlan {
        switch action {
        case .commit, .amend, .cherryPick, .revert:
            return .resetKeep(ref: "HEAD@{1}")
        case .merge, .rebase, .reset, .pull:
            return .resetKeep(ref: "ORIG_HEAD")
        case .checkout:
            if let from = checkoutSource { return .checkout(ref: from) }
            return .unsupported
        case .branch, .clone, .other:
            return .unsupported
        }
    }

    /// The `<from>` in a checkout subject's "moving from <from> to <to>".
    /// Splits on the *last* " to " so branch names containing " to "
    /// resolve as git wrote them.
    var checkoutSource: String? {
        let prefix = "moving from "
        let msg = message
        guard msg.hasPrefix(prefix) else { return nil }
        let rest = msg.dropFirst(prefix.count)
        guard let sep = rest.range(of: " to ", options: .backwards),
              sep.lowerBound > rest.startIndex else { return nil }
        return String(rest[..<sep.lowerBound])
    }
}

/// The first word of a reflog subject tells you what git did. We bucket
/// it for icon / colour selection in the UI; unknown verbs fall through
/// to `.other` and still surface their full subject text.
enum ReflogAction: String, Codable, Hashable, Sendable {
    case commit
    case amend
    case checkout
    case reset
    case merge
    case rebase
    case cherryPick
    case revert
    case pull
    case clone
    case branch
    case other

    init(subject: String) {
        let lower = subject.lowercased()
        // Match longest first so "commit (amend)" maps to .amend.
        if lower.hasPrefix("commit (amend)")              { self = .amend; return }
        if lower.hasPrefix("commit (initial)")            { self = .commit; return }
        if lower.hasPrefix("commit (merge)")              { self = .merge; return }
        if lower.hasPrefix("commit")                      { self = .commit; return }
        if lower.hasPrefix("checkout")                    { self = .checkout; return }
        if lower.hasPrefix("reset")                       { self = .reset; return }
        if lower.hasPrefix("merge")                       { self = .merge; return }
        if lower.hasPrefix("rebase")                      { self = .rebase; return }
        if lower.hasPrefix("cherry-pick")                 { self = .cherryPick; return }
        if lower.hasPrefix("revert")                      { self = .revert; return }
        if lower.hasPrefix("pull")                        { self = .pull; return }
        if lower.hasPrefix("clone")                       { self = .clone; return }
        if lower.hasPrefix("branch")                      { self = .branch; return }
        self = .other
    }

    var symbolName: String {
        switch self {
        case .commit:     return "checkmark.circle"
        case .amend:      return "pencil.circle"
        case .checkout:   return "arrow.triangle.branch"
        case .reset:      return "arrow.uturn.backward.circle"
        case .merge:      return "arrow.triangle.merge"
        case .rebase:     return "arrow.triangle.swap"
        case .cherryPick: return "leaf"
        case .revert:     return "arrow.counterclockwise.circle"
        case .pull:       return "arrow.down.to.line"
        case .clone:      return "doc.on.doc"
        case .branch:     return "arrow.triangle.branch"
        case .other:      return "ellipsis.circle"
        }
    }

    var displayName: String {
        switch self {
        case .commit:     return "Commit"
        case .amend:      return "Amend"
        case .checkout:   return "Checkout"
        case .reset:      return "Reset"
        case .merge:      return "Merge"
        case .rebase:     return "Rebase"
        case .cherryPick: return "Cherry-pick"
        case .revert:     return "Revert"
        case .pull:       return "Pull"
        case .clone:      return "Clone"
        case .branch:     return "Branch"
        case .other:      return "Other"
        }
    }
}
