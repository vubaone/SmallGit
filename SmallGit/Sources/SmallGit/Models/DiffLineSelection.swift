import Foundation

/// The diff rows the user has highlighted, and the text they add up to.
///
/// Four views need the same three click gestures over a list of diff lines:
/// the main Diff panel, which also stages from the selection, and the
/// read-only compare windows, which only ever copy from it. Keeping the
/// rules in one value type is what makes shift-click behave identically in
/// all of them, and is where "what would Copy put on the pasteboard" gets
/// answered once.
///
/// Copying is the reason the read-only views have a selection at all.
/// SwiftUI scopes text selection to a single `Text`, and a diff row is one
/// `Text` — so a drag can never run across rows, and without this there is
/// no way to get more than one line out of a compare window.
struct DiffLineSelection: Equatable, Sendable {
    private(set) var ids: Set<UUID> = []
    /// The row a shift-click extends from. Nil until something is clicked.
    private(set) var anchorID: UUID?

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    func contains(_ line: DiffLine) -> Bool { ids.contains(line.id) }

    mutating func clear() {
        ids.removeAll()
        anchorID = nil
    }

    /// Plain click: one row, and the anchor a later shift-click grows from.
    ///
    /// Pad rows are refused throughout. They stand for a line the other side
    /// doesn't have, so there is nothing under them to select, stage or copy.
    mutating func selectOnly(_ line: DiffLine) {
        guard line.type != .empty else { return }
        ids = [line.id]
        anchorID = line.id
    }

    /// ⌘-click: take one row in or out, and re-anchor on it.
    mutating func toggle(_ line: DiffLine) {
        guard line.type != .empty else { return }
        if ids.contains(line.id) {
            ids.remove(line.id)
        } else {
            ids.insert(line.id)
        }
        anchorID = line.id
    }

    /// ⇧-click: everything between the anchor and `line`, in the order
    /// `lines` gives. With no anchor yet there is no range to describe, so
    /// this falls back to selecting the clicked row alone.
    mutating func extend(to line: DiffLine, within lines: [DiffLine]) {
        guard line.type != .empty else { return }
        guard let anchorID,
              let a = lines.firstIndex(where: { $0.id == anchorID }),
              let b = lines.firstIndex(where: { $0.id == line.id })
        else {
            selectOnly(line)
            return
        }
        ids = Set(lines[min(a, b)...max(a, b)].map(\.id))
    }

    /// A drag: exactly these rows, whatever was selected before. The anchor
    /// follows the first of them, so a shift-click after a drag extends from
    /// where the drag began.
    mutating func select(_ lines: [DiffLine]) {
        let usable = lines.filter { $0.type != .empty }
        ids = Set(usable.map(\.id))
        anchorID = usable.first?.id
    }

    /// The selected rows' text, in the order `lines` draws them.
    ///
    /// Content only: no `+`/`-` marker and no line number. What leaves a
    /// diff this way is nearly always on its way into an editor, where a
    /// column of markers is something to strip back off by hand.
    func text(of lines: [DiffLine]) -> String {
        lines.filter { ids.contains($0.id) }
            .map(\.content)
            .joined(separator: "\n")
    }
}
