import Foundation

struct GitBranch: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let upstream: String?
    let worktreePath: String?
    let isHead: Bool
    let isRemote: Bool
    /// Remote name only (e.g. "origin"), so the sidebar can show a short
    /// `= origin` marker instead of the full `origin/social/...` path.
    let remoteName: String?
    /// Raw `%(upstream:track)` output (e.g. "[gone]", "[ahead 1]"). Kept as a
    /// String so it stays Codable-friendly for cached payloads.
    let upstreamTrack: String?

    init(
        name: String,
        upstream: String? = nil,
        worktreePath: String? = nil,
        isHead: Bool = false,
        isRemote: Bool = false,
        remoteName: String? = nil,
        upstreamTrack: String? = nil
    ) {
        self.name = name
        self.upstream = upstream
        self.worktreePath = worktreePath
        self.isHead = isHead
        self.isRemote = isRemote
        self.remoteName = remoteName
        self.upstreamTrack = upstreamTrack
    }

    /// True when the branch tracks an upstream that no longer exists on the
    /// remote — git reports this as "[gone]" in `%(upstream:track)`.
    var upstreamGone: Bool {
        upstreamTrack?.contains("gone") ?? false
    }

    /// Commits the upstream has and this branch doesn't, as of the last
    /// fetch — the `behind N` in `%(upstream:track,nobracket)`. Zero when the
    /// branch is level, only ahead, or tracks nothing.
    var behindCount: Int { trackCount("behind") }

    /// Commits this branch has and its upstream doesn't — the `ahead N`.
    var aheadCount: Int { trackCount("ahead") }

    /// The number after `label` in "ahead 1, behind 2".
    private func trackCount(_ label: String) -> Int {
        guard let track = upstreamTrack else { return 0 }
        for part in track.split(separator: ",") {
            let words = part.split(separator: " ")
            if words.count == 2, words[0] == label, let n = Int(words[1]) { return n }
        }
        return 0
    }

    /// Short remote label for the sidebar. Prefers git's `:remotename`, and
    /// falls back to the first path segment of the upstream ref.
    var upstreamRemote: String? {
        if let remoteName, !remoteName.isEmpty { return remoteName }
        return upstream?.split(separator: "/").first.map(String.init)
    }

    /// Splits a remote branch's short name — "origin/feature/x" — into the
    /// remote it is on and the branch it is there.
    ///
    /// Matched against the remotes this repository actually has, longest
    /// first, rather than cut at the first slash. Both halves may contain
    /// one: `origin/feature/x` is ("origin", "feature/x"), and a remote
    /// genuinely named `origin/feature` would take precedence over `origin`
    /// for a ref that starts with it. Guessing at the slash gets one of those
    /// wrong, and the command it builds deletes a branch nobody named.
    ///
    /// Nil for a local branch, or a remote one whose remote is not
    /// configured here.
    func remoteRef(knownRemotes: [String]) -> (remote: String, branch: String)? {
        guard isRemote else { return nil }
        for remote in knownRemotes.sorted(by: { $0.count > $1.count })
        where name.hasPrefix(remote + "/") {
            let branch = String(name.dropFirst(remote.count + 1))
            return branch.isEmpty ? nil : (remote, branch)
        }
        return nil
    }

    /// Folder segments derived from "/" separated branch names.
    var pathComponents: [String] {
        name.split(separator: "/").map(String.init)
    }

    var leafName: String {
        pathComponents.last ?? name
    }
}

/// Where the current branch stands against its upstream, in the direction
/// nothing else in the app measures: what the remote has and HEAD does not.
///
/// A branch that has been squashed or rebased is ahead *and* behind — the
/// commits it replaced are still on the remote until a force push — and that
/// is the state the Journal has to be able to draw.
struct UpstreamGap: Equatable, Sendable {
    /// Short ref name, as `git log` will take it: "origin/main".
    let ref: String
    /// Commits reachable from the upstream but not from HEAD.
    let incoming: Set<String>

    /// Nothing to draw: the upstream is an ancestor of HEAD, so the branch is
    /// either in sync or simply ahead.
    var isEmpty: Bool { incoming.isEmpty }
}

struct GitTag: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let targetHash: String?
    let date: Date?
}

struct GitStash: Codable, Identifiable, Hashable, Sendable {
    var id: Int { index }
    let index: Int
    let message: String
    let branch: String?
    let date: Date?
}

/// One file recorded in a stash entry, and the revision inside the entry
/// that holds it.
///
/// The revision is not the same for every row: a `git stash push
/// --include-untracked` keeps the tracked changes in `stash@{N}` and the
/// untracked files it swept up in a third parent, `stash@{N}^3`. Anything
/// asking git about one file — a per-file diff, a compare window — needs
/// the right one of the two.
struct StashFile: Identifiable, Hashable, Sendable {
    let status: GitFileStatus
    let revision: String

    var id: String { "\(revision):\(status.path)" }
    var path: String { status.path }
    var name: String { status.name }

    /// True for a file that was untracked when the stash was made — it
    /// lives in the entry's untracked parent rather than in the entry.
    var wasUntracked: Bool { revision.hasSuffix("^3") }
}
