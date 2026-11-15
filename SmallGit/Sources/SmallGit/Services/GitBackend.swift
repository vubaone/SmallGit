import Foundation

/// What a git operation reports back: whether it worked, and what it said.
///
/// Shaped by the shell, because that is what produced every one of these until
/// now — but it is `GitBackend`'s currency, not `ProcessRunner`'s, which is why
/// it lives here. A backend that never spawns anything fills it through
/// `outcome(_:failure:)` rather than by inventing a command line.
struct GitCommandResult: Sendable {
    /// The git command, for the Output panel. A non-shell backend puts a
    /// readable description of the operation here instead.
    let command: String
    /// Zero means success. A non-shell backend may use its own error codes;
    /// nothing reads this beyond `succeeded`.
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let duration: TimeInterval

    var succeeded: Bool { exitCode == 0 }
    var combinedOutput: String {
        if stderr.isEmpty { return stdout }
        if stdout.isEmpty { return stderr }
        return stdout + "\n" + stderr
    }

    /// Build a result for an operation that ran in-process. `failure` nil means
    /// it succeeded; otherwise the message lands where callers already look for
    /// one, so `combinedOutput` and the Output panel keep working unchanged.
    static func outcome(
        _ description: String,
        failure: String? = nil,
        duration: TimeInterval = 0
    ) -> GitCommandResult {
        GitCommandResult(
            command: description,
            exitCode: failure == nil ? 0 : 1,
            stdout: "",
            stderr: failure ?? "",
            duration: duration
        )
    }
}

/// Every git operation SmallGit performs, stated independently of *how* it is
/// performed.
///
/// `GitService` — which spawns `git` — is the only conformer today. The
/// protocol exists because a second one is foreseeable: a sandboxed build for
/// the Mac App Store cannot exec a binary it does not ship, and would have to
/// drive libgit2 in-process instead. Writing the contract down now, where the
/// compiler checks it, costs nothing and means that port would start from a
/// specification rather than from reading 2,400 lines of an actor.
///
/// It doubles as a working document. The notes below appear only on the
/// operations where a non-shell backend has real work to do or has to decline
/// outright; silence means the operation maps onto libgit2 without drama,
/// which is true of about 70 of the 114.
///
/// ## The seam is not clean, and pretending otherwise would be worse
///
/// 60 of these return `GitCommandResult`, a type shaped by the shell: exit
/// code, stdout, stderr. The honest fix is a neutral outcome type, but that
/// means touching 60 signatures and the nine places that read those fields —
/// all before a second backend exists to justify the churn. So the type stays,
/// and `GitCommandResult.outcome(_:failure:)` gives a non-shell backend a
/// blessed way to build one without inventing a command line it never ran.
/// Revisit when the second conformer is real, not before.
///
/// ## Actor isolation
///
/// The protocol is `Actor`-constrained. `GitService` is an actor, and a
/// libgit2 backend wants to be one too — `git_repository` handles are not
/// thread-safe, so serializing access is a requirement there, not a taste.
///
/// ## Default arguments
///
/// Swift forbids them on protocol requirements, so the full parameter list
/// appears here while the defaults stay on `GitService`. Callers therefore
/// still hold the concrete type; switching them to `any GitBackend` needs a
/// protocol extension re-supplying the defaults, which is work worth doing
/// when there is a second backend to switch *between*.
// MARK: - Vocabulary

/// `.message` → `--grep`, `.author` → `--author` (both
/// case-insensitive), `.content` → `-S` (pickaxe: commits that change
/// the number of occurrences of the string — "when was this line
/// added/removed"), `.contentRegex` → `-G` (commits whose diff text
/// matches the regex).
enum LogSearchMode: String, Sendable {
    case message
    case author
    case content
    case contentRegex

    /// `true` for the pickaxe modes, which have to diff every commit
    /// against its parent instead of reading commit headers.
    var walksDiffs: Bool { self == .content || self == .contentRegex }
}

enum ConfigScope: Sendable {
    case local
    case global
}

/// Which side of a 3-way merge to read for a conflicted file.
/// Stage numbers are git's standard: 1 = common ancestor (base),
/// 2 = current branch (ours), 3 = incoming branch (theirs).
enum ConflictSide: Int, Sendable {
    case base = 1
    case ours = 2
    case theirs = 3
}

/// Describes which long-running operation (if any) the repo is
/// currently in. Detected by the presence of marker files git
/// drops in the git directory while merge / rebase / cherry-pick is
/// paused waiting for the user to resolve conflicts or continue.
enum InProgressOperation: String, Sendable {
    case merge, rebase, cherryPick, revert

    /// Human-readable name for banners and dialogs.
    var displayName: String {
        switch self {
        case .merge:      return "Merge"
        case .rebase:     return "Rebase"
        case .cherryPick: return "Cherry-pick"
        case .revert:     return "Revert"
        }
    }
}

/// How a merge lands the other branch — the outcomes SmartGit's Merge
/// dialog offers.
enum MergeMode: Sendable {
    /// `--ff-only`: move the branch up to the other one. Only on offer when
    /// the current branch is wholly contained in it.
    case fastForward
    /// `--no-ff`: always a merge commit, even where a fast-forward would do —
    /// picking it over Fast-Forward is asking for the commit.
    case mergeCommit
    /// `--no-ff --no-commit`: the merged result is left in the working tree
    /// and index with MERGE_HEAD set, for the user to review and then commit
    /// or abort. `--no-ff` is not optional here: git fast-forwards straight
    /// past `--no-commit`, and the branch moves with nothing left to review.
    case workingTree
}

/// HEAD against the branch about to be merged into it.
enum MergeRelation: Sendable {
    /// Everything on the branch is already on HEAD; a merge would do nothing.
    case upToDate
    /// HEAD is wholly contained in the branch, so it can fast-forward.
    case canFastForward
    /// Both sides have commits of their own; only a real merge joins them.
    case diverged
}

// MARK: - The contract

protocol GitBackend: Actor {


    // MARK: - Discovery

    func isRepository(at path: String) async -> Bool

    func probeWorkTree(at path: String) async -> WorkTreeProbe

    func repositoryRoot(of path: String) async throws -> String

    func layout(repoPath: String) async -> RepoLayout


    // MARK: - Status

    func trackedFiles(repoPath: String) async throws -> [String]

    func assumeUnchangedFiles(repoPath: String) async throws -> [String]

    @discardableResult
    func setAssumeUnchanged(
        repoPath: String,
        paths: [String],
        on: Bool
    ) async throws -> GitCommandResult

    func status(repoPath: String, includeIgnored: Bool) async throws -> [GitFileStatus]

    func currentBranch(repoPath: String) async throws -> String?

    func currentHeadSHA(repoPath: String) async throws -> String?

    func commitHasParent(repoPath: String, hash: String) async throws -> Bool

    func commitsAfter(repoPath: String, hash: String) async throws -> Int

    func commitsReachableFromUpstream(
        repoPath: String,
        hashes: Set<String>
    ) async throws -> Set<String>

    func upstreamGap(repoPath: String) async throws -> UpstreamGap?

    func unpushedHashes(repoPath: String) async throws -> Set<String>


    // MARK: - Branches

    func localBranches(repoPath: String) async throws -> [GitBranch]

    func remoteBranches(repoPath: String) async throws -> [GitBranch]

    func tags(repoPath: String) async throws -> [String]


    // MARK: - Log

    func log(repoPath: String, count: Int, revisions: [String]) async throws -> [GitCommit]

    func recentCommitMessages(repoPath: String, count: Int) async throws -> [String]

    /// `.content` / `.contentRegex` are git's `-S` / `-G` pickaxe. No libgit2
    /// equivalent, and diffing every commit by hand is far slower than git's C.
    /// A backend that cannot afford it should reject those two modes rather
    /// than answer slowly; `.message` / `.author` are plain revwalk filters.
    func searchLog(
        repoPath: String,
        query: String,
        mode: LogSearchMode,
        count: Int,
        revisions: [String]
    ) async throws -> [GitCommit]

    /// Uses `--follow`. Rename detection across history has no libgit2
    /// equivalent; approximate per-step with `git_diff_find_similar`, or drop it.
    func fileHistory(repoPath: String, path: String, count: Int) async throws -> [GitCommit]

    func blame(repoPath: String, path: String) async throws -> [GitBlameLine]

    func blameLineHistory(repoPath: String, path: String, line: Int) async throws -> String


    // MARK: - Diff

    func diff(
        repoPath: String,
        file: String?,
        mode: DiffCompareMode,
        ignoreWhitespace: Bool,
        fullFile: Bool
    ) async throws -> [DiffHunk]

    func untrackedDiff(
        repoPath: String,
        file: String,
        ignoreWhitespace: Bool
    ) async throws -> [DiffHunk]

    func conflictDiff(
        repoPath: String,
        file: String,
        ignoreWhitespace: Bool,
        fullFile: Bool
    ) async throws -> [DiffHunk]


    // MARK: - Index actions

    /// Whole paths only. Hunk- and line-level staging arrives via `applyPatch`,
    /// which is where `DiffPatchBuilder`'s output lands.
    @discardableResult
    func stage(repoPath: String, files: [String]) async throws -> GitCommandResult

    @discardableResult
    func unstage(repoPath: String, files: [String]) async throws -> GitCommandResult

    @discardableResult
    func discard(repoPath: String, files: [String]) async throws -> GitCommandResult

    /// Restores from HEAD, not the index — the only source that can clear a
    /// conflicted path's unmerged stages.
    @discardableResult
    func discardConflicted(repoPath: String, files: [String]) async throws -> GitCommandResult

    /// Puts a conflict back that something flattened. libgit2 has no direct
    /// equivalent: a backend would have to re-run `git_merge_file` against the
    /// paused operation's two heads and write the three stages itself.
    @discardableResult
    func restoreConflict(repoPath: String, files: [String]) async throws -> GitCommandResult

    @discardableResult
    func cleanUntracked(
        repoPath: String,
        paths: [String],
        includeIgnored: Bool
    ) async throws -> GitCommandResult

    @discardableResult
    func commit(
        repoPath: String,
        subject: String,
        body: String?,
        amend: Bool
    ) async throws -> GitCommandResult

    @discardableResult
    func commitFixup(repoPath: String, targetHash: String) async throws -> GitCommandResult

    /// libgit2 has no autosquash: order the todo yourself, then replay.
    @discardableResult
    func autosquashRebase(repoPath: String, base: String) async throws -> GitCommandResult


    // MARK: - Credentials

    /// Shells out to `git credential`. A non-shell backend owns its own
    /// credential storage and satisfies these three from the Keychain.
    func credentialHelper(repoPath: String?) async throws -> String?

    @discardableResult
    func useKeychainCredentialHelper(repoPath: String?) async throws -> GitCommandResult

    @discardableResult
    func approveCredential(
        repoPath: String?,
        scheme: String,
        host: String,
        username: String,
        password: String
    ) async throws -> GitCommandResult

    func pull(
        repoPath: String,
        rebase: Bool,
        autostash: Bool
    ) async throws -> GitCommandResult

    @discardableResult
    func push(repoPath: String, force: Bool, tags: Bool) async throws -> GitCommandResult

    @discardableResult
    func fetch(repoPath: String, prune: Bool) async throws -> GitCommandResult

    @discardableResult
    func clone(
        remoteURL: String,
        destinationParent: String,
        folderName: String
    ) async throws -> (result: GitCommandResult, clonedPath: String)

    @discardableResult
    func pushTo(
        repoPath: String,
        remote: String,
        localBranch: String,
        remoteBranch: String?,
        force: Bool,
        setUpstream: Bool,
        tags: Bool
    ) async throws -> GitCommandResult

    func upstreamOfBranch(
        repoPath: String,
        branch: String
    ) async throws -> (remote: String, branch: String)?


    // MARK: - Config (user.name / user.email and friends)

    func configValue(
        repoPath: String?,
        key: String,
        scope: ConfigScope
    ) async throws -> String?

    @discardableResult
    func setConfigValue(
        repoPath: String?,
        key: String,
        value: String,
        scope: ConfigScope
    ) async throws -> GitCommandResult

    @discardableResult
    func unsetConfigValue(
        repoPath: String?,
        key: String,
        scope: ConfigScope
    ) async throws -> GitCommandResult

    @discardableResult
    func initRepository(
        at path: String,
        initialBranch: String
    ) async throws -> GitCommandResult

    @discardableResult
    func addRemote(
        repoPath: String,
        name: String,
        url: String
    ) async throws -> GitCommandResult

    func remotes(repoPath: String) async throws -> [String]

    func remoteDetails(repoPath: String) async throws -> [GitRemote]

    @discardableResult
    func setUpstream(
        repoPath: String,
        branch: String,
        upstream: String
    ) async throws -> GitCommandResult

    @discardableResult
    func unsetUpstream(repoPath: String, branch: String) async throws -> GitCommandResult


    // MARK: - File compare

    func fileAtHead(repoPath: String, path: String) async throws -> String?

    func fileAtRevision(
        repoPath: String,
        revision: String,
        path: String
    ) async throws -> String?


    // MARK: - Conflict resolution

    func conflictVersion(
        repoPath: String,
        path: String,
        side: ConflictSide
    ) async throws -> String?

    func conflictStages(repoPath: String, path: String) async throws -> Set<Int>

    @discardableResult
    func acceptOurs(repoPath: String, path: String) async throws -> GitCommandResult

    @discardableResult
    func acceptTheirs(repoPath: String, path: String) async throws -> GitCommandResult

    @discardableResult
    func markResolved(repoPath: String, path: String) async throws -> GitCommandResult

    func restoreConflictMarkersWithAncestor(
        repoPath: String,
        path: String
    ) async throws -> GitCommandResult


    // MARK: - Submodules

    func submodules(repoPath: String) async -> [GitSubmodule]

    func submoduleChange(repoPath: String, path: String) async -> SubmoduleChange?

    func updateSubmodules(
        repoPath: String,
        paths: [String],
        recursive: Bool
    ) async throws -> GitCommandResult

    func deinitSubmodule(
        repoPath: String,
        path: String,
        force: Bool
    ) async throws -> GitCommandResult

    func syncSubmodules(repoPath: String, recursive: Bool) async throws -> GitCommandResult

    func addSubmodule(
        repoPath: String,
        url: String,
        path: String
    ) async throws -> GitCommandResult

    func abortMerge(repoPath: String) async throws -> GitCommandResult

    /// Drives the merge/rebase banner and the conflict resolver.
    /// `git_repository_state()` answers this directly.
    func inProgressOperation(repoPath: String) async -> InProgressOperation?

    @discardableResult
    func continueOperation(
        repoPath: String,
        operation: InProgressOperation
    ) async throws -> GitCommandResult

    @discardableResult
    func abortOperation(
        repoPath: String,
        operation: InProgressOperation
    ) async throws -> GitCommandResult


    // MARK: - Stash

    func stashSave(
        repoPath: String,
        message: String?,
        includeUntracked: Bool,
        keepIndex: Bool,
        paths: [String]
    ) async throws -> GitCommandResult

    /// Writes a stash entry and leaves the working tree untouched. Git has no
    /// single command for it — the shell backend runs `stash create` and
    /// `stash store`, and builds the untracked parent itself because `create`
    /// never includes one. A library backend writes the same commit directly.
    @discardableResult
    func stashSnapshot(
        repoPath: String,
        message: String?,
        includeUntracked: Bool
    ) async throws -> GitCommandResult

    @discardableResult
    func stashApply(repoPath: String, index: Int) async throws -> GitCommandResult

    @discardableResult
    func stashPop(repoPath: String) async throws -> GitCommandResult

    /// Undoes a conflicted `stash apply`, which git itself cannot: the state
    /// has no marker and no sequencer, only unmerged index entries. Restores
    /// the stash's files from HEAD and returns those left in place because
    /// HEAD has no version of them.
    @discardableResult
    func abortStashApply(
        repoPath: String,
        files: [String]
    ) async throws -> (result: GitCommandResult, leftInPlace: [String])

    @discardableResult
    func stashDrop(repoPath: String, index: Int) async throws -> GitCommandResult

    /// Changes a stash entry's message and leaves it at the same index. Git
    /// has no rename; the shell backend rewrites the stash reflog around it.
    @discardableResult
    func stashRename(repoPath: String, index: Int, message: String) async throws -> GitCommandResult


    // MARK: - Maintenance

    /// `git count-objects -v`. Without it, measure `.git` on disk.
    func objectDatabaseSize(repoPath: String) async throws -> Int64

    /// No libgit2 equivalent — there is no repack/gc API. A backend without one
    /// should say so rather than report space it never reclaimed.
    @discardableResult
    func gc(repoPath: String, pruneExpiry: String) async throws -> GitCommandResult

    @discardableResult
    func pruneRemote(repoPath: String, remote: String) async throws -> GitCommandResult


    // MARK: - Worktrees

    func worktrees(repoPath: String) async throws -> [GitWorktree]

    @discardableResult
    func addWorktree(
        repoPath: String,
        path: String,
        checkoutBranch: String?,
        newBranch: String?,
        startPoint: String?
    ) async throws -> GitCommandResult

    @discardableResult
    func removeWorktree(
        repoPath: String,
        path: String,
        force: Bool
    ) async throws -> GitCommandResult

    @discardableResult
    func pruneWorktrees(repoPath: String) async throws -> GitCommandResult

    func commitFiles(repoPath: String, hash: String) async throws -> [GitFileStatus]

    func containment(repoPath: String, hash: String) async throws -> CommitContainment

    func commitBody(repoPath: String, hash: String) async throws -> String

    func commitDiff(
        repoPath: String,
        hash: String,
        paths: [String],
        ignoreWhitespace: Bool,
        fullFile: Bool
    ) async throws -> [DiffHunk]

    func stashDiff(
        repoPath: String,
        index: Int,
        path: String?,
        ignoreWhitespace: Bool,
        fullFile: Bool
    ) async throws -> [DiffHunk]

    func stashFiles(repoPath: String, index: Int) async throws -> [StashFile]

    func resolveRevision(repoPath: String, revision: String) async -> String?

    func stashList(repoPath: String) async throws -> [GitStash]


    // MARK: - Branch ops

    @discardableResult
    func checkoutBranch(repoPath: String, name: String) async throws -> GitCommandResult

    func refExists(repoPath: String, ref: String) async -> Bool

    @discardableResult
    func createBranch(
        repoPath: String,
        name: String,
        from: String?,
        checkout: Bool
    ) async throws -> GitCommandResult

    @discardableResult
    func deleteBranch(
        repoPath: String,
        name: String,
        force: Bool
    ) async throws -> GitCommandResult

    func deleteRemoteBranch(
        repoPath: String,
        remote: String,
        branch: String
    ) async throws -> GitCommandResult

    func branchDeletionCheck(
        repoPath: String,
        branch: String,
        upstream: String?,
        comparedTo: String
    ) async throws -> BranchDeletionCheck

    @discardableResult
    func renameBranch(
        repoPath: String,
        from: String,
        to: String
    ) async throws -> GitCommandResult

    @discardableResult
    func merge(
        repoPath: String,
        branch: String,
        mode: MergeMode,
        autostash: Bool
    ) async throws -> GitCommandResult

    /// Where HEAD stands relative to `branch`, which decides what a merge of
    /// it can offer.
    func mergeRelation(repoPath: String, branch: String) async -> MergeRelation

    /// Fetch `branch`'s upstream and fast-forward the branch to it, with the
    /// branch left where it is in the working tree — not checked out.
    @discardableResult
    func fastForwardToUpstream(repoPath: String, branch: String) async throws -> GitCommandResult

    /// Rebase onto or merge the checked-out branch's fetched upstream.
    /// Rebase preserves merges and leaves all other local branches in place.
    func integrateUpstream(repoPath: String, branch: String, rebase: Bool) async throws -> GitCommandResult

    func holdsOnlyFormerUpstream(repoPath: String, branch: String) async -> Bool

    func commitsFromRewrittenBase(repoPath: String, base: String) async -> [RebaseTodo]

    @discardableResult
    func rebase(
        repoPath: String,
        onto: String,
        from: String?,
        autostash: Bool
    ) async throws -> GitCommandResult

    func reflog(repoPath: String, limit: Int) async throws -> [GitReflogEntry]

    /// The interactive rebase's todo, worked out the way git's own sequencer
    /// works it out — including dropping commits the base already carries under
    /// a different SHA. A backend that gets this wrong does not fail, it
    /// replays the wrong commits.
    func rebaseRange(repoPath: String, base: String) async throws -> RebaseRange

    /// Just the rows to replay, for the callers that build their own plan.
    func commitsToRebase(repoPath: String, base: String) async throws -> [RebaseTodo]

    /// The merges inside the same range, which no interactive rebase can
    /// replay — the planner refuses a range holding one rather than let git
    /// flatten it silently.
    func mergesToRebase(repoPath: String, base: String) async throws -> [String]

    /// No libgit2 equivalent. Replay via cherry-pick + amend, honouring `todo`.
    @discardableResult
    func runInteractiveRebase(
        repoPath: String,
        onto: String,
        todo: [RebaseTodo]
    ) async throws -> GitCommandResult

    func commitMessageAndAuthorDate(
        repoPath: String,
        hash: String
    ) async throws -> (message: String, authorDateISO: String)

    /// Built on the same replay loop as `runInteractiveRebase`.
    @discardableResult
    func squashRange(
        repoPath: String,
        onto: String,
        pickHash: String,
        selectedHashes: Set<String>,
        lastSelectedHash: String,
        message: String,
        authorName: String?,
        authorEmail: String?,
        authorDateISO: String?
    ) async throws -> GitCommandResult

    /// Amend when `hash` is HEAD; otherwise a replay from its parent.
    @discardableResult
    func rewordCommit(
        repoPath: String,
        onto: String,
        hash: String,
        message: String
    ) async throws -> GitCommandResult

    @discardableResult
    func reset(
        repoPath: String,
        ref: String,
        mode: ResetMode
    ) async throws -> GitCommandResult

    @discardableResult
    func cherryPick(repoPath: String, hash: String) async throws -> GitCommandResult

    @discardableResult
    func revertCommit(
        repoPath: String,
        hash: String,
        noCommit: Bool
    ) async throws -> GitCommandResult

    @discardableResult
    func createTag(
        repoPath: String,
        name: String,
        message: String?,
        hash: String?
    ) async throws -> GitCommandResult

    @discardableResult
    func deleteTag(repoPath: String, name: String) async throws -> GitCommandResult

    @discardableResult
    func pushTag(
        repoPath: String,
        remote: String,
        tag: String,
        delete: Bool
    ) async throws -> GitCommandResult

    @discardableResult
    func removeFile(
        repoPath: String,
        path: String,
        cached: Bool
    ) async throws -> GitCommandResult

    /// The staging path for hunks and lines, not only user-supplied patches.
    /// `git_apply` against the index covers both.
    @discardableResult
    func applyPatch(
        repoPath: String,
        patch: String,
        cached: Bool,
        reverse: Bool
    ) async throws -> GitCommandResult


    // MARK: - Patches (file-level)

    func createPatch(repoPath: String, files: [String]) async throws -> String

    func createPatch(repoPath: String, commitHash: String) async throws -> String

    func createPatch(repoPath: String, stashIndex: Int) async throws -> String

    @discardableResult
    func applyPatchFile(
        repoPath: String,
        patchPath: String,
        threeWay: Bool
    ) async throws -> GitCommandResult

    func addToGitignore(repoPath: String, patterns: [String]) async throws

    @discardableResult
    func addToLocalExclude(repoPath: String, patterns: [String]) async throws -> [String]

    func trackedFiles(repoPath: String, under path: String) async throws -> [String]

}

/// The shell backend meets the contract as written — no shims, no adapters.
/// An empty conformance is the point: it is a compile-time assertion that the
/// seam runs exactly where `GitService`'s own API already ran, so nothing was
/// bent to fit a protocol that has only one implementation so far.
extension GitService: GitBackend {}
