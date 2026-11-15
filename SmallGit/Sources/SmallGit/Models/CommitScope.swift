import Foundation

/// What the commit dialog opens on: which tab, and which files start ticked.
///
/// The index is only half the answer. Selecting rows in the Files panel and
/// then hitting Commit is a statement about what to commit — SmartGit reads
/// it that way, and a dialog that opens on the index alone throws the
/// statement away, which is exactly what "I selected four files and it
/// offered me one" feels like.
///
/// So a selection wins over the index, in the two shapes it comes in:
///
/// - **Selection reaches outside the index** — it names work that isn't
///   staged yet. Open on Local Changes with the staged set *and* the
///   selection ticked: the user is adding to what's already staged, not
///   replacing it. Nothing is dropped, so a selection that was only ever a
///   click costs the user a glance at the ticks, not a commit they didn't
///   mean.
/// - **Selection is several rows, all of them already staged** — the user
///   is carving one commit out of a larger index. Open on Staged Changes
///   with just those ticked. The rest is unticked, and the dialog's usual
///   rule applies to it: unticked staged files are unstaged before the
///   commit, so they stay in the working tree.
///
/// That second shape is the destructive one — it puts staged work back —
/// so it asks for more than a click before it believes you. A *single*
/// selected row is not a statement about the index: clicking one row is
/// how the Files panel is asked for a diff, so the commonest thing anyone
/// does in that panel would otherwise unstage the rest of their index on
/// the next ⌘K. Neither is a conflicted row, whose `U` in the index column
/// makes it look staged when what it actually needs is resolving.
///
/// With nothing selected, this is the plain index behaviour: the staged
/// set, everything ticked, falling back to Local Changes when nothing is
/// staged at all so the dialog opens on something to pick from.
struct CommitScope: Equatable, Sendable {

    /// The dialog's two tabs.
    enum Mode: Hashable, Sendable { case staged, local }

    let mode: Mode
    /// Paths that start ticked, always a subset of what `mode` shows.
    let includedPaths: Set<String>

    /// Work out the opening scope from the working-tree status and
    /// whatever the Files panel had selected.
    ///
    /// `selectedPaths` may name rows this dialog can't commit — an ignored
    /// file, or one of the unchanged tracked paths the Files filter turns
    /// up when it's used as a find-file — so it is narrowed to committable
    /// rows before any of it counts as a selection. `files` is the whole
    /// working-tree status; the same narrowing decides what the dialog
    /// lists, so what's ticked is always a subset of what's shown.
    static func opening(files: [GitFileStatus], selectedPaths: [String]) -> CommitScope {
        let committable = files.filter(\.isCommittable)
        let staged = committable.filter(\.isStaged).map(\.path)
        let selection = Set(selectedPaths)
        let selected = committable.filter { selection.contains($0.path) }

        guard !selected.isEmpty else {
            if staged.isEmpty, !committable.isEmpty {
                return CommitScope(mode: .local, includedPaths: Set(committable.map(\.path)))
            }
            return CommitScope(mode: .staged, includedPaths: Set(staged))
        }

        let carvesUpTheIndex = selected.count > 1
            && selected.allSatisfy { $0.isStaged && !$0.isConflict }
        if carvesUpTheIndex {
            return CommitScope(mode: .staged, includedPaths: Set(selected.map(\.path)))
        }

        // Everything else adds to the index rather than cutting it down.
        // A selection already inside it changes nothing, which is the point:
        // one click is allowed to mean nothing at all.
        let widened = Set(staged).union(selected.map(\.path))
        let reachesOutside = widened.count > staged.count
        return CommitScope(
            mode: reachesOutside ? .local : .staged,
            includedPaths: widened
        )
    }
}
