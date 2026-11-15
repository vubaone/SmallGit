import Foundation

/// The effective destinations Git uses for a remote, including URL rewrites
/// and the fetch URL fallback when no separate push URL is configured.
struct GitRemote: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let fetchURLs: [String]
    let pushURLs: [String]
}
