import Foundation

/// Pure mapping layer from filesystem events (or post-action knowledge) to
/// the precise set of cache keys to invalidate.
///
/// This is the single source of truth for "what changed → what's now stale".
enum InvalidationEngine {

    // MARK: - FSEvents

    /// Given an absolute path that changed inside `repoRoot`, return the
    /// set of cache keys that should be evicted from L1.
    ///
    /// Assumes the ordinary layout — `.git` is a directory inside the work
    /// tree. Prefer the `layout:` form, which is right for a linked worktree
    /// too; this one stays for the callers that only ever see plain repos.
    static func keysToInvalidate(changedPath: String, repoRoot: String) -> Set<CacheKey> {
        keysToInvalidate(changedPath: changedPath, layout: .assumed(workTree: repoRoot))
    }

    /// Given an absolute path that changed anywhere `layout` keeps this
    /// repository's data, return the set of cache keys now stale.
    ///
    /// Returns an empty set for paths inside the git directory that no cache
    /// depends on (e.g. `COMMIT_EDITMSG`, `config`), and for the parts of a
    /// shared common directory that belong to a *different* worktree.
    static func keysToInvalidate(changedPath: String, layout: RepoLayout) -> Set<CacheKey> {
        guard let relative = relativePath(of: changedPath, in: layout) else { return [] }

        if relative == ".git/HEAD" {
            return [.currentBranch, .log(refs: CacheKey.currentBranchSentinel)]
        }
        if relative == ".git/index" {
            // The index *is* the tracked-file list: an add or rm changes
            // which paths the Files filter can find. The assume-unchanged
            // bits live in the same file, and `git update-index` run
            // outside SmallGit is the usual way they get set.
            return [.fileStatus, .trackedFiles, .assumeUnchangedFiles]
        }
        if relative.hasPrefix(".git/refs/heads/") {
            // The log key stands in for every cached log: a journal
            // graphing several refs holds a hashed key this function
            // cannot reconstruct, and the coordinator retires them all
            // when it sees one.
            return [.branchList, .log(refs: CacheKey.currentBranchSentinel)]
        }
        if relative.hasPrefix(".git/refs/remotes/") {
            // A remote ref moving rewrites the graph's decoration as well as
            // the remote-branch list: `git log`'s `%D` bakes `origin/<branch>`
            // into the cached commit rows, so a log cached before the move
            // keeps drawing the chip on the commit the remote used to be at.
            //
            // `.branchList` too, because ahead/behind is measured against the
            // upstream: the local branch didn't move, but where it stands
            // relative to the remote did.
            return [
                .remoteBranches,
                .branchList,
                .log(refs: CacheKey.currentBranchSentinel)
            ]
        }
        if relative.hasPrefix(".git/refs/tags/") {
            // A tag is a chip in the graph as much as a row in the Tags
            // section — `%D` again.
            return [.tagList, .log(refs: CacheKey.currentBranchSentinel)]
        }
        if relative.hasPrefix(".git/refs/stash") {
            return [.stashList]
        }
        if relative == ".git/MERGE_HEAD" || relative == ".git/REBASE_HEAD" {
            return [.fileStatus]
        }
        if relative == ".git/packed-refs" {
            // Packing is where refs go to be rewritten wholesale: `git gc`,
            // `git pack-refs`, and a fetch or push on a repository whose refs
            // are already packed all move branches, remote-tracking refs and
            // tags here rather than in `refs/`. Reading it as an internal
            // detail — which it was until now — means every ref-derived cache
            // survives a move it can't see, including the `origin/<branch>`
            // chip `%D` bakes into the cached log rows.
            return [
                .branchList,
                .remoteBranches,
                .tagList,
                .log(refs: CacheKey.currentBranchSentinel)
            ]
        }
        if relative.hasPrefix(".git/") {
            // Other internal files: COMMIT_EDITMSG, config, ORIG_HEAD, and a
            // sibling checkout's `worktrees/<name>/` ...
            return []
        }

        // Working-tree file change.
        // We don't know which file specifically here without per-event paths;
        // the FileWatcher passes one path at a time, so we can invalidate the
        // diff for it as well. Working-tree edits change the index-vs-WT diff;
        // the HEAD-vs-Index view is unaffected until a stage/unstage hits.
        if !relative.isEmpty {
            return [
                .fileStatus,
                .diff(file: relative, mode: .indexVsWorkingTree, compact: true),
                .diff(file: relative, mode: .indexVsWorkingTree, compact: false)
            ]
        }
        return [.fileStatus]
    }

    /// Collapse a batch of changed paths into a deduplicated key set.
    static func keysToInvalidate(changedPaths: [String], repoRoot: String) -> Set<CacheKey> {
        keysToInvalidate(changedPaths: changedPaths, layout: .assumed(workTree: repoRoot))
    }

    static func keysToInvalidate(changedPaths: [String], layout: RepoLayout) -> Set<CacheKey> {
        var union: Set<CacheKey> = []
        for path in changedPaths {
            union.formUnion(keysToInvalidate(changedPath: path, layout: layout))
        }
        return union
    }

    // MARK: - Post-action

    /// Two rules hold over everything below, and they are the ones this file
    /// keeps getting wrong:
    ///
    /// 1. Anything that creates, deletes or moves a ref retires the log.
    ///    `git log`'s `%D` bakes the branch, remote and tag chips into the
    ///    cached commit rows, so a ref that moves leaves its chip drawn on the
    ///    commit it used to be at.
    /// 2. Anything that changes where a branch stands relative to its upstream
    ///    retires `.branchList` — including the actions that move only the
    ///    *remote* side, since ahead/behind and `[gone]` are measured, not
    ///    stored.
    ///
    /// `InvalidationInvariantTests` asserts both against every action, so an
    /// action added here without them fails a test rather than shipping as
    /// another panel that quietly shows the state before the click.
    ///
    /// Keys invalidated after a user-initiated git action with known scope.
    static func keysAfter(_ action: GitAction) -> Set<CacheKey> {
        switch action {
        case .stage(let files), .unstage(let files):
            var keys: Set<CacheKey> = [.fileStatus]
            for f in files {
                // Stage/unstage moves content between Index and Working
                // Tree, which changes every compare mode for that file.
                for mode in DiffCompareMode.allCases {
                    keys.insert(.diff(file: f, mode: mode, compact: true))
                    keys.insert(.diff(file: f, mode: mode, compact: false))
                }
            }
            return keys

        case .discard(let files):
            var keys: Set<CacheKey> = [.fileStatus]
            for f in files {
                keys.insert(.diff(file: f, mode: .indexVsWorkingTree, compact: true))
                keys.insert(.diff(file: f, mode: .indexVsWorkingTree, compact: false))
            }
            return keys

        case .commit:
            // A commit advances the branch tip, so its ahead/behind vs.
            // upstream changes — `.branchList` carries that count.
            return [
                .fileStatus,
                .log(refs: CacheKey.currentBranchSentinel),
                .branchList,
                .stashList
            ]

        case .pull:
            // A fetch is half of a pull, so it can bring tags too.
            return [
                .fileStatus,
                .log(refs: CacheKey.currentBranchSentinel),
                .branchList,
                .remoteBranches,
                .tagList
            ]

        case .push:
            // No commit changes, but its decoration does: the `origin/<branch>`
            // chip the journal draws comes from `%D` in the cached log rows,
            // and it has just moved to the commit that was pushed.
            //
            // `.branchList` is rule 2: the branch that was ahead of its
            // upstream isn't any more, and a first push gives it an upstream
            // it didn't have.
            return [
                .remoteBranches,
                .branchList,
                .log(refs: CacheKey.currentBranchSentinel)
            ]

        case .fetch:
            // Same decoration move as `.push`, and a fetch can additionally
            // bring commits the graph has never drawn — and leave the local
            // branch behind its upstream, or its upstream `[gone]`.
            return [
                .remoteBranches,
                .branchList,
                .tagList,
                .log(refs: CacheKey.currentBranchSentinel)
            ]

        case .assumeUnchanged(let files):
            // Flagging a file drops it out of `git status` and empties its
            // diff, so a cached diff for it is now a lie — the same reason
            // stage/unstage retires every compare mode for the path.
            var keys: Set<CacheKey> = [.fileStatus, .assumeUnchangedFiles]
            for f in files {
                for mode in DiffCompareMode.allCases {
                    keys.insert(.diff(file: f, mode: mode, compact: true))
                    keys.insert(.diff(file: f, mode: mode, compact: false))
                }
            }
            return keys

        case .checkout:
            // A checkout can swap in a whole different set of files, and it
            // moves which branch `%D` marks as HEAD — `.branchList` carries
            // the same `isHead` flag.
            return [
                .currentBranch,
                .fileStatus,
                .trackedFiles,
                .assumeUnchangedFiles,
                .branchList,
                .log(refs: CacheKey.currentBranchSentinel)
            ]

        case .merge:
            return [
                .fileStatus,
                .log(refs: CacheKey.currentBranchSentinel),
                .branchList
            ]

        case .rebase:
            // Rewriting history moves the branch tip, so ahead/behind vs.
            // upstream changes — same reasoning as `.commit`.
            return [
                .fileStatus,
                .log(refs: CacheKey.currentBranchSentinel),
                .currentBranch,
                .branchList
            ]

        case .stashSave, .stashApply, .stashDrop:
            return [.stashList, .fileStatus]

        case .branchCreate, .branchDelete, .branchRename:
            // Rule 1: a branch name is a chip in the graph. Creating one adds
            // it to a commit row, deleting one leaves the row drawing a branch
            // that no longer exists, and a rename does both.
            return [.branchList, .log(refs: CacheKey.currentBranchSentinel)]

        case .tagChange:
            // Same again for tags: `%D` carries them, and the Tags section is
            // cached for five minutes, which is a long time to show a tag the
            // user just deleted.
            return [.tagList, .log(refs: CacheKey.currentBranchSentinel)]

        case .reset:
            // A reset repoints the branch tip, so ahead/behind changes.
            return [
                .fileStatus,
                .log(refs: CacheKey.currentBranchSentinel),
                .currentBranch,
                .branchList
            ]
        }
    }

    // MARK: - Helpers

    /// Restate `changedPath` in the vocabulary the rules above are written
    /// in: metadata as `.git/<something>`, wherever it actually lives, and
    /// working-tree files relative to the checkout. `nil` means the path
    /// belongs to this repository's storage but not to this checkout.
    ///
    /// For an ordinary repository the git and common directories are the
    /// same `<root>/.git`, the first branch matches everything metadata, and
    /// the result is what plain prefix-stripping against the root produced.
    private static func relativePath(of changedPath: String, in layout: RepoLayout) -> String? {
        // Per-worktree first: in a linked worktree `gitDir` lives *inside*
        // `commonDir`, so the wider of the two would swallow every path that
        // belongs to this checkout and report it as the main one's.
        if let rest = suffix(of: changedPath, under: layout.gitDir) {
            return ".git/\(rest)"
        }
        if let rest = suffix(of: changedPath, under: layout.commonDir) {
            // Only refs are genuinely shared. `HEAD`, `index` and the
            // operation markers exist in the common directory too, but those
            // are the *main* checkout's — a sibling worktree staging a file
            // must not refresh this one's Files panel.
            guard !layout.isLinkedWorktree
                    || rest.hasPrefix("refs/") || rest == "packed-refs" else {
                return nil
            }
            return ".git/\(rest)"
        }
        if changedPath == layout.workTree { return "" }
        if let rest = suffix(of: changedPath, under: layout.workTree) { return rest }
        return changedPath
    }

    /// `path`'s remainder below `directory`, or `nil` when it isn't below it.
    private static func suffix(of path: String, under directory: String) -> String? {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

/// Enumerates user-initiated git actions that the cache understands.
enum GitAction: Sendable {
    case stage(files: [String])
    case unstage(files: [String])
    case discard(files: [String])
    /// `git update-index --[no-]assume-unchanged` on these paths.
    case assumeUnchanged(files: [String])
    case commit
    case pull
    case push
    case fetch
    case checkout
    case merge
    case rebase
    case reset
    case stashSave
    case stashApply
    case stashDrop
    case branchCreate
    case branchDelete
    case branchRename
    /// A tag created or deleted locally.
    case tagChange

    /// One of every kind, for the invariant tests.
    ///
    /// Hand-written because the cases carry associated values, so there is no
    /// `CaseIterable` to lean on. `InvalidationInvariantTests` asserts the
    /// count, which is the tripwire: adding an action without listing it here
    /// fails that test instead of quietly going unchecked.
    static let everyKind: [GitAction] = [
        .stage(files: ["a"]),
        .unstage(files: ["a"]),
        .discard(files: ["a"]),
        .assumeUnchanged(files: ["a"]),
        .commit,
        .pull,
        .push,
        .fetch,
        .checkout,
        .merge,
        .rebase,
        .reset,
        .stashSave,
        .stashApply,
        .stashDrop,
        .branchCreate,
        .branchDelete,
        .branchRename,
        .tagChange
    ]
}
