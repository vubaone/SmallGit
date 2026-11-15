import Foundation
import SwiftUI

enum GitFileState: String, Codable, Sendable {
    case modified = "Mod"
    case added = "Add"
    case deleted = "Del"
    case renamed = "Ren"
    case copied = "Cop"
    case untracked = "New"
    case ignored = "Ign"
    case conflict = "Cnf"
    case typeChange = "Typ"
    case unmodified = "—"

    /// Full-word label for the State column. The short `rawValue` is
    /// kept for on-disk Codable compatibility.
    var label: String {
        switch self {
        case .modified:   return "Modified"
        case .added:      return "Added"
        case .deleted:    return "Deleted"
        case .renamed:    return "Renamed"
        case .copied:     return "Copied"
        case .untracked:  return "Untracked"
        case .ignored:    return "Ignored"
        case .conflict:   return "Conflict"
        case .typeChange: return "Type"
        case .unmodified: return "Unchanged"
        }
    }
}

/// Which side of a merge did what, for a path git reports as unmerged.
///
/// `git status --porcelain=v2` carries this in the `XY` of a `u` record,
/// and it is the whole difference between "two edits to reconcile" and
/// "one side deleted this". The second kind has no content to merge, no
/// `--ours`/`--theirs` blob to check out, and only one sensible pair of
/// answers: keep the file, or finish the delete. Spelled the way git's
/// own long status spells it.
enum ConflictKind: String, Codable, Sendable {
    case bothModified   // UU — stages 1, 2, 3
    case bothAdded      // AA — stages 2, 3 (no ancestor)
    case bothDeleted    // DD — stage 1 only
    case addedByUs      // AU — stage 2 only
    case addedByThem    // UA — stage 3 only
    case deletedByUs    // DU — stages 1, 3
    case deletedByThem  // UD — stages 1, 2

    init?(xy: String) {
        switch xy {
        case "UU": self = .bothModified
        case "AA": self = .bothAdded
        case "DD": self = .bothDeleted
        case "AU": self = .addedByUs
        case "UA": self = .addedByThem
        case "DU": self = .deletedByUs
        case "UD": self = .deletedByThem
        default:   return nil
        }
    }

    /// Reconstructs the kind from which index stages a path actually
    /// has, for callers that read the stages themselves rather than
    /// going back through `git status`. Nil when none of the three is
    /// present, which is not a conflict at all.
    init?(hasBase: Bool, hasOurs: Bool, hasTheirs: Bool) {
        switch (hasBase, hasOurs, hasTheirs) {
        case (_, false, false) where !hasBase: return nil
        case (_, true, true):  self = hasBase ? .bothModified : .bothAdded
        case (_, false, true): self = hasBase ? .deletedByUs : .addedByThem
        case (_, true, false): self = hasBase ? .deletedByThem : .addedByUs
        default:               self = .bothDeleted
        }
    }

    /// How the Files table's State column names it. "Conflict" stays the
    /// word for the ordinary content clash — that is what the column has
    /// always said, and the row is already orange and filed under the
    /// conflict header. The others earn their longer names by saying the
    /// one thing the user cannot otherwise see.
    var label: String {
        switch self {
        case .bothModified:  return "Conflict"
        case .bothAdded:     return "Both added"
        case .bothDeleted:   return "Both deleted"
        case .addedByUs:     return "Added by us"
        case .addedByThem:   return "Added by them"
        case .deletedByUs:   return "Deleted by us"
        case .deletedByThem: return "Deleted by them"
        }
    }

    /// Whether the current branch still has a version of the file —
    /// index stage 2. False means `git checkout --ours` has nothing to
    /// write and "take ours" means finishing the deletion.
    var hasOurs: Bool {
        switch self {
        case .bothModified, .bothAdded, .addedByUs, .deletedByThem: return true
        case .bothDeleted, .addedByThem, .deletedByUs:              return false
        }
    }

    /// Whether the incoming branch still has a version — index stage 3.
    var hasTheirs: Bool {
        switch self {
        case .bothModified, .bothAdded, .addedByThem, .deletedByUs: return true
        case .bothDeleted, .addedByUs, .deletedByThem:              return false
        }
    }

    /// True when one side deleted the path and the other did not: there
    /// is nothing to merge line-by-line, so the resolver and the action
    /// banner both have to offer a keep/delete choice instead.
    var isDeleteConflict: Bool { !hasOurs || !hasTheirs }
}

/// What `git status --porcelain=v2` says about a submodule in its `<sub>`
/// field — the one piece of a status record that has nothing to do with
/// ordinary files.
///
/// A submodule is two things at once, and `XY` alone cannot tell them
/// apart: a moved pointer and a dirty checkout both arrive as `.M`. The
/// difference is the whole difference between "commit this and the parent
/// records a new version" and "you have work inside that is not committed
/// anywhere yet", so it is worth carrying.
struct SubmoduleFileState: Codable, Hashable, Sendable {
    /// The submodule is checked out at a different commit than the parent
    /// records — `C` in `S<c><m><u>`.
    let commitChanged: Bool
    /// Tracked files are modified inside it — `M`.
    let modifiedContent: Bool
    /// It has untracked files inside it — `U`.
    let untrackedContent: Bool

    /// Parses the `<sub>` field. `N...` — the ordinary case — is not a
    /// submodule at all and gives nil.
    init?(field: String) {
        guard field.count == 4, field.hasPrefix("S") else { return nil }
        let flags = Array(field)
        self.commitChanged    = flags[1] == "C"
        self.modifiedContent  = flags[2] == "M"
        self.untrackedContent = flags[3] == "U"
    }

    /// How the Files table's State column describes it, which has to be
    /// more specific than "Modified" or the two cases read alike.
    var label: String {
        if commitChanged { return "Submodule moved" }
        if modifiedContent || untrackedContent { return "Submodule dirty" }
        return "Submodule"
    }
}

struct GitFileStatus: Codable, Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    /// Index-side status letter (X in `XY` of porcelain v2).
    let indexStatus: String
    /// Worktree-side status letter (Y in `XY`).
    let workTreeStatus: String
    let isConflict: Bool
    /// Original path when renamed/copied.
    let originalPath: String?
    /// `true` when this path's index entry carries the `assume-unchanged`
    /// bit.
    ///
    /// Never set from `git status`, which is the whole problem with the
    /// flag: it tells git to stop stat-ing the file, so an edit to a
    /// flagged path produces no status entry at all. It arrives instead
    /// from `git ls-files -v` and is stitched onto the row by
    /// `FilesViewModel` when the Files panel is asked to show these.
    let isAssumeUnchanged: Bool
    /// Non-nil when this row is a submodule, saying which of the three
    /// things a submodule can have going on are true. Nil for every
    /// ordinary file.
    let submodule: SubmoduleFileState?

    init(
        path: String,
        indexStatus: String,
        workTreeStatus: String,
        isConflict: Bool = false,
        originalPath: String? = nil,
        isAssumeUnchanged: Bool = false,
        submodule: SubmoduleFileState? = nil
    ) {
        self.path = path
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        self.isConflict = isConflict
        self.originalPath = originalPath
        self.isAssumeUnchanged = isAssumeUnchanged
        self.submodule = submodule
    }

    /// Cached rows written before submodules were parsed have no key for
    /// it, and a strict decode would throw the whole file status away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path              = try c.decode(String.self, forKey: .path)
        self.indexStatus       = try c.decode(String.self, forKey: .indexStatus)
        self.workTreeStatus    = try c.decode(String.self, forKey: .workTreeStatus)
        self.isConflict        = try c.decodeIfPresent(Bool.self, forKey: .isConflict) ?? false
        self.originalPath      = try c.decodeIfPresent(String.self, forKey: .originalPath)
        self.isAssumeUnchanged = try c.decodeIfPresent(Bool.self, forKey: .isAssumeUnchanged) ?? false
        self.submodule         = try c.decodeIfPresent(SubmoduleFileState.self, forKey: .submodule)
    }

    var isSubmodule: Bool { submodule != nil }

    /// What kind of unmerged path this is, read back out of the `XY`
    /// letters git gave us. Nil for everything that is not conflicted —
    /// and for a conflicted row restored from a cache written before
    /// these letters were kept, which decodes as `UU`.
    var conflictKind: ConflictKind? {
        guard isConflict else { return nil }
        return ConflictKind(xy: indexStatus + workTreeStatus)
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    var relativeDirectory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "." : dir
    }

    /// Basename of the pre-rename path, shown after the new name in the
    /// Files table ("B.swift ← A.swift") so a rename / copy reads as one
    /// move the way SmartGit presents it. `nil` for everything else.
    var renameOrigin: String? {
        guard state == .renamed || state == .copied, let originalPath else { return nil }
        return (originalPath as NSString).lastPathComponent
    }

    /// Paths a stage / unstage must touch together. A rename is two index
    /// operations — drop the old path, add the new one — so both have to
    /// move as a unit or the pair splits back into a separate delete +
    /// add. A copy leaves its source untouched, so it stages alone.
    var affectedPaths: [String] {
        if state == .renamed, let originalPath {
            return [path, originalPath]
        }
        return [path]
    }

    var isStaged: Bool {
        indexStatus != "." && indexStatus != "?" && indexStatus != " " && !indexStatus.isEmpty
    }

    var isUnstaged: Bool {
        workTreeStatus != "." && workTreeStatus != " " && !workTreeStatus.isEmpty
    }

    /// Whether the commit dialog can put this row in a commit.
    ///
    /// An ignored file is not one of them, and needs saying out loud: git
    /// reports it with `!` in the index column, which `isStaged` — reading
    /// "anything but `.`, `?` or blank" — cannot tell from a real index
    /// entry. Left to itself the dialog lists an ignored path under Staged
    /// Changes, and anything that then unticks it tries to unstage a path
    /// that was never in the index.
    var isCommittable: Bool {
        (isStaged || isUnstaged) && state != .ignored
    }

    /// Whether git has no index entry for this path at all — untracked or
    /// ignored. Every command that works through the index refuses such a
    /// path rather than ignoring it: `git rm` reports "did not match any
    /// files" and fails the whole invocation, `git update-index` has no
    /// entry to flag. Deleting one from disk is `git clean`'s job.
    var hasNoIndexEntry: Bool {
        state == .untracked || state == .ignored
    }

    var state: GitFileState {
        if isConflict { return .conflict }
        let primary = isStaged ? indexStatus : workTreeStatus
        switch primary {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChange
        case "?": return .untracked
        case "!": return .ignored
        default: return .unmodified
        }
    }

    /// What to render in the State column. Adds an explicit
    /// "Staged"/"Staged + …" distinction on top of `state`, matching
    /// SmartGit's behavior — without it, a freshly-staged Modified
    /// file looks identical to its unstaged version.
    var stateDisplay: String {
        if isConflict { return conflictKind?.label ?? "Conflict" }
        if state == .untracked { return "Untracked" }
        if state == .ignored { return "Ignored" }
        // A flagged file with staged content still reads "Staged" — that
        // is the fact about it that matters. It's the otherwise-quiet one
        // that needs naming: the row is on screen *because* of the flag,
        // and "Unchanged" would be the one thing it might not be.
        if isAssumeUnchanged, state == .unmodified { return "Assume unchanged" }
        // A submodule's own words. "Modified" is true of both a moved
        // pointer and a dirty checkout, and they call for opposite things:
        // one is ready to commit here, the other has to be committed in
        // there first.
        if let submodule { return submodule.label }
        let label = state.label
        switch (isStaged, isUnstaged) {
        case (true, true):  return "Staged + \(label)"   // staged then re-edited
        case (true, false): return "Staged"
        default:            return label
        }
    }
}
