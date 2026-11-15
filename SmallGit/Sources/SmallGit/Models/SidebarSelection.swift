import Foundation

/// One selectable row in the Branches panel.
///
/// The panel lists branches, tags, stashes and submodules in a single `List`,
/// and a `List`'s selection has one type. Making that type a bare `String`
/// would mean a branch and a tag named `v1.0` are the same selection — so the
/// kind is carried alongside the name.
///
/// Every row the panel draws has a case here, including the two that carry no
/// git object of their own — HEAD and the folders branch names nest into. An
/// untagged row is a row `List` will not select, which leaves the selection
/// pointing at whatever was clicked before it: a double-click on a folder
/// would then check out an unrelated branch.
enum SidebarSelection: Hashable, Sendable {
    /// The checked-out history, which follows the checkout rather than
    /// naming a ref.
    case head
    case branch(String)
    /// A folder in either branch tree, keyed by its row id — the path down
    /// from the tree's root, e.g. `Local Branches/social`.
    case folder(String)
    case tag(String)
    /// `stash@{n}` is positional and shifts when a stash is dropped, so the
    /// index is what identifies the row while it is on screen.
    case stash(Int)
    /// Repo-relative path, which is how git keys the gitlink.
    case submodule(String)

    /// A stable order: kinds in the order the panel lists them, rows within a
    /// kind by name. A `Set` has none of its own, and a batch action has to
    /// mean the same rows — in the same sequence — every time it is invoked.
    var sortKey: String {
        switch self {
        case .head:                 "0"
        case .branch(let name):     "1\(name)"
        case .folder(let id):       "2\(id)"
        case .tag(let name):        "3\(name)"
        case .stash(let index):     "4\(String(format: "%08d", index))"
        case .submodule(let path):  "5\(path)"
        }
    }
}

extension Set<SidebarSelection> {
    var sortedForMenu: [SidebarSelection] {
        sorted { $0.sortKey < $1.sortKey }
    }
}
