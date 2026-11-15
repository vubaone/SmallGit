import Foundation

/// What the hover arrow in the Changes panel's side-by-side layout does to
/// the row under the pointer.
///
/// One meaning, pointing one way: copy the left pane's version of this line
/// over the right pane's — Beyond Compare's "Copy to Right", which is to say
/// revert the line. What that costs depends on which two trees are being
/// compared, and the two cases are not equally recoverable: unstaging puts a
/// line back where the working file still holds it, while discarding throws
/// away the only copy of an edit that was never committed.
enum DiffRowRevert: Equatable, Sendable {

    /// HEAD ↔ Index: copy HEAD's line over the index — unstage it. The
    /// working file keeps the change.
    case unstage

    /// Index ↔ Working: copy the index's line over the working tree —
    /// discard the edit. Nothing else holds it.
    case discard

    /// The arrow points right in both cases, because both cases are the same
    /// sentence: the left pane wins. It is the panel's one direction — the
    /// right pane is downstream of the left in either compare mode.
    static let symbol = "arrow.right.circle.fill"

    /// The revert a diff of `source` offers, or nil where a line cannot be
    /// reverted at all — an untracked file (nothing in the index to apply
    /// against), a conflict, a stash, a commit, a submodule.
    ///
    /// Reads the mode rather than `source.staged` so a third compare mode,
    /// if one ever arrives, has to say here what its arrow means instead of
    /// silently inheriting the more destructive of the two.
    init?(source: DiffSource) {
        guard case .fileChanges(_, let mode) = source else { return nil }
        switch mode {
        case .headVsIndex:        self = .unstage
        case .indexVsWorkingTree: self = .discard
        }
    }

    /// Names both panes and the consequence. "Copy to the right" alone would
    /// leave the discard looking as cheap as the unstage, and only one of
    /// them can be undone by clicking the other way.
    var help: String {
        switch self {
        case .unstage: return "Copy this line from HEAD over Index — unstages it"
        case .discard: return "Copy this line from Index over Working — discards the change"
        }
    }

    /// The lines one side-by-side row's arrow acts on.
    ///
    /// A row is a pair, and a modification is both halves of one: reverting
    /// it has to take the `+` away *and* put the `-` back, or the line ends
    /// up neither version. A pure add or delete has one actionable half and
    /// an `empty` pad opposite it; an unchanged row has none, which is what
    /// keeps the arrow off it.
    static func targetLines(left: DiffLine, right: DiffLine) -> [DiffLine] {
        [left, right].filter { $0.type == .add || $0.type == .del }
    }
}
