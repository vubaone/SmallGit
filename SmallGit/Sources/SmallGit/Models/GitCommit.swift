import Foundation

struct GitCommit: Codable, Identifiable, Hashable, Sendable {
    var id: String { hash }
    let hash: String
    let shortHash: String
    let subject: String
    let authorName: String
    let authorEmail: String
    let date: Date
    let refs: String
    /// Parent commit SHAs, in declaration order — first parent is the
    /// continuation of the same lane, additional parents are merge
    /// sources. Empty for the initial commit of the repository.
    let parentHashes: [String]

    init(
        hash: String,
        shortHash: String,
        subject: String,
        authorName: String,
        authorEmail: String,
        date: Date,
        refs: String,
        parentHashes: [String] = []
    ) {
        self.hash = hash
        self.shortHash = shortHash
        self.subject = subject
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.date = date
        self.refs = refs
        self.parentHashes = parentHashes
    }

    // Tolerant Codable so cached log entries from before parentHashes
    // existed (Sprint 4 disk cache) still decode without re-fetching.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hash         = try c.decode(String.self, forKey: .hash)
        self.shortHash    = try c.decode(String.self, forKey: .shortHash)
        self.subject      = try c.decode(String.self, forKey: .subject)
        self.authorName   = try c.decode(String.self, forKey: .authorName)
        self.authorEmail  = try c.decode(String.self, forKey: .authorEmail)
        self.date         = try c.decode(Date.self,   forKey: .date)
        self.refs         = try c.decode(String.self, forKey: .refs)
        self.parentHashes = try c.decodeIfPresent([String].self, forKey: .parentHashes) ?? []
    }

    var refList: [String] {
        refs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The commit the working tree is checked out at — `HEAD -> branch`
    /// normally, a bare `HEAD` when detached.
    ///
    /// Matched against the decorations one at a time rather than searching
    /// the whole string: a repository with a default remote branch carries
    /// `origin/HEAD` on whatever that points at, and a substring test reads
    /// that row as the checkout.
    var isHead: Bool {
        refList.contains { $0 == "HEAD" || $0.hasPrefix("HEAD ->") }
    }

    var isMerge: Bool { parentHashes.count > 1 }

    /// The best name to put on screen for this commit, or nil when it carries
    /// no branch at all and the short hash is all there is.
    ///
    /// Worth the trouble where a hash would be true but unhelpful: "rebase
    /// onto 4618fa2" says far less about what is about to happen than "rebase
    /// onto social/ZSOC-1318-emoji", and the hash is still what gets handed to
    /// git — only the label changes.
    ///
    /// `knownLocal` is the repository's local branch names, because git lists
    /// decorations remote-first (`origin/social/x` comes before `social/x`)
    /// and the local branch is the one the user is thinking in. Tags are
    /// skipped: a tag names a point in history, not the line of work being
    /// rebased onto.
    func branchLabel(knownLocal: Set<String>) -> String? {
        let candidates = refList.compactMap { ref -> String? in
            if ref == "HEAD" { return nil }
            if ref.hasPrefix("tag: ") { return nil }
            if let arrow = ref.range(of: "HEAD -> ") { return String(ref[arrow.upperBound...]) }
            return ref
        }
        return candidates.first { knownLocal.contains($0) } ?? candidates.first
    }
}
