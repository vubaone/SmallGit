import Foundation

/// Identifies one piece of cacheable data within a repository.
///
/// Per-repo keys (most cases) carry no repo path — the repo is implicit
/// via `CacheCoordinator.activeRepoPath`. Cross-repo keys carry their path.
///
/// Tip: the log's key carries `JournalRefSelection.cacheToken` — the
/// sentinel `__current__` for the default HEAD view (stable across
/// checkouts), a hash of the refs for any wider selection.
enum CacheKey: Hashable, Codable, Sendable {
    case fileStatus
    /// Every tracked path in the repo (`git ls-files`), which the Files
    /// filter searches on top of the changed set.
    case trackedFiles
    /// Paths the index has flagged `assume-unchanged` (`git ls-files -v`).
    /// Its own key rather than part of `.fileStatus` because `git status`
    /// cannot see these at all — it's a second read, and one the Files
    /// panel only pays for when asked to show them.
    case assumeUnchangedFiles
    case currentBranch
    case branchList
    case remoteBranches
    case tagList
    case stashList
    /// `refs` identifies which ref selection this log is for — see
    /// `JournalRefSelection.cacheToken`. Two selections must never share
    /// an entry: the commit lists are different histories.
    case log(refs: String)
    /// `compact` distinguishes the default short diff (limited context)
    /// from the full-file view (`--unified=<all>`) so the two don't share
    /// a cache entry.
    case diff(file: String, mode: DiffCompareMode, compact: Bool)

    case repoValidation(path: String)

    /// Sentinel value used when caching the log of the currently checked-out
    /// branch (regardless of which branch that is).
    static let currentBranchSentinel = "__current__"

    /// Filename prefix shared by every cached log, whatever ref selection it
    /// holds. The disk cache retires logs by prefix for the same reason
    /// `MemoryCache.invalidateLogs` retires them by `isLog`: the hashed
    /// selection in a log key cannot be reconstructed from the ref that moved.
    static let logDiskFilePrefix = "log_"

    /// `true` for a commit-log entry, whichever ref selection it holds.
    var isLog: Bool {
        if case .log = self { return true }
        return false
    }

    /// Stable filename used by the disk cache.
    var diskFileName: String {
        switch self {
        case .fileStatus:                       return "file_status.json"
        case .trackedFiles:                     return "tracked_files.json"
        case .assumeUnchangedFiles:             return "assume_unchanged_files.json"
        case .currentBranch:                    return "current_branch.json"
        case .branchList:                       return "branch_list.json"
        case .remoteBranches:                   return "remote_branches.json"
        case .tagList:                          return "tag_list.json"
        case .stashList:                        return "stash_list.json"
        case .log(let refs):
            return "\(Self.logDiskFilePrefix)\(refs.safeFileName).json"
        case .diff(let file, let mode, let compact):
            return "diff_\(mode.rawValue)_\(compact ? "c" : "full")_\(file.safeFileName).json"
        case .repoValidation(let path):         return "repo_\(path.stableHash).json"
        }
    }
}
