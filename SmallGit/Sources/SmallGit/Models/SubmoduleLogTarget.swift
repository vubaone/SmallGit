import Foundation

/// Which submodule the Submodule window is looking at.
///
/// A parent path and a repo-relative path rather than one absolute path,
/// because the window shows both: the submodule's history, and what the
/// repository that owns it records. Identity is the pair, so pointing the
/// window at a different submodule rebuilds its session while pointing it
/// at the same one again only reloads.
struct SubmoduleLogTarget: Identifiable, Hashable, Sendable {
    let parentPath: String
    let path: String

    var id: String { (parentPath as NSString).appendingPathComponent(path) }
}
