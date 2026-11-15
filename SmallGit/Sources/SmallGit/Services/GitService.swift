import Foundation

/// The three answers `probeWorkTree(at:)` can give. `unknown` is the one
/// worth having: it means git was never heard from, not that the folder
/// failed the question.
enum WorkTreeProbe: Sendable, Equatable {
    case workTree(root: String)
    case notARepository
    case unknown
}

/// Thin domain-typed facade over `ProcessRunner`. All UI flows go through
/// `CacheCoordinator` rather than touching this directly (see Sprint 2).
actor GitService {
    static let shared = GitService()

    private let runner: ProcessRunner

    /// Resolved `RepoLayout` per repo path — see `layout(repoPath:)`.
    private var layouts: [String: RepoLayout] = [:]

    init(runner: ProcessRunner = .shared) {
        self.runner = runner
    }


    // These four moved to GitBackend.swift — they describe the operations, not
    // the shell that runs them. Aliased so `GitService.LogSearchMode` and
    // friends keep resolving at existing call sites.
    typealias LogSearchMode = SmallGit.LogSearchMode
    typealias ConfigScope = SmallGit.ConfigScope
    typealias ConflictSide = SmallGit.ConflictSide
    typealias InProgressOperation = SmallGit.InProgressOperation

    // MARK: - Discovery

    func isRepository(at path: String) async -> Bool {
        let r = try? await runner.run(in: path, args: ["rev-parse", "--is-inside-work-tree"])
        return r?.succeeded == true
            && r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// What git says about `path`, with "git never answered" kept apart
    /// from "git answered no". A spawn that failed, a timeout or a cancelled
    /// refresh says nothing about the folder, and the sidebar must not turn
    /// that into a "Not a Repo" badge that stays until the app is relaunched.
    ///
    /// One `rev-parse` rather than the two this used to take: the sidebar
    /// asks about every repository at once, and each process costs
    /// descriptors while it lives.
    func probeWorkTree(at path: String) async -> WorkTreeProbe {
        guard let r = try? await runner.run(in: path, args: ["rev-parse", "--show-toplevel"]) else {
            return .unknown
        }
        // A cancelled refresh kills the process mid-question. The non-zero
        // exit that leaves behind is the signal, not git's answer.
        if Task.isCancelled { return .unknown }
        guard r.succeeded else { return .notARepository }
        let root = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare repository, or a path inside `.git`, answers with nothing
        // to show as a work tree.
        return root.isEmpty ? .notARepository : .workTree(root: root)
    }

    func repositoryRoot(of path: String) async throws -> String {
        let r = try await runner.run(in: path, args: ["rev-parse", "--show-toplevel"])
        guard r.succeeded else { throw GitServiceError.notARepository(path) }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where `repoPath` keeps its metadata — asked of git rather than assumed
    /// to be `<repoPath>/.git`, which is a *file* in a linked worktree or a
    /// submodule. See `RepoLayout` for what goes wrong when it is assumed.
    ///
    /// Cached: a repository's layout is fixed for as long as the repository
    /// exists, and this is consulted on every panel refresh.
    func layout(repoPath: String) async -> RepoLayout {
        if let cached = layouts[repoPath] { return cached }
        let resolved = await resolveLayout(repoPath: repoPath)
        layouts[repoPath] = resolved
        return resolved
    }

    private func resolveLayout(repoPath: String) async -> RepoLayout {
        let fallback = RepoLayout.assumed(workTree: repoPath)
        guard let r = try? await runner.run(
            in: repoPath,
            args: ["rev-parse", "--absolute-git-dir", "--git-common-dir"]
        ), r.succeeded else { return fallback }

        let lines = r.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count == 2 else { return fallback }

        // Only `--absolute-git-dir` promises an absolute path. A relative
        // `--git-common-dir` — the bare `.git` an ordinary repository
        // reports — means there is no separate shared store, so the git
        // directory *is* the common one. Spelling it out from `repoPath`
        // instead would produce a second name for the same directory
        // whenever that path runs through a symlink, and the two would then
        // compare as a linked worktree.
        let common = lines[1].hasPrefix("/") ? lines[1] : lines[0]
        return RepoLayout(workTree: repoPath, gitDir: lines[0], commonDir: common)
    }

    // MARK: - Status

    /// Every file git tracks, whether or not it has changed — the index's
    /// contents. Feeds the Files panel's filter, where a query is a way to
    /// find a file, not only to narrow the handful that changed.
    ///
    /// NUL-separated so paths with spaces, quotes or newlines survive.
    func trackedFiles(repoPath: String) async throws -> [String] {
        let r = try await runner.run(in: repoPath, args: ["ls-files", "-z"])
        try ensureSucceeded(r)
        return r.stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Paths whose index entry carries the `assume-unchanged` bit.
    ///
    /// `git status` cannot answer this. The flag exists to stop git
    /// stat-ing the file, so a flagged path is absent from status whether
    /// it was edited or not — which is exactly why the Files panel has to
    /// ask a second question to show them at all.
    ///
    /// `ls-files -v` prints a tag per index entry — `H` cached, `S`
    /// skip-worktree, `M` unmerged, … — and lowercases it when the entry
    /// is assume-unchanged. So the flag is "tag is a lowercase letter",
    /// not "tag is `h`": a skip-worktree file that is also flagged comes
    /// back as `s`.
    ///
    /// NUL-separated so paths with spaces or newlines survive.
    func assumeUnchangedFiles(repoPath: String) async throws -> [String] {
        let r = try await runner.run(in: repoPath, args: ["ls-files", "-v", "-z"])
        try ensureSucceeded(r)
        return GitOutputParser.parseAssumeUnchanged(r.stdout)
    }

    /// Set or clear `assume-unchanged` on `paths`.
    ///
    /// Only meaningful for tracked paths: `update-index` has no entry to
    /// flag for an untracked file and fails the whole invocation if one is
    /// in the list.
    ///
    /// The paths go in on stdin, NUL-separated: a folder flagged from the
    /// sidebar can hold thousands of files, more than fits in an argv.
    @discardableResult
    func setAssumeUnchanged(
        repoPath: String,
        paths: [String],
        on: Bool
    ) async throws -> GitCommandResult {
        try await runner.run(
            in: repoPath,
            args: ["update-index", on ? "--assume-unchanged" : "--no-assume-unchanged", "-z", "--stdin"],
            stdin: paths.joined(separator: "\0") + "\0"
        )
    }

    /// Tracked files at or under `path`, relative to the repository — what
    /// an index flag set on a folder actually lands on. Literal, so a folder
    /// named with a `*` or a `[` means that folder.
    func trackedFiles(repoPath: String, under path: String) async throws -> [String] {
        let r = try await runner.run(
            in: repoPath,
            args: ["--literal-pathspecs", "ls-files", "-z", "--", path]
        )
        try ensureSucceeded(r)
        return r.stdout.split(separator: "\0").map(String.init)
    }

    func status(repoPath: String, includeIgnored: Bool = false) async throws -> [GitFileStatus] {
        // `--untracked-files=all` matches SmartGit / Tower: when a new
        // directory is untracked, list each file inside it rather than
        // collapsing to a single "dirname/" entry. Without this the
        // Files panel shows a single row like `_temp/` instead of the
        // dozen actual files the user just dropped in.
        var args = ["status", "--porcelain=v2", "-z", "--untracked-files=all"]
        if includeIgnored { args.append("--ignored=traditional") }
        let r = try await runner.run(in: repoPath, args: args)
        try ensureSucceeded(r)
        let parsed = GitOutputParser.parseStatus(r.stdout)
        return await mergeWorktreeRenames(parsed, repoPath: repoPath)
    }

    /// `git status` only pairs a delete with an add into a rename when
    /// *both sides are staged* — a worktree deletion plus a brand-new
    /// untracked file are reported as two separate rows. SmartGit / Tower
    /// collapse that pair into a single rename by running their own
    /// similarity pass; this does the same for the unambiguous case:
    /// an untracked file whose content hashes to the exact same blob as a
    /// worktree-deleted file is shown as one unstaged rename (R) row.
    ///
    /// Only exact (100% identical) content is matched — a deliberately
    /// conservative bar that avoids guessing at near-matches. The pass is
    /// skipped entirely unless the working tree holds *both* an unstaged
    /// deletion and an untracked file, so the common status call pays
    /// nothing.
    private func mergeWorktreeRenames(
        _ statuses: [GitFileStatus],
        repoPath: String
    ) async -> [GitFileStatus] {
        let deleted = statuses.filter { $0.workTreeStatus == "D" && !$0.isStaged }
        let untracked = statuses.filter { $0.state == .untracked }
        // Bail before any extra git work when there's nothing to pair, and
        // cap the untracked set so a repo with thousands of new files
        // doesn't trigger a huge hash-object sweep just because one file
        // was deleted.
        guard !deleted.isEmpty, !untracked.isEmpty, untracked.count <= 2000 else {
            return statuses
        }

        guard
            let deletedSHAs = try? await indexBlobSHAs(repoPath: repoPath, paths: deleted.map(\.path)),
            let untrackedSHAs = try? await worktreeBlobSHAs(repoPath: repoPath, paths: untracked.map(\.path))
        else {
            return statuses
        }

        // SHA → queue of deleted paths with that content (handles several
        // identical files being renamed at once, e.g. a moved directory).
        var deletedBySHA: [String: [String]] = [:]
        for f in deleted {
            if let sha = deletedSHAs[f.path] { deletedBySHA[sha, default: []].append(f.path) }
        }

        var consumed = Set<String>()
        var renames: [GitFileStatus] = []
        for f in untracked {
            guard let sha = untrackedSHAs[f.path],
                  var queue = deletedBySHA[sha], !queue.isEmpty else { continue }
            let origin = queue.removeFirst()
            deletedBySHA[sha] = queue
            consumed.insert(origin)
            consumed.insert(f.path)
            renames.append(GitFileStatus(
                path: f.path,
                indexStatus: ".",
                workTreeStatus: "R",
                originalPath: origin
            ))
        }
        guard !renames.isEmpty else { return statuses }
        return statuses.filter { !consumed.contains($0.path) } + renames
    }

    /// Maps each path to its blob SHA in the index (`git ls-files -s`).
    /// Used to fingerprint worktree-deleted files, whose content still
    /// lives in the index even though it's gone from disk.
    private func indexBlobSHAs(repoPath: String, paths: [String]) async throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let r = try await runner.run(in: repoPath, args: ["ls-files", "-s", "-z", "--"] + paths)
        try ensureSucceeded(r)
        var map: [String: String] = [:]
        for record in r.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            // "<mode> <sha> <stage>\t<path>"
            let s = String(record)
            guard let tab = s.firstIndex(of: "\t") else { continue }
            let meta = s[..<tab].split(separator: " ")
            guard meta.count >= 2 else { continue }
            map[String(s[s.index(after: tab)...])] = String(meta[1])
        }
        return map
    }

    /// Maps each path to the blob SHA git *would* assign its on-disk
    /// content (`git hash-object`). One SHA per input line, in order.
    private func worktreeBlobSHAs(repoPath: String, paths: [String]) async throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let r = try await runner.run(in: repoPath, args: ["hash-object", "--"] + paths)
        try ensureSucceeded(r)
        let shas = r.stdout.split(whereSeparator: { $0 == "\n" }).map(String.init)
        guard shas.count == paths.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(paths, shas))
    }

    func currentBranch(repoPath: String) async throws -> String? {
        let r = try await runner.run(in: repoPath, args: ["symbolic-ref", "--short", "HEAD"])
        guard r.succeeded else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func currentHeadSHA(repoPath: String) async throws -> String? {
        let r = try await runner.run(in: repoPath, args: ["rev-parse", "HEAD"])
        guard r.succeeded else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commitHasParent(repoPath: String, hash: String) async throws -> Bool {
        let r = try await runner.run(in: repoPath, args: [
            "rev-parse", "--verify", "\(hash)^"
        ])
        return r.succeeded
    }

    /// How many commits sit between `hash` and HEAD, exclusive — i.e. how
    /// many an interactive rewrite of `hash` has to replay onto its
    /// replacement, each of them landing on a new hash. Zero when `hash`
    /// *is* HEAD.
    func commitsAfter(repoPath: String, hash: String) async throws -> Int {
        let r = try await runner.run(in: repoPath, args: [
            "rev-list", "--count", "\(hash)..HEAD"
        ])
        guard r.succeeded else { return 0 }
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func commitsReachableFromUpstream(repoPath: String, hashes: Set<String>) async throws -> Set<String> {
        guard !hashes.isEmpty else { return [] }
        let upstream = try await runner.run(in: repoPath, args: [
            "rev-parse", "--verify", "@{upstream}"
        ])
        guard upstream.succeeded else { return [] }

        var reachable: Set<String> = []
        for hash in hashes {
            let result = try await runner.run(in: repoPath, args: [
                "merge-base", "--is-ancestor", hash, "@{upstream}"
            ])
            if result.succeeded {
                reachable.insert(hash)
            }
        }
        return reachable
    }

    /// What the current branch's upstream holds that HEAD does not, and what
    /// that upstream is called.
    ///
    /// The other half of `unpushedHashes`. A branch that has been rebased or
    /// squashed is *both* ahead and behind its upstream — the old commits are
    /// still sitting on the remote — and a log drawn from HEAD alone shows
    /// only the rewritten side of that, which is the half the user already
    /// knows about.
    ///
    /// Nil when there is nothing to compare against: a branch with no
    /// upstream, a detached HEAD, an upstream that is `[gone]`.
    func upstreamGap(repoPath: String) async throws -> UpstreamGap? {
        let name = try await runner.run(in: repoPath, args: [
            "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"
        ])
        guard name.succeeded else { return nil }
        let ref = name.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return nil }

        let incoming = try await runner.run(in: repoPath, args: [
            "rev-list", "HEAD..@{upstream}"
        ])
        guard incoming.succeeded else { return nil }
        return UpstreamGap(ref: ref, incoming: Self.parseHashes(incoming.stdout))
    }

    /// SHAs of commits on HEAD that aren't yet on any remote — i.e. the
    /// orange "outgoing" markers SmartGit shows in the Journal.
    ///
    /// Resolution strategy:
    /// 1. **Preferred** — `git rev-list @{upstream}..HEAD` when the
    ///    branch has an upstream configured. Matches exactly what
    ///    `git push` would send.
    /// 2. **Fallback** — `git rev-list HEAD --not --remotes` for
    ///    branches with no upstream (fresh local branches, branches
    ///    detached from any tracking ref). Returns commits reachable
    ///    from HEAD but not from any remote-tracking ref. This covers
    ///    the "I made this on a new branch and haven't pushed yet"
    ///    case, which the previous upstream-only path silently
    ///    reported as zero.
    ///
    /// Returns empty set when both queries fail (corrupt repo, no
    /// commits yet, …).
    func unpushedHashes(repoPath: String) async throws -> Set<String> {
        let upstream = try await runner.run(in: repoPath, args: [
            "rev-list", "@{upstream}..HEAD"
        ])
        if upstream.succeeded {
            return Self.parseHashes(upstream.stdout)
        }

        let notRemote = try await runner.run(in: repoPath, args: [
            "rev-list", "HEAD", "--not", "--remotes"
        ])
        guard notRemote.succeeded else { return [] }
        return Self.parseHashes(notRemote.stdout)
    }

    private static func parseHashes(_ output: String) -> Set<String> {
        Set(output
            .split(whereSeparator: { $0 == "\n" })
            .map(String.init)
            .filter { !$0.isEmpty })
    }

    // MARK: - Branches

    /// Branches come back in git's plain refname order, which sorts
    /// "ZSOC-1056" above "ZSOC-153". Every list in the app reads better
    /// numbered the way people number things, so the ordering is applied
    /// here rather than at each of the places that display it.
    func localBranches(repoPath: String) async throws -> [GitBranch] {
        let fmt = "%(refname:short)%00%(upstream:short)%00%(worktreepath)%00%(HEAD)%00%(upstream:remotename)%00%(upstream:track,nobracket)"
        let r = try await runner.run(in: repoPath, args: ["branch", "--format=\(fmt)"])
        try ensureSucceeded(r)
        return GitOutputParser.parseBranches(r.stdout, remote: false)
            .sorted { $0.name.naturallyPrecedes($1.name) }
    }

    func remoteBranches(repoPath: String) async throws -> [GitBranch] {
        let fmt = "%(refname:short)%00%(upstream:short)%00%(worktreepath)%00"
        let r = try await runner.run(in: repoPath, args: ["branch", "-r", "--format=\(fmt)"])
        try ensureSucceeded(r)
        return GitOutputParser.parseBranches(r.stdout, remote: true)
            .sorted { $0.name.naturallyPrecedes($1.name) }
    }

    func tags(repoPath: String) async throws -> [String] {
        let r = try await runner.run(in: repoPath, args: ["tag", "--sort=-creatordate"])
        try ensureSucceeded(r)
        return r.stdout.split(whereSeparator: { $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Log

    /// - Parameter revisions: refs to walk, as `git log` takes them. Empty
    ///   means no ref argument at all — HEAD's history, the default view.
    ///   More than one is the multi-ref graph the Branches checkboxes
    ///   drive: the union of everything reachable from them.
    func log(
        repoPath: String,
        count: Int = 100,
        revisions: [String] = []
    ) async throws -> [GitCommit] {
        // Includes %P (space-separated parent SHAs) for the commit-graph
        // layout engine. NUL-separated to survive arbitrary subject text.
        let fmt = "%H%x00%h%x00%s%x00%an%x00%ae%x00%aI%x00%D%x00%P"
        // `--topo-order` keeps each branch's commits contiguous so the graph
        // lanes open and close tightly (like SmartGit). Plain date order
        // interleaves sibling branches that share timestamps, which leaves
        // many lanes open at once and turns the graph into a tangle.
        var args = ["log", "--topo-order", "--format=\(fmt)", "-n", "\(count)"]
        var stdin: String?

        if !revisions.isEmpty {
            let inline = revisions.joined(separator: " ")
            if inline.utf8.count > Self.maxInlineRevisionBytes {
                // A remote can hold thousands of branches, and ticking the
                // group puts every one of them on the command line. `--stdin`
                // takes the same revisions without an argv limit. Note it
                // rejects `--ignore-missing`, so this path relies on the
                // caller having pruned deleted refs.
                args.append("--stdin")
                stdin = revisions.joined(separator: "\n") + "\n"
            } else {
                // A selection outlives the branches in it: someone deletes a
                // branch we still have ticked and git would fail the whole
                // query over one bad revision. Skipping it beats showing
                // nothing.
                args.append("--ignore-missing")
                args += revisions
            }
        }

        let r = try await runner.run(in: repoPath, args: args, stdin: stdin)
        try ensureSucceeded(r)
        return GitOutputParser.parseLog(r.stdout)
    }

    /// Full messages for the commit dialog's reuse menu, newest first.
    /// NUL-separated records preserve paragraphs and trailers in each message.
    func recentCommitMessages(repoPath: String, count: Int = 10) async throws -> [String] {
        guard count > 0 else { return [] }
        let result = try await runner.run(in: repoPath, args: [
            "log", "--topo-order", "--no-color", "--no-show-signature",
            "-z", "--format=%B", "-n", "\(count)"
        ])
        try ensureSucceeded(result)
        return result.stdout.split(separator: "\0").map {
            $0.trimmingCharacters(in: .newlines)
        }
    }

    /// Where `log` switches from command-line revisions to `--stdin`.
    /// Well under any real argv limit — the point is to bound argv, not to
    /// find its edge.
    private static let maxInlineRevisionBytes = 100_000

    /// What a journal search matches against. Raw git flags:

    /// Git-backed history search — unlike the Journal's client-side
    /// filter this walks the *entire* history, not just the loaded pages.
    /// Same output format as `log()` so the shared parser applies.
    /// Results come back newest-first in git's default order (search hits
    /// are usually sparse, so `--topo-order` buys nothing here).
    func searchLog(
        repoPath: String,
        query: String,
        mode: LogSearchMode,
        count: Int = 1000,
        revisions: [String] = []
    ) async throws -> [GitCommit] {
        let fmt = "%H%x00%h%x00%s%x00%an%x00%ae%x00%aI%x00%D%x00%P"
        var args = ["log", "--format=\(fmt)", "-n", "\(count)"]
        switch mode {
        case .message:
            args += ["--regexp-ignore-case", "--grep=\(query)"]
        case .author:
            args += ["--regexp-ignore-case", "--author=\(query)"]
        case .content:
            // -S takes its argument attached or separate; separate keeps
            // queries that start with "-" from being read as a flag.
            args += ["-S", query]
        case .contentRegex:
            args += ["-G", query]
        }
        // Search the same refs the journal is graphing, so a hit is
        // always a commit the user could have scrolled to.
        if !revisions.isEmpty {
            args.append("--ignore-missing")
            args += revisions
        }
        // `--grep` / `--author` read commit headers; `-S` / `-G` diff every
        // commit against its parent, which on a large repo is minutes of
        // work and was hitting the default two-minute budget. The UI can
        // cancel a search now, so give the pickaxe a budget it can
        // actually finish in.
        let timeout: TimeInterval = mode.walksDiffs ? 600 : 120
        let r = try await runner.run(in: repoPath, args: args, timeout: timeout)
        try ensureSucceeded(r)
        return GitOutputParser.parseLog(r.stdout)
    }

    /// Commit history for a single file (`git log --follow -- <path>`),
    /// newest first. `--follow` keeps the history across renames, matching
    /// the "Show File History" / "Log selected file" feature in Fork and
    /// SmartGit. Same format as `log()` so the shared parser applies.
    /// Note: `--follow` requires a single pathspec, hence one `path`.
    func fileHistory(repoPath: String, path: String, count: Int = 200) async throws -> [GitCommit] {
        let fmt = "%H%x00%h%x00%s%x00%an%x00%ae%x00%aI%x00%D%x00%P"
        let args = ["log", "--follow", "--format=\(fmt)", "-n", "\(count)", "--", path]
        let r = try await runner.run(in: repoPath, args: args)
        try ensureSucceeded(r)
        return GitOutputParser.parseLog(r.stdout)
    }

    /// Line-by-line authorship for a file (`git blame --line-porcelain`).
    /// Works on tracked, committed files; throws for untracked paths.
    func blame(repoPath: String, path: String) async throws -> [GitBlameLine] {
        let r = try await runner.run(in: repoPath, args: ["blame", "--line-porcelain", "--", path])
        try ensureSucceeded(r)
        return GitOutputParser.parseBlame(r.stdout)
    }

    /// Revision history for one final-file line (`git log -L`), used by
    /// the blame view's "History of current line" pane.
    func blameLineHistory(repoPath: String, path: String, line: Int) async throws -> String {
        let spec = "\(line),\(line):\(path)"
        let r = try await runner.run(in: repoPath, args: [
            "log", "--no-color", "--date=short",
            "--format=commit %h  %ad  %an%n%s",
            "-L", spec
        ])
        try ensureSucceeded(r)
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Diff

    /// Context lines passed to `--unified` to render the *whole* file
    /// around the changes (the non-compact "full file" view). Any value
    /// larger than the file's line count yields full-file context; git
    /// clamps it, so a single large constant is safe for any file.
    static let fullFileContextLines = 100_000

    func diff(
        repoPath: String,
        file: String?,
        mode: DiffCompareMode = .indexVsWorkingTree,
        ignoreWhitespace: Bool = false,
        fullFile: Bool = false
    ) async throws -> [DiffHunk] {
        var args = ["diff"]
        switch mode {
        case .headVsIndex:        args.append("--cached")
        case .indexVsWorkingTree: break
        }
        if ignoreWhitespace { args.append("-w") }
        if fullFile { args.append("--unified=\(Self.fullFileContextLines)") }
        args.append("--no-color")
        if let file { args += ["--", file] }
        let r = try await runner.run(in: repoPath, args: args)
        try ensureSucceeded(r)
        return GitOutputParser.parseDiff(r.stdout)
    }

    /// Diff an untracked file against `/dev/null` so the Diff panel can
    /// show its full content as an "added" change. Required because plain
    /// `git diff` skips files not in the index.
    ///
    /// `git diff --no-index` exits with status 1 whenever differences
    /// exist (which they always do here) — we explicitly don't treat
    /// that as a failure.
    func untrackedDiff(
        repoPath: String,
        file: String,
        ignoreWhitespace: Bool = false
    ) async throws -> [DiffHunk] {
        var args = ["diff", "--no-index", "--no-color"]
        if ignoreWhitespace { args.append("-w") }
        args += ["--", "/dev/null", file]
        let r = try await runner.run(in: repoPath, args: args)
        // Exit codes 0 (no diff — impossible here) and 1 (has diff) are
        // both success. Anything else is a real failure (binary file,
        // permission denied, …).
        if r.exitCode > 1 {
            throw GitServiceError.gitFailed(
                command: r.command,
                exitCode: r.exitCode,
                stderr: r.stderr
            )
        }
        return GitOutputParser.parseDiff(r.stdout)
    }

    /// Diffs a conflicted file's working tree against `HEAD`. We use HEAD
    /// rather than the index because the index for a conflicted file holds
    /// stages 1/2/3 (base/ours/theirs) instead of the usual single staged
    /// blob, and `git diff` against that produces empty/combined output.
    /// Diffing against HEAD surfaces the merge-marker block (`<<<<<<<`,
    /// `=======`, `>>>>>>>`) as additions — the SmartGit-style preview.
    func conflictDiff(
        repoPath: String,
        file: String,
        ignoreWhitespace: Bool = false,
        fullFile: Bool = false
    ) async throws -> [DiffHunk] {
        var args = ["diff", "HEAD", "--no-color"]
        if ignoreWhitespace { args.append("-w") }
        if fullFile { args.append("--unified=\(Self.fullFileContextLines)") }
        args += ["--", file]
        let r = try await runner.run(in: repoPath, args: args)
        try ensureSucceeded(r)
        return GitOutputParser.parseDiff(r.stdout)
    }

    // MARK: - Index actions

    @discardableResult
    func stage(repoPath: String, files: [String]) async throws -> GitCommandResult {
        let r = try await runner.run(in: repoPath, args: ["add", "--"] + files)
        try ensureSucceeded(r)
        return r
    }

    @discardableResult
    func unstage(repoPath: String, files: [String]) async throws -> GitCommandResult {
        let r = try await runner.run(in: repoPath, args: ["reset", "HEAD", "--"] + files)
        try ensureSucceeded(r)
        return r
    }

    @discardableResult
    func discard(repoPath: String, files: [String]) async throws -> GitCommandResult {
        let r = try await runner.run(in: repoPath, args: ["checkout", "--"] + files)
        try ensureSucceeded(r)
        return r
    }

    /// Throw away a conflicted file's merge and take HEAD's version.
    ///
    /// `discard` cannot do this: `git checkout -- <path>` restores from the
    /// index, and a conflicted path has no single index entry to restore from
    /// — git answers "path ... is unmerged" and, because it validates every
    /// pathspec before touching anything, the whole command becomes a no-op.
    /// Naming HEAD as the source both works and clears the unmerged stages,
    /// which is what discarding a conflict has to mean.
    @discardableResult
    func discardConflicted(repoPath: String, files: [String]) async throws -> GitCommandResult {
        let r = try await runner.run(in: repoPath, args: ["checkout", "HEAD", "--"] + files)
        try ensureSucceeded(r)
        return r
    }

    /// Re-creates the conflict on paths git has stopped calling unmerged.
    ///
    /// `git reset` on an unmerged path collapses its three stages back to a
    /// single entry matching HEAD. The working tree keeps its markers, but the
    /// conflict is gone as far as git is concerned: the Files panel shows an
    /// ordinary modification, the resolver has no stages left to read, and
    /// `rebase --continue` refuses — over the unstaged change, while saying
    /// the problem is a conflict to resolve. Nothing in git's own advice gets
    /// the user out of that.
    ///
    /// `git checkout -m` does: it redoes the three-way merge from the paused
    /// operation's own heads, restoring both the stages and the markers.
    ///
    /// Destructive to hand edits, like `restoreConflictMarkersWithAncestor` —
    /// the file is rebuilt from the merge, so anything typed into it since is
    /// replaced. Callers confirm first.
    @discardableResult
    func restoreConflict(repoPath: String, files: [String]) async throws -> GitCommandResult {
        let r = try await runner.run(in: repoPath, args: ["checkout", "-m", "--"] + files)
        try ensureSucceeded(r)
        return r
    }

    /// Remove untracked files (`git clean -f -d`). `git checkout --` (used by
    /// `discard`) only restores *tracked* files, so deleting untracked work
    /// needs `clean`. Ignored files are left alone (no `-x`), matching Fork's
    /// default "Clean" behaviour. Pass specific `paths` to scope the clean to
    /// a selection; empty cleans the whole working tree.
    ///
    /// - Parameter includeIgnored: Adds `-x`, without which `clean` skips an
    ///   ignored path even when it is named explicitly. Honoured only
    ///   alongside `paths` — a repo-wide `clean -xfd` deletes every build
    ///   product and local config in the tree, which is never what a caller
    ///   here is asking for.
    @discardableResult
    func cleanUntracked(
        repoPath: String,
        paths: [String] = [],
        includeIgnored: Bool = false
    ) async throws -> GitCommandResult {
        var args = ["clean", "-f", "-d"]
        if includeIgnored && !paths.isEmpty { args.append("-x") }
        if !paths.isEmpty { args += ["--"] + paths }
        let r = try await runner.run(in: repoPath, args: args)
        try ensureSucceeded(r)
        return r
    }

    @discardableResult
    func commit(
        repoPath: String,
        subject: String,
        body: String? = nil,
        amend: Bool = false
    ) async throws -> GitCommandResult {
        var args = ["commit"]
        if amend { args.append("--amend") }
        args += ["-m", subject]
        if let body, !body.isEmpty { args += ["-m", body] }
        let r = try await runner.run(in: repoPath, args: args)
        try ensureSucceeded(r)
        return r
    }

    /// `git commit --fixup=<hash>`: commit the staged changes as a fixup
    /// of `hash`. The commit's subject becomes "fixup! <target subject>",
    /// which a later autosquash rebase folds into the target without a
    /// message prompt. Fails (exit ≠ 0) when nothing is staged — the
    /// caller surfaces git's own message.
    @discardableResult
    func commitFixup(repoPath: String, targetHash: String) async throws -> GitCommandResult {
        let r = try await runner.run(in: repoPath, args: ["commit", "--fixup=\(targetHash)"])
        try ensureSucceeded(r)
        return r
    }

    /// `git rebase -i --autosquash <base>` with the todo accepted as
    /// generated: reorders every `fixup!` / `squash!` commit directly
    /// after its target and folds it in. `GIT_SEQUENCE_EDITOR=true` exits
    /// 0 without touching the todo, so no editor ever opens; conflicts
    /// pause the rebase exactly like `runInteractiveRebase`.
    /// `base` of `"--root"` rebases the whole history — the only way to
    /// include the root commit, which has no `<hash>^` to name.
    @discardableResult
    func autosquashRebase(repoPath: String, base: String) async throws -> GitCommandResult {
        try await runAutostashing(
            in: repoPath,
            args: base == "--root"
                ? ["rebase", "-i", "--autosquash", "--autostash", "--root"]
                : ["rebase", "-i", "--autosquash", "--autostash", base],
            env: [
                "GIT_SEQUENCE_EDITOR": "true",
                "GIT_EDITOR": "true"
            ]
        )
    }

    // MARK: - Remote ops

    @discardableResult
    // MARK: - Credentials

    /// Whether git has a credential helper configured to store passwords in.
    ///
    /// Without one, `git credential approve` accepts the credentials and
    /// quietly forgets them, and the next pull asks again.
    ///
    /// `repoPath` is optional because a clone hits the credentials wall
    /// before there is a repository to ask from. With nil, git answers from
    /// global and system config — which is where the helper belongs anyway.
    func credentialHelper(repoPath: String?) async throws -> String? {
        let result = try await runner.run(
            in: repoPath, args: ["config", "--get", "credential.helper"]
        )
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Configures the macOS keychain as the global credential helper.
    ///
    /// `osxkeychain` ships with both Apple's git and Homebrew's, and is
    /// where the git CLI, Xcode and every other Mac git client already look
    /// — so a password saved here works outside this app too.
    @discardableResult
    func useKeychainCredentialHelper(repoPath: String? = nil) async throws -> GitCommandResult {
        try await runner.run(
            in: repoPath,
            args: ["config", "--global", "credential.helper", "osxkeychain"]
        )
    }

    /// Hands a username and password to the configured helper.
    ///
    /// `git credential approve` rather than writing to the keychain
    /// directly: git decides the storage format, and going through it is
    /// what guarantees git can read the entry back.
    @discardableResult
    func approveCredential(
        repoPath: String?,
        scheme: String,
        host: String,
        username: String,
        password: String
    ) async throws -> GitCommandResult {
        try await runner.run(
            in: repoPath,
            args: ["credential", "approve"],
            stdin: GitCredentials.credentialInput(
                scheme: scheme, host: host, username: username, password: password
            )
        )
    }

    /// Pull, stashing any local changes for the duration.
    ///
    /// Without `--autostash` git refuses outright — "cannot pull with
    /// rebase: You have unstaged changes" — and the user has to stash,
    /// pull and pop by hand for what is the ordinary state of a working
    /// tree. git's own autostash does exactly that dance, and keeps the
    /// stash when it can't reapply cleanly, so nothing is ever lost.
    ///
    /// Note it exits 0 even when the reapply conflicts; the caller has to
    /// read the output to know. See `GitOutputParser.autostashOutcome`.
    ///
    /// `--prune` for the same reason `fetch` has it: once the upstream is
    /// deleted on the remote (merged and removed with its MR), the pull
    /// fails with "no such ref was fetched" — and without pruning the stale
    /// remote-tracking ref survives, so the branch never shows as `[gone]`.
    func pull(repoPath: String, rebase: Bool = false, autostash: Bool = true) async throws -> GitCommandResult {
        var args = ["pull", "--prune"]
        if rebase { args.append("--rebase") }
        if autostash { args.append("--autostash") }
        // Network operation: opt out of the run() timeout so a large
        // transfer or slow link isn't force-terminated mid-flight.
        return try await runAutostashing(in: repoPath, args: args, timeout: 0)
    }

    /// Run a command that carries `--autostash`, dropping the flag and
    /// trying again if this git doesn't know it.
    ///
    /// Merge-mode autostash needs git 2.27. Rather than gate on a version,
    /// notice the refusal and go again without it: the user then gets
    /// git's own "commit or stash" message — the pre-autostash behaviour —
    /// instead of a command that fails on a flag.
    private func runAutostashing(
        in repoPath: String,
        args: [String],
        env: [String: String]? = nil,
        timeout: TimeInterval = 120
    ) async throws -> GitCommandResult {
        let result = try await runner.run(in: repoPath, args: args, env: env, timeout: timeout)
        guard !result.succeeded, Self.rejectedAutostash(result) else { return result }
        return try await runner.run(
            in: repoPath,
            args: args.filter { $0 != "--autostash" },
            env: env,
            timeout: timeout
        )
    }

    private nonisolated static func rejectedAutostash(_ result: GitCommandResult) -> Bool {
        let text = result.combinedOutput.lowercased()
        return text.contains("autostash") &&
            (text.contains("unknown option") || text.contains("unknown switch"))
    }

    @discardableResult
    func push(repoPath: String, force: Bool = false, tags: Bool = false) async throws -> GitCommandResult {
        var args = ["push"]
        if force { args.append("--force-with-lease") }
        if tags { args.append("--tags") }
        return try await runner.run(in: repoPath, args: args, timeout: 0)
    }

    @discardableResult
    func fetch(repoPath: String, prune: Bool = true) async throws -> GitCommandResult {
        var args = ["fetch", "--all"]
        if prune { args.append("--prune") }
        return try await runner.run(in: repoPath, args: args, timeout: 0)
    }

    /// Clone `remoteURL` into `destinationParent`/`folderName`. Runs in the
    /// destination's parent directory so git resolves the target path
    /// itself. Returns the absolute path of the resulting working tree on
    /// success.
    @discardableResult
    func clone(
        remoteURL: String,
        destinationParent: String,
        folderName: String
    ) async throws -> (result: GitCommandResult, clonedPath: String) {
        let result = try await runner.run(
            in: destinationParent,
            args: ["clone", remoteURL, folderName],
            timeout: 0
        )
        let cloned = (destinationParent as NSString).appendingPathComponent(folderName)
        return (result, cloned)
    }

    /// Pushes a specific local branch to a specific remote / remote ref,
    /// independent of whatever upstream is currently configured. Used by
    /// the "Push To…" context-menu item.
    ///
    /// Refspec form: `<local>:<remote>` when `remoteBranch` is non-nil,
    /// otherwise just `<local>` (git resolves it against `push.default`).
    @discardableResult
    func pushTo(
        repoPath: String,
        remote: String,
        localBranch: String,
        remoteBranch: String? = nil,
        force: Bool = false,
        setUpstream: Bool = false,
        tags: Bool = false
    ) async throws -> GitCommandResult {
        try await runner.run(
            in: repoPath,
            args: Self.pushToArguments(
                remote: remote,
                localBranch: localBranch,
                remoteBranch: remoteBranch,
                force: force,
                setUpstream: setUpstream,
                tags: tags
            ),
            timeout: 0
        )
    }

    /// The argv `pushTo` runs, built apart from running it so a
    /// confirmation dialog can show the user the exact command first. A
    /// push that has to be spelled out is one the user should see spelled
    /// out — doubly so with `--force-with-lease` in it.
    static func pushToArguments(
        remote: String,
        localBranch: String,
        remoteBranch: String? = nil,
        force: Bool = false,
        setUpstream: Bool = false,
        tags: Bool = false
    ) -> [String] {
        var args = ["push"]
        if setUpstream { args.append("--set-upstream") }
        if force { args.append("--force-with-lease") }
        if tags { args.append("--tags") }
        args.append(remote)
        if let remoteBranch, !remoteBranch.isEmpty {
            args.append("\(localBranch):\(remoteBranch)")
        } else {
            args.append(localBranch)
        }
        return args
    }

    /// Where `branch` pushes: the remote it tracks, and its name *on that
    /// remote*. Nil when the branch tracks nothing, or tracks another local
    /// branch (`branch.<name>.remote = .`), which no `git push` can address.
    ///
    /// Read from `branch.<name>.remote` / `.merge` rather than split out of
    /// `%(upstream:short)`: that string is `<remote>/<branch>` with no way
    /// back — a remote name may contain a slash and so may a branch name —
    /// while `.merge` holds the remote-side ref verbatim.
    func upstreamOfBranch(
        repoPath: String,
        branch: String
    ) async throws -> (remote: String, branch: String)? {
        guard let remote = try await configValue(
            repoPath: repoPath,
            key: "branch.\(branch).remote",
            scope: .local
        ), remote != "." else { return nil }
        guard let merge = try await configValue(
            repoPath: repoPath,
            key: "branch.\(branch).merge",
            scope: .local
        ) else { return nil }
        let headsPrefix = "refs/heads/"
        let name = merge.hasPrefix(headsPrefix)
            ? String(merge.dropFirst(headsPrefix.count))
            : merge
        return name.isEmpty ? nil : (remote, name)
    }

    // MARK: - Config (user.name / user.email and friends)

    /// Read a single `git config` value. Returns nil when the key
    /// isn't set at the requested scope — `git config` exits 1 in
    /// that case, which is the normal "absent" signal and not an
    /// error.
    ///
    /// - Parameter scope: `.local` reads from the repo's
    ///   `.git/config`; `.global` reads from `~/.gitconfig`.
    func configValue(
        repoPath: String?,
        key: String,
        scope: ConfigScope
    ) async throws -> String? {
        var args = ["config", "--get"]
        switch scope {
        case .local:  break
        case .global: args.append("--global")
        }
        args.append(key)
        let r = try await runner.run(in: scope == .local ? repoPath : nil, args: args)
        if r.exitCode == 1 { return nil }
        try ensureSucceeded(r)
        let value = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Write `value` to a `git config` key at `scope`. Empty values
    /// are not allowed; pass through `unsetConfigValue` to clear a
    /// key instead.
    @discardableResult
    func setConfigValue(
        repoPath: String?,
        key: String,
        value: String,
        scope: ConfigScope
    ) async throws -> GitCommandResult {
        var args = ["config"]
        switch scope {
        case .local:  break
        case .global: args.append("--global")
        }
        args += [key, value]
        let r = try await runner.run(in: scope == .local ? repoPath : nil, args: args)
        try ensureSucceeded(r)
        return r
    }

    /// Remove a key from the requested scope. Useful for repo-local
    /// overrides — clearing the local `user.name` falls back to the
    /// global value for that repo.
    @discardableResult
    func unsetConfigValue(
        repoPath: String?,
        key: String,
        scope: ConfigScope
    ) async throws -> GitCommandResult {
        var args = ["config", "--unset"]
        switch scope {
        case .local:  break
        case .global: args.append("--global")
        }
        args.append(key)
        let r = try await runner.run(in: scope == .local ? repoPath : nil, args: args)
        // Exit code 5 = key not set; treat as success (already absent).
        if r.exitCode == 5 { return r }
        try ensureSucceeded(r)
        return r
    }


    /// Run `git init` in `path`, optionally setting an initial branch
    /// name (matches modern git's `--initial-branch` flag — default
    /// `main` if the user leaves it empty). Used by the
    /// Init-Repository sheet when the user drags in a non-git folder.
    @discardableResult
    func initRepository(at path: String, initialBranch: String = "main") async throws -> GitCommandResult {
        let r = try await runner.run(
            in: nil,
            args: ["init", "--initial-branch=\(initialBranch)", path]
        )
        try ensureSucceeded(r)
        return r
    }

    /// Register a new remote pointing at `url` (defaults to `origin`).
    /// Companion to `initRepository` for the "init + link to host"
    /// flow — no-op if the user leaves the URL blank in the sheet.
    @discardableResult
    func addRemote(repoPath: String, name: String = "origin", url: String) async throws -> GitCommandResult {
        let r = try await runner.run(
            in: repoPath,
            args: ["remote", "add", name, url]
        )
        try ensureSucceeded(r)
        return r
    }

    /// Names of configured remotes (one per line from `git remote`).
    func remotes(repoPath: String) async throws -> [String] {
        let r = try await runner.run(in: repoPath, args: ["remote"])
        try ensureSucceeded(r)
        return r.stdout
            .split(whereSeparator: { $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Read destinations locally, without contacting any remote. Asking Git
    /// for the URLs also applies insteadOf/pushInsteadOf configuration.
    func remoteDetails(repoPath: String) async throws -> [GitRemote] {
        var details: [GitRemote] = []
        for name in try await remotes(repoPath: repoPath) {
            let fetch = try await runner.run(in: repoPath, args: ["remote", "get-url", "--all", name])
            try ensureSucceeded(fetch)
            let push = try await runner.run(in: repoPath, args: ["remote", "get-url", "--push", "--all", name])
            try ensureSucceeded(push)
            details.append(GitRemote(
                name: name,
                fetchURLs: fetch.stdout.split(separator: "\n").map(String.init),
                pushURLs: push.stdout.split(separator: "\n").map(String.init)
            ))
        }
        return details.sorted {
            if ($0.name == "origin") != ($1.name == "origin") { return $0.name == "origin" }
            return $0.name.naturallyPrecedes($1.name)
        }
    }

    /// Sets `<branch>`'s upstream to `<upstream>` (e.g. "origin/main").
    /// `git branch --set-upstream-to=<upstream> <branch>`.
    @discardableResult
    func setUpstream(repoPath: String, branch: String, upstream: String) async throws -> GitCommandResult {
        try await runner.run(in: repoPath, args: [
            "branch", "--set-upstream-to=\(upstream)", branch
        ])
    }

    /// Removes the upstream tracking config for `<branch>`.
    @discardableResult
    func unsetUpstream(repoPath: String, branch: String) async throws -> GitCommandResult {
        try await runner.run(in: repoPath, args: [
            "branch", "--unset-upstream", branch
        ])
    }

    // MARK: - File compare

    /// Reads a file's contents as recorded in `HEAD`. Returns nil if
    /// the file isn't tracked at HEAD (newly added in the working
    /// tree, or never committed) — callers should render an
    /// "(untracked)" placeholder rather than an error.
    func fileAtHead(repoPath: String, path: String) async throws -> String? {
        try await fileAtRevision(repoPath: repoPath, revision: "HEAD", path: path)
    }

    /// Reads a file's contents as recorded at the given revision (commit
    /// hash, branch name, `HEAD~1`, etc.). Returns nil if the file didn't
    /// exist at that revision — used by the external diff tool to feed
    /// "before" / "after" temp files for arbitrary commits.
    func fileAtRevision(repoPath: String, revision: String, path: String) async throws -> String? {
        let r = try await runner.run(in: repoPath, args: ["show", "\(revision):\(path)"])
        return r.exitCode == 0 ? r.stdout : nil
    }

    // MARK: - Conflict resolution


    /// Reads one of the three blob versions git records for a conflicted
    /// file. Used by the 3-pane resolver to populate ours/theirs/base
    /// panes without touching the working tree. Returns nil when that
    /// stage doesn't exist (e.g. add/add conflicts have no base).
    func conflictVersion(repoPath: String, path: String, side: ConflictSide) async throws -> String? {
        let r = try await runner.run(in: repoPath, args: ["show", ":\(side.rawValue):\(path)"])
        // Missing stage isn't an error in our UX — return nil so the
        // pane can show "(no base)" instead of crashing.
        guard r.exitCode == 0 else { return nil }
        return r.stdout
    }

    /// Which index stages exist for a conflicted path (`git ls-files -u`).
    ///
    /// A plain content conflict has all three; a modify/delete has only
    /// the ancestor plus the side that kept the file. Asking first is
    /// what keeps `acceptOurs` from running a checkout git will refuse
    /// with "path 'x' does not have our version".
    func conflictStages(repoPath: String, path: String) async throws -> Set<Int> {
        let r = try await runner.run(in: repoPath, args: ["ls-files", "-u", "-z", "--", path])
        guard r.succeeded else { return [] }
        var stages: Set<Int> = []
        for record in r.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            // "<mode> <sha> <stage>\t<path>"
            let s = String(record)
            guard let tab = s.firstIndex(of: "\t") else { continue }
            let meta = s[..<tab].split(separator: " ")
            guard meta.count >= 3, let stage = Int(meta[2]) else { continue }
            stages.insert(stage)
        }
        return stages
    }

    /// Resolves a conflict by taking one whole side of it.
    ///
    /// For a content conflict that means checking that side's blob out
    /// over the working tree and staging it. For a modify/delete there
    /// is no blob on the deleted side, and the only thing "take the side
    /// that deleted it" can mean is finishing the delete — `git rm`,
    /// which both removes the file and resolves the index entry. Doing
    /// it the checkout way fails outright, which is what used to happen.
    private func acceptSide(
        repoPath: String,
        path: String,
        sideStage: Int,
        flag: String
    ) async throws -> GitCommandResult {
        let stages = try await conflictStages(repoPath: repoPath, path: path)
        // An empty set means git reports no unmerged entry — the path is
        // not conflicted, or it was resolved under us. Fall through to the
        // checkout so the caller still gets git's own diagnosis.
        if !stages.isEmpty, !stages.contains(sideStage) {
            return try await runner.run(in: repoPath, args: ["rm", "--", path])
        }
        let co = try await runner.run(in: repoPath, args: ["checkout", flag, "--", path])
        try ensureSucceeded(co)
        return try await stage(repoPath: repoPath, files: [path])
    }

    /// Resolves a conflict by replacing the file with the current
    /// branch's version, then staging it — or, when the current branch
    /// deleted the file, by completing that deletion.
    @discardableResult
    func acceptOurs(repoPath: String, path: String) async throws -> GitCommandResult {
        let r = try await acceptSide(repoPath: repoPath, path: path, sideStage: 2, flag: "--ours")
        try ensureSucceeded(r)
        return r
    }

    /// Resolves a conflict by replacing the file with the incoming
    /// branch's version, then staging it — or, when the incoming branch
    /// deleted the file, by completing that deletion.
    @discardableResult
    func acceptTheirs(repoPath: String, path: String) async throws -> GitCommandResult {
        let r = try await acceptSide(repoPath: repoPath, path: path, sideStage: 3, flag: "--theirs")
        try ensureSucceeded(r)
        return r
    }

    /// Stages whatever the working tree currently contains as the
    /// resolution. Used after the user manually edited the file to
    /// remove conflict markers.
    @discardableResult
    func markResolved(repoPath: String, path: String) async throws -> GitCommandResult {
        try await stage(repoPath: repoPath, files: [path])
    }

    /// Aborts an in-progress merge / rebase / cherry-pick, restoring
    /// the working tree to the pre-merge state. Tries `--abort` for
    /// each operation type and swallows non-matching errors.
    @discardableResult
    /// Rewrites a conflicted file's markers to include the common ancestor.
    ///
    /// git's default `merge.conflictStyle` writes only ours and theirs, so the
    /// ancestor is simply absent from the file even though it sits in stage 1
    /// of the index. This regenerates the markers from those stages in diff3
    /// style, adding the `|||||||` section — the file stays conflicted and
    /// unstaged, it just gains the third side.
    ///
    /// Destructive to hand edits: the file is rebuilt from the index, so any
    /// manual editing of the conflicted file is replaced by fresh markers.
    /// Callers must confirm first.
    func restoreConflictMarkersWithAncestor(repoPath: String, path: String) async throws -> GitCommandResult {
        try await runner.run(in: repoPath, args: ["checkout", "--conflict=diff3", "--", path])
    }

    // MARK: - Submodules

    /// Every submodule the parent repository records, with its state.
    ///
    /// `--recursive` is deliberately absent. Nested submodules belong to the
    /// submodule that owns them, and flattening them into the parent's list
    /// hides which repository is actually responsible for a given pointer —
    /// open the submodule as a repository and its own list is right there.
    func submodules(repoPath: String) async -> [GitSubmodule] {
        // Empty rather than an error for a repository with no submodules,
        // which is nearly all of them. `git submodule status` succeeds with no
        // output there, and treating "none" as a failure would put an error in
        // the log on every refresh of every ordinary repository.
        let status = try? await runner.run(in: repoPath, args: ["submodule", "status"])
        guard let status, status.succeeded, !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let modulesPath = (repoPath as NSString).appendingPathComponent(".gitmodules")
        let gitmodules = (try? String(contentsOfFile: modulesPath, encoding: .utf8)) ?? ""
        return GitOutputParser.mergeSubmodules(status: status.stdout, gitmodules: gitmodules)
    }

    /// The commits behind a moved submodule pointer.
    ///
    /// `git diff` answers this with two SHAs and nothing else, and
    /// `--submodule=log` answers it with subject lines only. Both readings
    /// come from the same two commits, so this fetches them once and reads
    /// the log inside the submodule itself, which is where the authors and
    /// dates live.
    ///
    /// Returns nil when `path` is not a submodule the index knows about.
    func submoduleChange(repoPath: String, path: String) async -> SubmoduleChange? {
        // `rev-parse :path` reads the gitlink straight out of the index,
        // which is the commit a `git commit` right now would keep. Using
        // HEAD's would answer a different question whenever the pointer
        // change is already staged.
        guard let recorded = try? await runner.run(
            in: repoPath, args: ["rev-parse", ":\(path)"]
        ), recorded.succeeded else { return nil }
        let recordedSHA = recorded.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recordedSHA.isEmpty else { return nil }

        let submodulePath = (repoPath as NSString).appendingPathComponent(path)
        let head = try? await runner.run(
            in: submodulePath, args: ["rev-parse", "HEAD"]
        )
        let currentSHA = (head?.succeeded ?? false)
            ? head?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        guard let currentSHA, !currentSHA.isEmpty, currentSHA != recordedSHA else {
            let dirty = await dirtyFiles(submodulePath: submodulePath)
            return SubmoduleChange(
                path: path,
                recorded: recordedSHA,
                current: currentSHA?.isEmpty == true ? nil : currentSHA,
                recordedCommit: await commit(sha: recordedSHA, in: submodulePath),
                currentCommit: await commit(sha: recordedSHA, in: submodulePath),
                added: [],
                removed: [],
                dirtyFiles: dirty,
                hasModifiedContent: dirty.contains { $0.state != .untracked },
                hasUntrackedContent: dirty.contains { $0.state == .untracked }
            )
        }

        async let added = rangeLog(in: submodulePath, from: recordedSHA, to: currentSHA)
        async let removed = rangeLog(in: submodulePath, from: currentSHA, to: recordedSHA)
        async let recordedCommit = commit(sha: recordedSHA, in: submodulePath)
        async let currentCommit = commit(sha: currentSHA, in: submodulePath)
        async let dirty = dirtyFiles(submodulePath: submodulePath)

        let inner = await dirty
        return SubmoduleChange(
            path: path,
            recorded: recordedSHA,
            current: currentSHA,
            recordedCommit: await recordedCommit,
            currentCommit: await currentCommit,
            added: await added,
            removed: await removed,
            dirtyFiles: inner,
            hasModifiedContent: inner.contains { $0.state != .untracked },
            hasUntrackedContent: inner.contains { $0.state == .untracked }
        )
    }

    /// Commits reachable from `to` but not from `from`, newest first.
    /// Empty when either commit is missing from the submodule's object
    /// store, which happens to a pointer that was fetched but never pulled.
    private func rangeLog(in submodulePath: String, from: String, to: String) async -> [GitCommit] {
        (try? await log(repoPath: submodulePath, count: 200, revisions: ["\(from)..\(to)"])) ?? []
    }

    /// One commit, read from the submodule's own object store. Nil when it
    /// does not have it — a pointer can name a commit that was never
    /// fetched, and that is a state to show rather than an error to throw.
    private func commit(sha: String, in submodulePath: String) async -> GitCommit? {
        (try? await log(repoPath: submodulePath, count: 1, revisions: [sha]))?.first
    }

    /// Uncommitted work inside the submodule, as status rows of its own.
    private func dirtyFiles(submodulePath: String) async -> [GitFileStatus] {
        let result = try? await runner.run(
            in: submodulePath,
            args: ["status", "--porcelain=v2", "-z", "--untracked-files=all"]
        )
        guard let result, result.succeeded else { return [] }
        return GitOutputParser.parseStatus(result.stdout)
    }

    /// Clones and checks out submodules that aren't initialised yet.
    ///
    /// `--init` alongside `update` because they are one step in practice:
    /// nobody wants a registered-but-empty submodule, and requiring two
    /// commands to get a working checkout is the most common submodule
    /// complaint there is.
    func updateSubmodules(repoPath: String, paths: [String] = [], recursive: Bool = true) async throws -> GitCommandResult {
        var args = ["submodule", "update", "--init"]
        if recursive { args.append("--recursive") }
        if !paths.isEmpty {
            args.append("--")
            args.append(contentsOf: paths)
        }
        // Cloning a large submodule over the network takes far longer than the
        // default two minutes allows.
        return try await runner.run(in: repoPath, args: args, timeout: 900)
    }

    /// Removes a submodule's working tree, keeping its registration.
    func deinitSubmodule(repoPath: String, path: String, force: Bool) async throws -> GitCommandResult {
        var args = ["submodule", "deinit"]
        if force { args.append("--force") }
        args.append(contentsOf: ["--", path])
        return try await runner.run(in: repoPath, args: args)
    }

    /// Rewrites each submodule's configured remote URL from `.gitmodules`.
    /// Needed after the upstream moves host.
    func syncSubmodules(repoPath: String, recursive: Bool = true) async throws -> GitCommandResult {
        var args = ["submodule", "sync"]
        if recursive { args.append("--recursive") }
        return try await runner.run(in: repoPath, args: args)
    }

    /// Registers a new submodule and clones it.
    func addSubmodule(repoPath: String, url: String, path: String) async throws -> GitCommandResult {
        try await runner.run(
            in: repoPath,
            args: ["submodule", "add", "--", url, path],
            timeout: 900
        )
    }

    func abortMerge(repoPath: String) async throws -> GitCommandResult {
        try await runner.run(in: repoPath, args: ["merge", "--abort"])
    }


    /// All five markers are per-worktree, so this reads `layout.gitDir` —
    /// the linked worktree's own directory — rather than `<repo>/.git`. That
    /// path is a *file* in a worktree, so every check under it answered `no`
    /// and a paused rebase read as nothing in progress: no banner, no guard
    /// on the pull that left it paused, and a push straight into git's
    /// "You are not currently on a branch".
    func inProgressOperation(repoPath: String) async -> InProgressOperation? {
        let layout = await layout(repoPath: repoPath)
        let fm = FileManager.default
        if fm.fileExists(atPath: layout.gitPath("MERGE_HEAD"))        { return .merge }
        if fm.fileExists(atPath: layout.gitPath("rebase-merge"))      { return .rebase }
        if fm.fileExists(atPath: layout.gitPath("rebase-apply"))      { return .rebase }
        if fm.fileExists(atPath: layout.gitPath("CHERRY_PICK_HEAD"))  { return .cherryPick }
        if fm.fileExists(atPath: layout.gitPath("REVERT_HEAD"))       { return .revert }
        return nil
    }

    /// Continues whichever operation is paused. For merge that means
    /// completing the synthetic merge commit (git uses `commit` with
    /// the prepared `MERGE_MSG`). For rebase/cherry-pick/revert each
    /// has its own `--continue` flag.
    ///
    /// `-c core.editor=true` forces git to accept the pre-composed
    /// commit message instead of spawning $EDITOR — otherwise the
    /// subprocess would hang waiting for vim.
    @discardableResult
    func continueOperation(repoPath: String, operation: InProgressOperation) async throws -> GitCommandResult {
        if operation == .revert, await uncommittedRevert(repoPath: repoPath) != nil {
            // Git's single-commit `revert --continue` commits the resolution
            // even when the original command used --no-commit. Once every
            // conflict is staged, forget the operation and keep its changes
            // in the index, exactly as a conflict-free no-commit revert does.
            let unresolved = try await runner.run(
                in: repoPath, args: ["diff", "--name-only", "--diff-filter=U", "-z"]
            )
            try ensureSucceeded(unresolved)
            guard unresolved.stdout.isEmpty else {
                return .outcome("Finish Revert without committing", failure: "Resolve and stage all conflicts before finishing the revert.")
            }
            let result = try await runner.run(in: repoPath, args: ["revert", "--quit"])
            if result.succeeded { await clearUncommittedRevert(repoPath: repoPath) }
            return result
        }
        if operation == .rebase { return try await continueRebase(repoPath: repoPath) }
        let tail: [String]
        switch operation {
        case .merge:      tail = ["commit", "--no-edit"]
        case .rebase:     tail = ["rebase", "--continue"]
        case .cherryPick: tail = ["cherry-pick", "--continue"]
        case .revert:     tail = ["revert", "--continue"]
        }
        return try await runner.run(
            in: repoPath,
            args: ["-c", "core.editor=true"] + tail
        )
    }

    /// Aborts whichever operation is paused.
    @discardableResult
    func abortOperation(repoPath: String, operation: InProgressOperation) async throws -> GitCommandResult {
        if operation == .revert, let pending = await uncommittedRevert(repoPath: repoPath) {
            // A no-commit revert accepts an already-dirty index. Git's
            // `revert --abort` resets it to HEAD, losing that earlier staged
            // work. Restore only the paths changed since the saved index;
            // unrelated staged and unstaged files stay as they were.
            let paths = try await runner.run(in: repoPath, args: [
                "diff", "--cached", "--name-only", "--no-renames", "-z", pending.indexTree, "--"
            ])
            try ensureSucceeded(paths)
            if !paths.stdout.isEmpty {
                let restored = try await runner.run(in: repoPath, args: [
                    "--literal-pathspecs", "restore", "--source=\(pending.indexTree)",
                    "--staged", "--worktree", "--pathspec-from-file=-", "--pathspec-file-nul"
                ], stdin: paths.stdout)
                guard restored.succeeded else { return restored }
            }
            let result = try await runner.run(in: repoPath, args: ["revert", "--quit"])
            if result.succeeded { await clearUncommittedRevert(repoPath: repoPath) }
            return result
        }
        let args: [String]
        switch operation {
        case .merge:      args = ["merge", "--abort"]
        case .rebase:     args = ["rebase", "--abort"]
        case .cherryPick: args = ["cherry-pick", "--abort"]
        case .revert:     args = ["revert", "--abort"]
        }
        let result = try await runner.run(in: repoPath, args: args)
        if result.succeeded, operation == .revert {
            await clearUncommittedRevert(repoPath: repoPath)
        }
        if result.succeeded, operation == .rebase {
            await clearRebasePlan(repoPath: repoPath)
        }
        return result
    }

    // MARK: - Stash

    @discardableResult
    /// `git stash push`. `paths` limits the stash to those pathspecs
    /// (partial stash — everything else stays in the working tree);
    /// empty means stash all changes. `keepIndex` (`--keep-index`)
    /// stashes everything but leaves already-staged changes in the
    /// index, the classic "stash only my unstaged noise" move.
    /// Untracked files need `includeUntracked` even when explicitly
    /// listed in `paths` — plain `stash push -- <path>` skips them.
    func stashSave(
        repoPath: String,
        message: String? = nil,
        includeUntracked: Bool = false,
        keepIndex: Bool = false,
        paths: [String] = []
    ) async throws -> GitCommandResult {
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if keepIndex { args.append("--keep-index") }
        if let message, !message.isEmpty { args += ["-m", message] }
        if !paths.isEmpty { args += ["--"] + paths }
        return try await runner.run(in: repoPath, args: args)
    }

    @discardableResult
    /// Record a stash entry and leave the working tree exactly as it is —
    /// a snapshot rather than a save.
    ///
    /// `git stash push` always does two things: it writes the entry, then it
    /// rolls the tree back to HEAD. No flag asks for only the first half, but
    /// both halves git builds it from are commands of their own: `stash
    /// create` writes the stash commit and prints its SHA while touching
    /// nothing, and `stash store` files an existing commit under
    /// `refs/stash`. Run the pair and the entry shows up in the list with
    /// every staged, unstaged and untracked file still where the user left it.
    ///
    /// `create` parses no options at all — everything after the word is
    /// joined into the message, so `-u` would be *recorded* rather than
    /// obeyed — which leaves two gaps to fill by hand:
    ///
    /// - It never sweeps up untracked files. `includeUntracked` builds the
    ///   third parent itself (the parentless commit whose tree holds the
    ///   untracked files, exactly what `stash push -u` records) and rebuilds
    ///   the stash commit around it.
    /// - It prints nothing when the only changes are untracked ones, because
    ///   by its own reckoning there is nothing to stash. Then the working and
    ///   index trees are HEAD's own, which is the shape `stash push -u`
    ///   records in that state.
    ///
    /// There is no `paths` here on purpose: `create` takes no pathspec — it
    /// would read one as more message — so a snapshot is always the whole
    /// working tree.
    func stashSnapshot(
        repoPath: String,
        message: String? = nil,
        includeUntracked: Bool = false
    ) async throws -> GitCommandResult {
        // HEAD's full SHA, short SHA and subject in one call: the commit
        // every parent below hangs off, plus the "<short> <subject>" tail git
        // puts in the messages of the index and untracked commits.
        let headInfo = try await runner.run(
            in: repoPath, args: ["log", "-1", "--format=%H%x00%h%x00%s", "HEAD"]
        )
        let head = headInfo.stdout
            .split(separator: "\0", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard headInfo.succeeded, head.count == 3, !head[0].isEmpty else {
            // What `git stash push` says on an unborn branch.
            return .outcome(
                "git stash create", failure: "You do not have the initial commit yet"
            )
        }
        let headSHA = head[0]
        let headTail = "\(head[1]) \(head[2])"

        var createArgs = ["stash", "create"]
        if let message, !message.isEmpty { createArgs.append(message) }
        let created = try await runner.run(in: repoPath, args: createArgs)
        try ensureSucceeded(created)
        let createdSHA = created.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let untracked = includeUntracked ? try await untrackedFiles(repoPath: repoPath) : []
        guard !createdSHA.isEmpty || !untracked.isEmpty else {
            return .outcome(created.command, failure: "No local changes to save")
        }

        // The three pieces a stash entry is made of: the tree of tracked
        // files as they sit on disk, the commit holding the index, and the
        // subject line the stash list shows.
        var workingTree = "\(headSHA)^{tree}"
        var indexCommit = ""
        var subject = ""

        if !createdSHA.isEmpty {
            let parts = try await runner.run(
                in: repoPath, args: ["log", "-1", "--format=%T%x00%P%x00%s", createdSHA]
            )
            try ensureSucceeded(parts)
            let fields = parts.stdout
                .split(separator: "\0", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            let parents = fields.count > 1 ? fields[1].split(separator: " ").map(String.init) : []
            guard fields.count == 3, parents.count >= 2 else {
                return .outcome(
                    parts.command,
                    failure: "Could not read the stash commit git just created."
                )
            }
            workingTree = fields[0]
            indexCommit = parents[1]
            subject = fields[2]

            // Nothing to graft on: the commit `create` made is already a
            // complete entry, message and all.
            if untracked.isEmpty {
                return try await runner.run(
                    in: repoPath, args: ["stash", "store", "-m", subject, createdSHA]
                )
            }
        }

        let branch = await stashBranchName(repoPath: repoPath)
        if createdSHA.isEmpty {
            subject = message.flatMap { $0.isEmpty ? nil : "On \(branch): \($0)" }
                ?? "WIP on \(branch): \(headTail)"
            indexCommit = try await commitTree(
                repoPath: repoPath,
                tree: workingTree,
                parents: [headSHA],
                message: "index on \(branch): \(headTail)"
            )
        }

        let untrackedCommit = try await commitTree(
            repoPath: repoPath,
            tree: try await untrackedTree(repoPath: repoPath, files: untracked),
            parents: [],
            message: "untracked files on \(branch): \(headTail)"
        )
        let snapshot = try await commitTree(
            repoPath: repoPath,
            tree: workingTree,
            parents: [headSHA, indexCommit, untrackedCommit],
            message: subject
        )
        return try await runner.run(
            in: repoPath, args: ["stash", "store", "-m", subject, snapshot]
        )
    }

    /// Untracked-but-not-ignored files: what `stash push -u` sweeps up.
    private func untrackedFiles(repoPath: String) async throws -> [String] {
        let r = try await runner.run(
            in: repoPath, args: ["ls-files", "--others", "--exclude-standard", "-z"]
        )
        try ensureSucceeded(r)
        return r.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    /// A tree of the untracked files and nothing else.
    ///
    /// Built in a scratch index, because the repository's own index is part
    /// of what the snapshot is recording and must come out of this unchanged.
    private func untrackedTree(repoPath: String, files: [String]) async throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-stash-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let env = ["GIT_INDEX_FILE": scratch.path]
        // Paths arrive NUL-separated on stdin, so spaces and newlines in a
        // filename survive and a long list never has to fit in an argv.
        let added = try await runner.run(
            in: repoPath,
            args: ["update-index", "-z", "--add", "--stdin"],
            stdin: files.joined(separator: "\0") + "\0",
            env: env
        )
        try ensureSucceeded(added)
        let tree = try await runner.run(in: repoPath, args: ["write-tree"], env: env)
        try ensureSucceeded(tree)
        return tree.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `git commit-tree`: a commit object out of a tree, its parents and a
    /// message, with nothing staged, checked out or moved.
    private func commitTree(
        repoPath: String,
        tree: String,
        parents: [String],
        message: String
    ) async throws -> String {
        var args = ["commit-tree", tree]
        for parent in parents { args += ["-p", parent] }
        args += ["-m", message]
        let r = try await runner.run(in: repoPath, args: args)
        try ensureSucceeded(r)
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The branch name git writes into stash messages: the checked-out
    /// branch, or "(no branch)" when HEAD is detached, as git words it.
    private func stashBranchName(repoPath: String) async -> String {
        let r = try? await runner.run(
            in: repoPath, args: ["symbolic-ref", "--quiet", "--short", "HEAD"]
        )
        let name = r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "(no branch)" : name
    }

    @discardableResult
    func stashApply(repoPath: String, index: Int = 0) async throws -> GitCommandResult {
        try await runner.run(in: repoPath, args: ["stash", "apply", "stash@{\(index)}"])
    }

    @discardableResult
    func stashPop(repoPath: String) async throws -> GitCommandResult {
        try await runner.run(in: repoPath, args: ["stash", "pop"])
    }

    /// Undo a `stash apply` that stopped in conflict, by restoring the files
    /// the stash touched to their committed state.
    ///
    /// There is no `git stash apply --abort`. A conflicted apply leaves no
    /// MERGE_HEAD and no sequencer state — just unmerged index entries — so
    /// there is nothing for git to unwind and nothing for
    /// `inProgressOperation` to find. Neither `apply` nor `pop` drops the
    /// stash when it conflicts, so the entry is still there to re-apply once
    /// the tree is back in order.
    ///
    /// `git reset --hard` would do it in one line and take every other
    /// uncommitted change with it, including work staged before the apply.
    /// Restoring only the stash's own files keeps the blast radius to what
    /// the apply actually disturbed.
    ///
    /// Files the stash would have *added* are only unstaged, never deleted:
    /// they are absent from HEAD, so there is no committed version to restore,
    /// and removing them could destroy content git has never held a copy of.
    /// `leftInPlace` names them so the caller can say so.
    @discardableResult
    func abortStashApply(
        repoPath: String,
        files: [String]
    ) async throws -> (result: GitCommandResult, leftInPlace: [String]) {
        guard !files.isEmpty else {
            return (.outcome("abort stash apply", failure: "The stash touched no files."), [])
        }
        // Which of them HEAD actually has a version of.
        let listed = try await runner.run(
            in: repoPath,
            args: ["ls-tree", "--name-only", "-z", "HEAD", "--"] + files
        )
        let inHead = Set(
            listed.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        )
        let restorable = files.filter { inHead.contains($0) }
        let added = files.filter { !inHead.contains($0) }

        var last = GitCommandResult.outcome("abort stash apply")
        if !restorable.isEmpty {
            last = try await runner.run(
                in: repoPath, args: ["checkout", "HEAD", "--"] + restorable
            )
            try ensureSucceeded(last)
        }
        if !added.isEmpty {
            // Drop the apply's staging of them; the files stay on disk.
            last = try await runner.run(in: repoPath, args: ["reset", "-q", "HEAD", "--"] + added)
        }
        return (last, added)
    }

    @discardableResult
    func stashDrop(repoPath: String, index: Int) async throws -> GitCommandResult {
        try await runner.run(in: repoPath, args: ["stash", "drop", "stash@{\(index)}"])
    }

    /// Give `stash@{index}` a new message, keeping it where it is in the list.
    ///
    /// Git has no rename. The message is the reflog entry's subject, and the
    /// only way to change one is to drop the entry and `store` its commit
    /// again — which files it at the top, `stash@{0}`. Putting it back in its
    /// own place means lifting off every entry above it too and storing them
    /// all again deepest-first. The commits are untouched throughout; only
    /// the reflog lines are rewritten, so dates and contents stay the same.
    ///
    /// The "On <branch>:" prefix git writes is kept, so the entry still says
    /// which branch it came from — see `renamedStashSubject`.
    @discardableResult
    func stashRename(repoPath: String, index: Int, message: String) async throws -> GitCommandResult {
        let listed = try await runner.run(
            in: repoPath, args: ["stash", "list", "--format=%H%x00%gs"]
        )
        try ensureSucceeded(listed)
        let entries: [(sha: String, subject: String)] = listed.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let parts = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
            }
        guard index >= 0, index < entries.count else {
            return .outcome("git stash rename", failure: "There is no stash@{\(index)}.")
        }
        let lifted = Array(entries.prefix(index + 1))
        var subjects = lifted.map(\.subject)
        subjects[index] = Self.renamedStashSubject(old: lifted[index].subject, new: message)

        // Stores the lifted entries back from `upTo` down to stash@{0}, so
        // each lands in the slot it came from. Keeps going past a failure:
        // an entry left off the list is one the user can no longer see.
        func storeBack(upTo last: Int, subjects: [String]) async -> [String] {
            var failed: [String] = []
            for i in stride(from: last, through: 0, by: -1) {
                let r = try? await runner.run(
                    in: repoPath, args: ["stash", "store", "-m", subjects[i], lifted[i].sha]
                )
                if r?.succeeded != true { failed.append(lifted[i].sha) }
            }
            return failed
        }

        var dropped = 0
        for _ in lifted {
            let r = try? await runner.run(in: repoPath, args: ["stash", "drop", "-q", "stash@{0}"])
            guard r?.succeeded == true else {
                // Put back what came off, under the names it had.
                _ = await storeBack(upTo: dropped - 1, subjects: lifted.map(\.subject))
                return r ?? .outcome("git stash drop", failure: "Could not lift stash@{\(dropped)}.")
            }
            dropped += 1
        }

        let failed = await storeBack(upTo: index, subjects: subjects)
        guard failed.isEmpty else {
            return .outcome(
                "git stash store",
                failure: "Could not put back \(failed.count) stash entr\(failed.count == 1 ? "y" : "ies"). "
                    + "Recover with `git stash store -m <message> <sha>`: "
                    + failed.joined(separator: ", ")
            )
        }
        return .outcome("git stash rename stash@{\(index)}")
    }

    /// The subject a renamed stash is stored under: the new message behind
    /// the "On <branch>:" git writes, so the branch the entry came from is
    /// still read off it. "WIP on" becomes "On" — the entry now has a
    /// message of the user's own, which is what "On" means in git's wording.
    static func renamedStashSubject(old: String, new: String) -> String {
        guard let branch = stashSubjectBranch(old) else { return new }
        return "On \(branch): \(new)"
    }

    /// The part of a stash subject after git's "On <branch>:" or
    /// "WIP on <branch>:" prefix — what a rename starts from.
    static func stashSubjectDescription(_ subject: String) -> String {
        guard stashSubjectBranch(subject) != nil,
              let colon = subject.firstIndex(of: ":") else { return subject }
        return subject[subject.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    private static func stashSubjectBranch(_ subject: String) -> String? {
        let prefix = subject.hasPrefix("WIP on ") ? "WIP on " : subject.hasPrefix("On ") ? "On " : nil
        guard let prefix,
              let colon = subject.firstIndex(of: ":") else { return nil }
        let branch = subject[subject.index(subject.startIndex, offsetBy: prefix.count)..<colon]
        return branch.isEmpty ? nil : String(branch)
    }

    /// Files touched by a single commit (`git show --name-status`),
    /// returned as `GitFileStatus` values so they render with the same
    /// FilesTable that the working-tree view uses. `indexStatus` carries
    /// the M/A/D/R letter from git; worktree letter is left as ".".
    // MARK: - Maintenance

    /// Approximate disk footprint of the object database in bytes,
    /// from `git count-objects -v` (`size` + `size-pack`, both KiB).
    /// Used by Clean Up to report "before → after".
    func objectDatabaseSize(repoPath: String) async throws -> Int64 {
        let r = try await runner.run(in: repoPath, args: ["count-objects", "-v"])
        try ensureSucceeded(r)
        return GitOutputParser.parseObjectDatabaseSizeKiB(r.stdout) * 1024
    }

    /// `git gc --prune=<expiry>`: repack loose objects into packs, pack
    /// refs, and delete unreachable objects older than `expiry`.
    /// "now" gives the real shrink — but note git only deletes objects
    /// unreachable from *every* ref **and reflog entry**, so undo
    /// history survives until the reflog itself expires. No timeout:
    /// gc can take minutes on large repositories.
    @discardableResult
    func gc(repoPath: String, pruneExpiry: String = "now") async throws -> GitCommandResult {
        let r = try await runner.run(
            in: repoPath,
            args: ["gc", "--prune=\(pruneExpiry)"],
            timeout: 0
        )
        try ensureSucceeded(r)
        return r
    }

    /// `git remote prune <remote>`: delete remote-tracking refs whose
    /// upstream branch no longer exists ("unlinked" refs left behind
    /// after branches are deleted on the server). Network access is
    /// required, hence no timeout.
    @discardableResult
    func pruneRemote(repoPath: String, remote: String) async throws -> GitCommandResult {
        let r = try await runner.run(
            in: repoPath,
            args: ["remote", "prune", remote],
            timeout: 0
        )
        try ensureSucceeded(r)
        return r
    }

    // MARK: - Worktrees

    /// All working trees attached to the repository, main worktree first
    /// (`git worktree list --porcelain`).
    func worktrees(repoPath: String) async throws -> [GitWorktree] {
        let r = try await runner.run(in: repoPath, args: ["worktree", "list", "--porcelain"])
        try ensureSucceeded(r)
        return GitOutputParser.parseWorktrees(r.stdout)
    }

    /// `git worktree add`. Exactly one of `checkoutBranch` /
    /// `newBranch` applies:
    /// - `checkoutBranch` checks an existing branch out at `path`
    ///   (fails if it's already checked out in another worktree),
    /// - `newBranch` creates that branch at `startPoint` (default HEAD)
    ///   and checks it out at `path`.
    @discardableResult
    func addWorktree(
        repoPath: String,
        path: String,
        checkoutBranch: String? = nil,
        newBranch: String? = nil,
        startPoint: String? = nil
    ) async throws -> GitCommandResult {
        var args = ["worktree", "add"]
        if let newBranch {
            args += ["-b", newBranch, path]
            if let startPoint { args.append(startPoint) }
        } else if let checkoutBranch {
            args += [path, checkoutBranch]
        } else {
            args.append(path)
        }
        let r = try await runner.run(in: repoPath, args: args)
        try ensureSucceeded(r)
        return r
    }

    /// `git worktree remove [--force]`. Without force, git refuses when
    /// the worktree is dirty or locked — the caller surfaces git's
    /// message and can retry with `force: true`.
    @discardableResult
    func removeWorktree(
        repoPath: String,
        path: String,
        force: Bool = false
    ) async throws -> GitCommandResult {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path)
        let r = try await runner.run(in: repoPath, args: args)
        try ensureSucceeded(r)
        return r
    }

    /// `git worktree prune`: drop bookkeeping for worktrees whose
    /// folders were deleted manually.
    @discardableResult
    func pruneWorktrees(repoPath: String) async throws -> GitCommandResult {
        let r = try await runner.run(in: repoPath, args: ["worktree", "prune"])
        try ensureSucceeded(r)
        return r
    }

    func commitFiles(repoPath: String, hash: String) async throws -> [GitFileStatus] {
        // `-m --first-parent` makes merge commits report the files they
        // changed relative to their first parent. Without it `git show`
        // emits an empty diff for merges and the Files pane looks blank,
        // unlike SmartGit. Both flags are harmless for normal commits.
        let r = try await runner.run(in: repoPath, args: [
            "show", "-m", "--first-parent", "--name-status", "--no-color", "--format=", hash
        ])
        try ensureSucceeded(r)
        return GitOutputParser.parseNameStatus(r.stdout)
    }

    /// Full commit message (subject + blank line + body) — used by the
    /// Log window's commit detail pane. The short log format we use for
    /// the Journal table only includes %s (subject), so we fetch %B
    /// lazily when the user actually wants the full text.
    /// Branches whose tip has `hash` in its history, plus the nearest tag
    /// containing it.
    ///
    /// Both halves walk refs, so on a repo with thousands of branches this
    /// is measured in seconds rather than milliseconds — callers load it
    /// off the selection path and cache the answer per commit.
    func containment(repoPath: String, hash: String) async throws -> CommitContainment {
        let branchList = try await runner.run(
            in: repoPath,
            args: ["branch", "--all", "--contains", hash, "--format=%(refname:short)"]
        )
        try ensureSucceeded(branchList)
        let branches = branchList.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // `origin/HEAD` is a symref onto a branch that's already in
            // the list — naming the same branch twice tells the user
            // nothing.
            .filter { !$0.isEmpty && !$0.contains(" -> ") && !$0.hasSuffix("/HEAD") }

        // `describe --contains` names the closest containing tag as
        // "v1.2~14"; everything from the first ~ or ^ is the distance
        // back to the tag, not part of its name. A non-zero exit means no
        // tag contains the commit — an answer, not a failure.
        var closestTag: String?
        let described = try? await runner.run(
            in: repoPath, args: ["describe", "--contains", hash]
        )
        if let described, described.succeeded {
            let name = described.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix { $0 != "~" && $0 != "^" }
            closestTag = name.isEmpty ? nil : String(name)
        }
        return CommitContainment(branches: branches, closestTag: closestTag)
    }

    func commitBody(repoPath: String, hash: String) async throws -> String {
        let r = try await runner.run(in: repoPath, args: [
            "show", "--no-patch", "--no-color", "--format=%B", hash
        ])
        try ensureSucceeded(r)
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Diff of a specific commit (`git show <hash>`). May cover multiple
    /// files; we parse them as one flat hunk list — same shape the stash
    /// diff path produces, so the existing rendering just works. A
    /// non-empty `paths` scopes the diff to those files, so the Log
    /// window's Files pane can narrow the preview to the rows it selected.
    func commitDiff(
        repoPath: String,
        hash: String,
        paths: [String] = [],
        ignoreWhitespace: Bool = false,
        fullFile: Bool = false
    ) async throws -> [DiffHunk] {
        // `-m --first-parent` so merge commits render their diff against
        // the first parent instead of an empty patch (matches the Files
        // pane and SmartGit). Harmless for non-merge commits.
        var args = ["show", "-m", "--first-parent", "--no-color", "--format="]
        if ignoreWhitespace { args.append("-w") }
        if fullFile { args.append("--unified=\(Self.fullFileContextLines)") }
        args.append(hash)
        if !paths.isEmpty { args += ["--"] + paths }
        let r = try await runner.run(in: repoPath, args: args)
        try ensureSucceeded(r)
        return GitOutputParser.parseDiff(r.stdout)
    }

    /// Diff of a specific stash entry (`git stash show -p stash@{N}`),
    /// plus the untracked files the entry swept up, if any. Covers several
    /// files at once; each hunk carries the path it came from, so a caller
    /// showing one file at a time can pick its own out.
    ///
    /// Passing `path` narrows the result to that one file. The filtering is
    /// done here rather than by git: `git stash show` takes a revision and
    /// no pathspec ("Too many revisions specified"), so a path on the
    /// command line would fail outright.
    func stashDiff(
        repoPath: String,
        index: Int,
        path: String? = nil,
        ignoreWhitespace: Bool = false,
        fullFile: Bool = false
    ) async throws -> [DiffHunk] {
        var options = ["-p", "--no-color"]
        if ignoreWhitespace { options.append("-w") }
        if fullFile { options.append("--unified=\(Self.fullFileContextLines)") }

        let tracked = try await runner.run(
            in: repoPath,
            args: ["stash", "show"] + options + [Self.stashRev(index)]
        )
        try ensureSucceeded(tracked)
        var hunks = GitOutputParser.parseDiff(tracked.stdout)

        if let untracked = try? await runner.run(
            in: repoPath,
            args: ["show", "--format="] + options + [Self.stashUntrackedRev(index)]
        ), untracked.succeeded {
            hunks += GitOutputParser.parseDiff(untracked.stdout)
        }

        guard let path else { return hunks }
        return hunks.filter { $0.file == path }
    }

    /// Files recorded in a stash entry, each paired with the revision inside
    /// the entry that holds it — `git stash show --name-status`, plus the
    /// third parent a `stash push --include-untracked` leaves the untracked
    /// files in. Without that second half the list reads as if the stash
    /// were smaller than it is.
    func stashFiles(repoPath: String, index: Int) async throws -> [StashFile] {
        let stash = Self.stashRev(index)
        let tracked = try await runner.run(
            in: repoPath,
            args: ["stash", "show", "--name-status", "--no-color", stash]
        )
        try ensureSucceeded(tracked)
        var files = GitOutputParser.parseNameStatus(tracked.stdout)
            .map { StashFile(status: $0, revision: stash) }

        let untrackedRev = Self.stashUntrackedRev(index)
        // Fails with "unknown revision" on a stash saved without untracked
        // files, which is most of them — that is the answer, not an error.
        if let r = try? await runner.run(
            in: repoPath,
            args: ["show", "--name-status", "--no-color", "--format=", untrackedRev]
        ), r.succeeded {
            files += GitOutputParser.parseNameStatus(r.stdout)
                .map { StashFile(status: $0, revision: untrackedRev) }
        }
        return files
    }

    /// The commit a revision names, so a window can hold on to the entry it
    /// was opened for. Stash revisions are positional — dropping @{0}
    /// renumbers every one below it — and a SHA is not.
    func resolveRevision(repoPath: String, revision: String) async -> String? {
        guard let r = try? await runner.run(
            in: repoPath, args: ["rev-parse", "--verify", "--quiet", revision]
        ), r.succeeded else { return nil }
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    static func stashRev(_ index: Int) -> String { "stash@{\(index)}" }

    /// Where `git stash push --include-untracked` keeps what it swept up.
    static func stashUntrackedRev(_ index: Int) -> String { "stash@{\(index)}^3" }

    func stashList(repoPath: String) async throws -> [GitStash] {
        let r = try await runner.run(in: repoPath, args: [
            "stash", "list", "--format=%gd%x00%gs%x00%aI"
        ])
        try ensureSucceeded(r)
        return GitOutputParser.parseStashList(r.stdout)
    }

    // MARK: - Branch ops

    /// Checks out `name`, landing on a branch wherever there is one to land
    /// on.
    ///
    /// The name comes from a row in the sidebar, so it can be a local branch
    /// or a remote one ("origin/topic"). Handed to plain `git checkout`, a
    /// remote ref succeeds and leaves HEAD **detached** at that commit — no
    /// branch, nothing for the next pull or push to reason about — and reports
    /// exit code 0 while doing it. Somebody who clicked "Check Out" meant to be
    /// *on* that branch, so a remote one becomes the local branch of the same
    /// name: switched to if it already exists, created tracking the remote if
    /// it does not.
    ///
    /// Every question here is put to git rather than to a cached branch list.
    /// A list that had gone stale — or had simply not loaded yet — would put
    /// this back to checking out a remote ref and detaching, which is the
    /// failure it exists to prevent.
    @discardableResult
    func checkoutBranch(repoPath: String, name: String) async throws -> GitCommandResult {
        if await refExists(repoPath: repoPath, ref: "refs/heads/\(name)") {
            return try await runner.run(in: repoPath, args: ["checkout", name])
        }
        if await refExists(repoPath: repoPath, ref: "refs/remotes/\(name)"),
           let slash = name.firstIndex(of: "/")
        {
            let local = String(name[name.index(after: slash)...])
            if !local.isEmpty {
                // Already there under its short name: switch to it. `--track`
                // would refuse with "a branch named … already exists".
                if await refExists(repoPath: repoPath, ref: "refs/heads/\(local)") {
                    return try await runner.run(in: repoPath, args: ["checkout", local])
                }
                return try await runner.run(in: repoPath, args: ["checkout", "--track", name])
            }
        }
        // Neither: a tag, or a commit someone typed. git will detach, which
        // for those is the only thing it can do — the caller says so rather
        // than reporting a bare success.
        return try await runner.run(in: repoPath, args: ["checkout", name])
    }

    /// Whether `ref` resolves in this repository. `--quiet` keeps a missing
    /// ref off stderr; the exit code carries the answer.
    func refExists(repoPath: String, ref: String) async -> Bool {
        let r = try? await runner.run(
            in: repoPath,
            args: ["rev-parse", "--verify", "--quiet", ref]
        )
        return r?.succeeded == true
    }

    @discardableResult
    func createBranch(repoPath: String, name: String, from: String? = nil, checkout: Bool = true) async throws -> GitCommandResult {
        var args = checkout ? ["checkout", "-b", name] : ["branch", name]
        if let from { args.append(from) }
        return try await runner.run(in: repoPath, args: args)
    }

    @discardableResult
    func deleteBranch(repoPath: String, name: String, force: Bool = false) async throws -> GitCommandResult {
        let flag = force ? "-D" : "-d"
        return try await runner.run(in: repoPath, args: ["branch", flag, name])
    }

    /// Delete a branch from a remote.
    ///
    /// A push with nothing on the near side of the refspec, which is what
    /// `--delete` spells — not a `git branch` command at all. It leaves the
    /// machine, so it is the one delete in this app that other people see.
    func deleteRemoteBranch(
        repoPath: String,
        remote: String,
        branch: String
    ) async throws -> GitCommandResult {
        try await runner.run(
            in: repoPath,
            args: ["push", remote, "--delete", branch],
            timeout: 0
        )
    }

    /// What a plain `git branch -d` is about to do to `branch`, worked out
    /// before the delete runs.
    ///
    /// git accepts `-d` when the branch is reachable from HEAD *or* from its
    /// own upstream, and otherwise refuses with a "not fully merged" error
    /// that only ever lands in the command log. Asking git the same two
    /// questions up front lets the delete dialog say what would be lost
    /// while the user can still change their mind.
    func branchDeletionCheck(
        repoPath: String,
        branch: String,
        upstream: String?,
        comparedTo: String
    ) async throws -> BranchDeletionCheck {
        var mergedInto: String?
        if try await isAncestor(repoPath: repoPath, ancestor: branch, descendant: comparedTo) {
            mergedInto = comparedTo
        } else if let upstream, !upstream.isEmpty,
                  try await isAncestor(repoPath: repoPath, ancestor: branch, descendant: upstream) {
            // A "[gone]" upstream fails this check, which is exactly right:
            // git refuses the same delete for the same reason.
            mergedInto = upstream
        }

        let counted = try await runner.run(in: repoPath, args: [
            "rev-list", "--count", "\(comparedTo)..\(branch)"
        ])
        let unmerged = counted.succeeded
            ? Int(counted.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            : 0

        return BranchDeletionCheck(
            mergedInto: mergedInto,
            unmergedCount: unmerged,
            comparedTo: comparedTo
        )
    }

    /// True when `ancestor` is reachable from `descendant`. A missing ref on
    /// either side is a non-zero exit, which reads as "not contained".
    private func isAncestor(repoPath: String, ancestor: String, descendant: String) async throws -> Bool {
        let r = try await runner.run(in: repoPath, args: [
            "merge-base", "--is-ancestor", ancestor, descendant
        ])
        return r.succeeded
    }

    @discardableResult
    func renameBranch(repoPath: String, from: String, to: String) async throws -> GitCommandResult {
        try await runner.run(in: repoPath, args: ["branch", "-m", from, to])
    }

    /// Merge `branch` into the current one, stashing local changes for the
    /// duration. Same reasoning as `pull`: a dirty working tree is the
    /// normal state, and git refusing the whole operation over it just
    /// moves the stash dance onto the user.
    ///
    /// For `.workingTree` the autostash outlives the command: git keeps it
    /// as MERGE_AUTOSTASH and puts it back when the merge is committed or
    /// aborted, so the tree under review holds the merge and nothing else.
    @discardableResult
    func merge(
        repoPath: String,
        branch: String,
        mode: MergeMode = .mergeCommit,
        autostash: Bool = true
    ) async throws -> GitCommandResult {
        var args = ["merge"]
        switch mode {
        case .fastForward: args.append("--ff-only")
        case .mergeCommit: args.append("--no-ff")
        case .workingTree: args += ["--no-ff", "--no-commit"]
        }
        if autostash { args.append("--autostash") }
        args.append(branch)
        return try await runAutostashing(in: repoPath, args: args)
    }

    func mergeRelation(repoPath: String, branch: String) async -> MergeRelation {
        if (try? await isAncestor(repoPath: repoPath, ancestor: branch, descendant: "HEAD")) == true {
            return .upToDate
        }
        if (try? await isAncestor(repoPath: repoPath, ancestor: "HEAD", descendant: branch)) == true {
            return .canFastForward
        }
        return .diverged
    }

    /// Bring local `branch` up to date with what it tracks, without checking
    /// it out — so `main` can be brought level with `origin/main` from a
    /// feature branch that is about to rebase onto it.
    ///
    /// `git fetch <remote> <merge>:refs/heads/<branch>` is one round trip that
    /// fetches and moves the branch together, and updates `<remote>/<branch>`
    /// on the way. Fetching first matters: the remote-tracking ref is only as
    /// new as the last fetch, and a fast-forward to a stale one leaves the
    /// branch exactly as far behind as it looked.
    ///
    /// No checks here, because git makes the two that count itself: without a
    /// `+` the refspec refuses anything but a fast-forward, and fetch refuses
    /// to move a branch checked out in any worktree.
    @discardableResult
    func fastForwardToUpstream(repoPath: String, branch: String) async throws -> GitCommandResult {
        // Read from config rather than split out of `%(upstream:short)`, for
        // the reason `upstreamOfBranch` gives. Unlike that one, a local
        // upstream (`remote = .`) is kept: `git fetch .` addresses it fine.
        guard let remote = try await configValue(
            repoPath: repoPath, key: "branch.\(branch).remote", scope: .local
        ), let merge = try await configValue(
            repoPath: repoPath, key: "branch.\(branch).merge", scope: .local
        ) else {
            return .outcome("fast-forward \(branch)", failure: "\(branch) does not track a branch")
        }
        let result = try await runner.run(
            in: repoPath,
            args: ["fetch", remote, "\(merge):refs/heads/\(branch)"],
            timeout: 0
        )
        // Refused as non-fast-forward. That is either real local work, which
        // stays refused, or the upstream having been rewritten under a branch
        // that only ever held the upstream's own old state — a teammate
        // rebased and force-pushed it. The second has nothing to lose, and
        // moving it is what `git pull --rebase` would end up doing too (it
        // finds the same fork point and has no commits left to replay), so
        // the `+` goes on for that case alone.
        guard !result.succeeded,
              result.combinedOutput.contains("non-fast-forward"),
              await holdsOnlyFormerUpstream(repoPath: repoPath, branch: branch)
        else { return result }
        return try await runner.run(
            in: repoPath,
            args: ["fetch", remote, "+\(merge):refs/heads/\(branch)"],
            timeout: 0
        )
    }

    /// Integrate a diverged branch after the user has chosen to check it out.
    /// The explicit branch check prevents accidentally rebasing the feature
    /// branch from which the fast-forward was requested if checkout failed.
    func integrateUpstream(repoPath: String, branch: String, rebase: Bool) async throws -> GitCommandResult {
        guard await inProgressOperation(repoPath: repoPath) == nil else {
            return .outcome("Integrate \(branch)", failure: "Finish or abort the current operation first.")
        }
        guard try await currentBranch(repoPath: repoPath) == branch else {
            return .outcome("Integrate \(branch)", failure: "Check out \(branch) before integrating its upstream.")
        }
        let upstream = try await runner.run(in: repoPath, args: [
            "rev-parse", "--symbolic-full-name", "@{upstream}"
        ])
        try ensureSucceeded(upstream)
        let ref = upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else {
            return .outcome("Integrate \(branch)", failure: "\(branch) does not track a branch.")
        }
        if rebase {
            // Match pull's fork-point handling for a rewritten upstream,
            // preserve local merges, and keep any other branches pointing at
            // the old commits even when rebase.updateRefs is configured.
            return try await runAutostashing(in: repoPath, args: [
                "rebase", "--autostash", "--fork-point", "--rebase-merges", "--no-update-refs", ref
            ])
        }
        return try await merge(repoPath: repoPath, branch: ref, mode: .mergeCommit)
    }

    /// True when `branch`'s tip is a state its upstream was once in — it has
    /// no commit of its own, however far the two have since diverged.
    ///
    /// Read off the upstream's reflog through `merge-base --fork-point`: the
    /// fork point of a branch that was never more than an old copy of its
    /// upstream is the branch's own tip. False whenever git can't say — no
    /// upstream, or the reflog entry expired — so the caller stays with
    /// "refuse".
    func holdsOnlyFormerUpstream(repoPath: String, branch: String) async -> Bool {
        let ref = "refs/heads/\(branch)"
        guard let upstream = try? await runner.run(
                  in: repoPath,
                  args: ["rev-parse", "--symbolic-full-name", "\(branch)@{upstream}"]
              ), upstream.succeeded,
              let tip = await resolveRevision(repoPath: repoPath, revision: ref),
              let fork = await forkPoint(
                  repoPath: repoPath,
                  base: upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                  of: ref
              )
        else { return false }
        return fork == tip
    }

    /// `git merge-base --fork-point <base> <commit>`: where `commit`'s line
    /// left `base`, judged against every tip `base` has had according to its
    /// reflog rather than only its current one. Nil when git finds none —
    /// `base` isn't a ref, or its reflog no longer reaches that far.
    func forkPoint(repoPath: String, base: String, of commit: String) async -> String? {
        guard let r = try? await runner.run(
            in: repoPath, args: ["merge-base", "--fork-point", base, commit]
        ), r.succeeded else { return nil }
        let hash = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    /// The commits HEAD carries from an old version of `base`, when `base` has
    /// been rewritten since HEAD branched from it. Newest first. Empty when it
    /// hasn't been, or git can't tell.
    ///
    /// Branch `vubl` off `story`, let a teammate rebase and force-push
    /// `story`, and HEAD still holds every commit `story` had then, under the
    /// old SHAs. A rebase onto the new `story` replays them all from the
    /// merge-base: git skips the ones whose patch survived unchanged, but any
    /// the rewrite touched come back as duplicates or conflicts. Those
    /// commits are `<merge-base>..<fork-point>` — the fork point being where
    /// HEAD left the *old* `story`, which the reflog still knows.
    func commitsFromRewrittenBase(repoPath: String, base: String) async -> [RebaseTodo] {
        guard let fork = await forkPoint(repoPath: repoPath, base: base, of: "HEAD"),
              let mb = try? await runner.run(in: repoPath, args: ["merge-base", base, "HEAD"]),
              mb.succeeded
        else { return [] }
        let mergeBase = mb.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mergeBase.isEmpty, mergeBase != fork,
              let log = try? await runner.run(
                  in: repoPath,
                  args: ["log", "--topo-order", "--pretty=format:%H%x09%h%x09%s", "\(mergeBase)..\(fork)"]
              ), log.succeeded
        else { return [] }
        return log.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return RebaseTodo(hash: String(parts[0]), shortHash: String(parts[1]), subject: String(parts[2]))
        }
    }

    @discardableResult
    /// - Parameter from: replay only `<from>..HEAD` (`--onto <onto> <from>`)
    ///   instead of everything since HEAD and `onto` diverged.
    func rebase(
        repoPath: String,
        onto: String,
        from: String? = nil,
        autostash: Bool = true
    ) async throws -> GitCommandResult {
        var args = ["rebase"]
        if autostash { args.append("--autostash") }
        if let from {
            args += ["--onto", onto, from]
        } else {
            args.append(onto)
        }
        return try await runAutostashing(in: repoPath, args: args)
    }

    /// Reads HEAD's reflog. `limit` caps the returned entries (default
    /// 500 — large enough to cover any practical recovery window without
    /// pulling tens of thousands of rows on long-lived repos).
    func reflog(repoPath: String, limit: Int = 500) async throws -> [GitReflogEntry] {
        let result = try await runner.run(
            in: repoPath,
            args: [
                "reflog",
                "show",
                "--no-abbrev-commit",
                "--format=%H%x09%h%x09%gd%x09%gs%x09%cI",
                "-n", String(limit),
                "HEAD"
            ]
        )
        guard result.succeeded else { return [] }
        return GitOutputParser.parseReflog(result.stdout)
    }

    /// What an interactive rebase onto `base` would replay, and what it would
    /// skip because the base already has it. Oldest first, matching the order
    /// git writes into `git-rebase-todo`.
    ///
    /// Built as git's own sequencer builds that file, because SmallGit
    /// overwrites the file wholesale through `GIT_SEQUENCE_EDITOR` rather than
    /// editing what git generated — so a listing that merely *resembles* git's
    /// does not fail, it replays the wrong commits.
    ///
    /// The flags are the sequencer's, one for one:
    ///
    /// - `--cherry-mark --right-only <base>...HEAD` — the symmetric difference,
    ///   keeping HEAD's side, with commits that already exist on the base
    ///   marked `=` instead of `>`. A plain `<base>..HEAD` cannot see them: it
    ///   compares by commit, and a rewritten upstream carries the same changes
    ///   under new SHAs. Branch B off A, let someone force-push A, and every
    ///   commit A had when you branched comes back in the range as something
    ///   to replay — the user is made to drop A1, A2, A3 by hand, and replays
    ///   work A already has if they don't. git skips them ("skipped previously
    ///   applied commit …") and so does this.
    /// - `--no-merges` — the todo holds single-parent commits only.
    /// - `--topo-order --reverse` — graph order, oldest first.
    ///
    /// Merges are excluded here rather than refused; `mergesToRebase` is what
    /// refuses them, because a range holding one cannot be replayed faithfully
    /// at all.
    func rebaseRange(repoPath: String, base: String) async throws -> RebaseRange {
        // %m is the side/equivalence mark the walk above assigns: `=` for a
        // commit the base already has, `>` for one to replay. %H full hash,
        // %h short, %s subject.
        var args = [
            "log", "--reverse", "--topo-order", "--no-merges",
            "--pretty=format:%m%x09%H%x09%h%x09%s"
        ]
        if base == "--root" {
            // Rebasing the whole branch: there is no other side to compare
            // against, so every commit is one to replay.
            args.append("HEAD")
        } else {
            args += ["--cherry-mark", "--right-only", "\(base)...HEAD"]
        }
        let result = try await runner.run(in: repoPath, args: args)
        // Thrown rather than answered with an empty range: "nothing to replay"
        // is now a sentence the planner says out loud, and a bad ref must not
        // be able to put those words on screen.
        try ensureSucceeded(result)

        var todo: [RebaseTodo] = []
        var alreadyOnBase: [RebaseTodo] = []
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { continue }
            let row = RebaseTodo(
                hash: String(parts[1]),
                shortHash: String(parts[2]),
                subject: String(parts[3])
            )
            if parts[0] == "=" {
                alreadyOnBase.append(row)
            } else {
                todo.append(row)
            }
        }
        return RebaseRange(todo: todo, alreadyOnBase: alreadyOnBase)
    }

    /// Just the commits to replay, with a base that does not resolve answered
    /// as an empty range rather than as an error.
    ///
    /// The two error policies are deliberate. Squash and reword compute their
    /// own base from the commit the user clicked — `<hash>^`, which resolves to
    /// nothing for a root commit — and both turn an empty range into their own
    /// sentence about that commit, which is the better message. The planner
    /// cannot do that: it says "nothing to rebase" out loud, and a ref that
    /// does not resolve must not be able to put those words on screen, so
    /// `rebaseRange` throws and the planner reports the failure.
    func commitsToRebase(repoPath: String, base: String) async throws -> [RebaseTodo] {
        (try? await rebaseRange(repoPath: repoPath, base: base))?.todo ?? []
    }

    /// The merge commits inside `<base>..HEAD`, short hash, oldest first.
    ///
    /// `rebase -i` cannot replay one. Its todo holds single-parent commits
    /// only: git leaves the merge out and replays the side branch inline,
    /// flattening it out of history without ever saying so. And because
    /// SmallGit writes the todo itself rather than editing git's, the range
    /// has to be checked here — `commitsToRebase` lists the merge like any
    /// other commit, so the plan would carry a `pick <merge>` line that git's
    /// own todo would never contain.
    ///
    /// Asked with `rev-list` rather than read off the loaded graph because the
    /// range can reach past the journal's window entirely — rebasing onto a
    /// sibling branch replays everything since the two diverged.
    func mergesToRebase(repoPath: String, base: String) async throws -> [String] {
        let range = base == "--root" ? "HEAD" : "\(base)..HEAD"
        let result = try await runner.run(
            in: repoPath,
            args: ["rev-list", "--merges", "--reverse", "--abbrev-commit", range]
        )
        // A failure here must not read as "no merges": that answer is what
        // lets the planner open on a range git would flatten.
        try ensureSucceeded(result)
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    /// Runs `git rebase -i <onto>` with the supplied todo written into
    /// git's todo file via `GIT_SEQUENCE_EDITOR`.
    ///
    /// How it works: git invokes `$GIT_SEQUENCE_EDITOR <path-to-todo>` so
    /// the user can edit the plan. By setting it to `cp <our-todo>`, git
    /// ends up running `cp <our-todo> <path-to-todo>` which overwrites its
    /// own generated plan with ours. `GIT_EDITOR=true` makes the per-commit
    /// editor a no-op (used for `squash` combined-message prompts — the
    /// pre-filled combined message is accepted unchanged).
    ///
    /// On conflict, git exits non-zero and leaves the rebase in progress;
    /// the caller observes this via `inProgressOperation()` and surfaces
    /// the conflict resolver. The caller then drives `continueOperation`
    /// or `abortOperation` to completion.
    @discardableResult
    func runInteractiveRebase(
        repoPath: String,
        onto: String,
        todo: [RebaseTodo]
    ) async throws -> GitCommandResult {
        if let reason = todo.validationError {
            return GitCommandResult(
                command: "git rebase -i \(onto)",
                exitCode: 1,
                stdout: "",
                stderr: reason,
                duration: 0
            )
        }
        // Write the todo to a temp file we own. We deliberately put it in
        // an isolated directory so the path is shell-safe (no spaces,
        // no metacharacters) — GIT_SEQUENCE_EDITOR is parsed by sh -c.
        let tempDir = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("smallgit-rebase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let todoFile = tempDir.appendingPathComponent("todo")
        let planned = try await spellingOutSquashMessages(repoPath: repoPath, todo: todo)
        try planned.todoFileContents.write(to: todoFile, atomically: true, encoding: .utf8)

        await recordRebasePlan(repoPath: repoPath, onto: onto, todo: todo)
        let result = try await runGuardedRebase(repoPath: repoPath, onto: onto, todoFile: todoFile)
        if !result.succeeded, await inProgressOperation(repoPath: repoPath) == nil {
            // Refused or failed outright — there is no result to check later.
            await clearRebasePlan(repoPath: repoPath)
        }
        return result
    }

    /// The plan with every pick that takes a squash or fixup given its
    /// message outright — its own, then each squashed commit's, as git would
    /// stack them — unless the user already wrote one.
    ///
    /// Git builds that message up step by step in `rebase-merge`, and a step
    /// cut short by a foreign `index.lock` leaves it wrong: a rescheduled
    /// squash appends its message twice, a killed one leaves the previous
    /// group's message lying there. The `exec` amend the message rides on
    /// runs after the group is complete, so whatever git made of it, the
    /// commit ends up saying what the plan says.
    private func spellingOutSquashMessages(repoPath: String, todo: [RebaseTodo]) async throws -> [RebaseTodo] {
        var todo = todo
        for index in todo.indices where todo[index].action == .pick && todo[index].message == nil {
            let members = todo.squashMembers(of: index)
            guard !members.isEmpty else { continue }
            var parts: [String] = []
            for row in [index] + members where todo[row].action == .pick || todo[row].action == .squash {
                parts.append(try await commitMessageAndAuthorDate(repoPath: repoPath, hash: todo[row].hash).message)
            }
            todo[index].message = parts.joined(separator: "\n\n")
        }
        return todo
    }

    /// Full commit message (`%B`) plus the author date in strict-ISO form
    /// (`%aI`, the format `git commit --date` round-trips cleanly). The
    /// journal log only carries the subject line, so the squash dialog
    /// fetches the rest here to seed its editable message and the
    /// authorship dropdown.
    func commitMessageAndAuthorDate(
        repoPath: String,
        hash: String
    ) async throws -> (message: String, authorDateISO: String) {
        // Unit separator between the date and the (possibly multi-line)
        // body so the split is unambiguous.
        let sep = "\u{1f}"
        let r = try await runner.run(
            in: repoPath,
            args: ["show", "-s", "--format=%aI\(sep)%B", hash]
        )
        try ensureSucceeded(r)
        let parts = r.stdout.split(
            separator: Character(sep),
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let iso = parts.first.map(String.init) ?? ""
        let body = parts.count > 1 ? String(parts[1]) : ""
        return (body.trimmingCharacters(in: .newlines), iso)
    }

    /// Squash a contiguous range of commits into a single commit with a
    /// caller-supplied message and authorship.
    ///
    /// Mechanism: drive `git rebase -i <onto>` exactly like
    /// `runInteractiveRebase`, but build the todo so the oldest selected
    /// commit stays `pick`, the rest of the selected range becomes `fixup`
    /// (folds changes in, no message prompt), and an `exec git commit
    /// --amend` line runs right after the last folded commit to rewrite the
    /// squashed commit's message and author. Commits above the range keep
    /// their place as `pick`. `GIT_EDITOR=true` keeps git from opening any
    /// interactive editor — the amend's `--file` supplies the final message.
    ///
    /// On conflict git exits non-zero and leaves the rebase in progress;
    /// the caller surfaces the resolver exactly as for a normal rebase.
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
    ) async throws -> GitCommandResult {
        let todos = try await commitsToRebase(repoPath: repoPath, base: onto)
        guard !todos.isEmpty else {
            return GitCommandResult(
                command: "git rebase -i \(onto)",
                exitCode: 1,
                stdout: "",
                stderr: "Nothing to squash — the range is empty.",
                duration: 0
            )
        }

        // Isolated temp dir keeps both helper files on shell-safe paths.
        let tempDir = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("smallgit-squash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let msgFile = tempDir.appendingPathComponent("message")
        try message.write(to: msgFile, atomically: true, encoding: .utf8)

        // The exec line is run through `sh -c`, so quote every interpolated
        // value defensively (author names routinely contain spaces).
        var amend = "exec git commit --amend --file=\(Self.shellQuote(msgFile.path))"
        if let authorName, let authorEmail {
            amend += " --author=\(Self.shellQuote("\(authorName) <\(authorEmail)>"))"
        }
        if let authorDateISO, !authorDateISO.isEmpty {
            amend += " --date=\(Self.shellQuote(authorDateISO))"
        }

        var lines: [String] = []
        for todo in todos {
            let keyword = (todo.hash != pickHash && selectedHashes.contains(todo.hash))
                ? "fixup" : "pick"
            lines.append("\(keyword) \(todo.hash) \(todo.subject)")
            if todo.hash == lastSelectedHash {
                lines.append(amend)
            }
        }
        let todoFile = tempDir.appendingPathComponent("todo")
        try (lines.joined(separator: "\n") + "\n")
            .write(to: todoFile, atomically: true, encoding: .utf8)

        return try await runGuardedRebase(repoPath: repoPath, onto: onto, todoFile: todoFile)
    }

    /// Rewrite one commit's message, leaving its tree, its authorship and
    /// every other commit's content alone.
    ///
    /// Mechanism: the same `git rebase -i <onto>` drive as `squashRange`.
    /// Every commit keeps its `pick`, and a single `exec git commit --amend
    /// --file=<message>` line runs directly after the target row, so the
    /// amend lands on the commit git has just replayed. Git's own `reword`
    /// keyword is no use here: it hands the old message to `$GIT_EDITOR`,
    /// and the editor this runs under is `true` — it would accept the old
    /// message unchanged and rewrite nothing.
    ///
    /// Note this rewrites the commit even when it is HEAD, where a bare
    /// `git commit --amend` would do. That is deliberate: `--amend` folds
    /// whatever is staged into the commit as well, and "change the message"
    /// must not quietly commit the user's staged work. The rebase replays
    /// the tree as it stands and `--autostash` keeps the working tree out
    /// of it entirely.
    ///
    /// On conflict git exits non-zero and leaves the rebase in progress;
    /// the caller surfaces the resolver exactly as for a normal rebase.
    @discardableResult
    func rewordCommit(
        repoPath: String,
        onto: String,
        hash: String,
        message: String
    ) async throws -> GitCommandResult {
        let todos = try await commitsToRebase(repoPath: repoPath, base: onto)
        guard todos.contains(where: { $0.hash == hash }) else {
            return GitCommandResult(
                command: "git rebase -i \(onto)",
                exitCode: 1,
                stdout: "",
                stderr: "Nothing to reword — that commit is not on the current branch.",
                duration: 0
            )
        }

        // Isolated temp dir keeps both helper files on shell-safe paths.
        let tempDir = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("smallgit-reword-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let msgFile = tempDir.appendingPathComponent("message")
        try message.write(to: msgFile, atomically: true, encoding: .utf8)
        let amend = "exec git commit --amend --file=\(Self.shellQuote(msgFile.path))"

        var lines: [String] = []
        for todo in todos {
            lines.append("pick \(todo.hash) \(todo.subject)")
            if todo.hash == hash { lines.append(amend) }
        }
        let todoFile = tempDir.appendingPathComponent("todo")
        try (lines.joined(separator: "\n") + "\n")
            .write(to: todoFile, atomically: true, encoding: .utf8)

        return try await runGuardedRebase(repoPath: repoPath, onto: onto, todoFile: todoFile)
    }

    // MARK: - Rebase guards
    //
    // An interactive rebase is a long run of index writes, and any other
    // program that takes `index.lock` in the middle of one makes git stop on
    // the spot — Xcode's source-control scanner does it every few seconds.
    // Most stops are harmless and `--continue` picks up where git left off.
    // One is not: dying on a squash after its changes are staged but before
    // git notes the squash as in progress. `--continue` then commits those
    // changes as a commit of their own, with the stacked squash message, and
    // the squash the user asked for silently becomes two commits.

    /// How long another program's `index.lock` is waited out before giving up.
    static let indexLockPatience: TimeInterval = 8

    /// Waits for a foreign `index.lock` to go away. Nil once there is none;
    /// otherwise how old the lock was when patience ran out.
    func waitForIndexLock(
        repoPath: String,
        patience: TimeInterval = GitService.indexLockPatience
    ) async -> TimeInterval? {
        let path = await layout(repoPath: repoPath).gitPath("index.lock")
        let deadline = Date().addingTimeInterval(patience)
        while let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            if Date() >= deadline {
                let modified = attributes[.modificationDate] as? Date ?? Date()
                return Date().timeIntervalSince(modified)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    nonisolated static func failedOnIndexLock(_ result: GitCommandResult) -> Bool {
        guard !result.succeeded else { return false }
        let text = result.combinedOutput
        return text.contains("index.lock") && text.contains("File exists")
    }

    private func indexLockRefusal(_ command: String, age: TimeInterval) -> GitCommandResult {
        .outcome(command, failure: "Another program is holding this repository's index lock (index.lock, \(Int(age.rounded()))s old) — often Xcode's source control scanning the working copy. Running git now could stop the rebase half-way through a step. Wait for it to finish or close it, then try again.")
    }

    /// `git rebase -i` with the given todo, refused while another program
    /// holds the index, and started over if one grabs it before the run
    /// gets anywhere. Starting over is safe on the first run only: nothing
    /// has been resolved by hand yet, and `--abort` puts HEAD, the working
    /// tree and any autostash back exactly as they were.
    private func runGuardedRebase(repoPath: String, onto: String, todoFile: URL) async throws -> GitCommandResult {
        // A failed `exec` is run again on `--continue` instead of being
        // skipped — the message amends are execs, and the lock can stop one.
        let args = onto == "--root"
            ? ["rebase", "-i", "--autostash", "--reschedule-failed-exec", "--root"]
            : ["rebase", "-i", "--autostash", "--reschedule-failed-exec", onto]
        let env = [
            "GIT_SEQUENCE_EDITOR": "cp \(todoFile.path)",
            "GIT_EDITOR": "true"
        ]
        var attempt = 0
        while true {
            if let age = await waitForIndexLock(repoPath: repoPath) {
                return indexLockRefusal("git rebase -i \(onto)", age: age)
            }
            let result = try await runAutostashing(in: repoPath, args: args, env: env)
            attempt += 1
            guard Self.failedOnIndexLock(result), attempt < 5 else { return result }
            // Lost the race before git had started anything: just go again.
            if await inProgressOperation(repoPath: repoPath) == .rebase {
                let aborted = try await runner.run(in: repoPath, args: ["rebase", "--abort"])
                guard aborted.succeeded else { return result }
            }
        }
    }

    /// `git rebase --continue`, made safe against a foreign `index.lock`:
    /// waits it out first, mends a squash that git died in the middle of,
    /// and goes round again when the lock comes back mid-run.
    private func continueRebase(repoPath: String) async throws -> GitCommandResult {
        var attempt = 0
        while true {
            if let age = await waitForIndexLock(repoPath: repoPath) {
                return indexLockRefusal("git rebase --continue", age: age)
            }
            attempt += 1
            if let mended = try await mendInterruptedSquash(repoPath: repoPath), !mended.succeeded {
                if Self.failedOnIndexLock(mended), attempt < 4 { continue }
                return mended
            }
            let result = try await runner.run(
                in: repoPath,
                args: ["-c", "core.editor=true", "rebase", "--continue"]
            )
            guard Self.failedOnIndexLock(result), attempt < 4,
                  await inProgressOperation(repoPath: repoPath) == .rebase
            else { return result }
        }
    }

    /// Finishes a squash or fixup that git was killed in the middle of, so
    /// that `--continue` doesn't commit it on its own — and a pick killed the
    /// same way, which `--continue` would otherwise refuse to go past.
    ///
    /// The tell: the last command git started is a squash or fixup and its
    /// changes are staged, yet there is no `rebase-merge/amend` — the file a
    /// squash stopped the ordinary way (a conflict, an editor that failed)
    /// always leaves, and the one `--continue` reads to amend HEAD rather
    /// than commit anew. Folding the staged changes into HEAD here, with the
    /// message git had prepared for the squash, leaves `--continue` a clean
    /// index and nothing to get wrong.
    ///
    /// Nil when there is nothing to mend.
    func mendInterruptedSquash(repoPath: String) async throws -> GitCommandResult? {
        let dir = await layout(repoPath: repoPath).gitPath("rebase-merge")
        guard let done = try? String(contentsOfFile: dir + "/done", encoding: .utf8),
              let last = done.split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .last(where: { !$0.isEmpty && !$0.hasPrefix("#") })
        else { return nil }
        let words = last.split(separator: " ").map(String.init)
        guard let keyword = words.first, words.count > 1,
              ["pick", "p", "squash", "s", "fixup", "f"].contains(keyword),
              !FileManager.default.fileExists(atPath: dir + "/amend")
        else { return nil }
        let picked = words[1]

        // Unresolved conflicts are the user's to settle, and an empty index
        // means git rescheduled the squash before applying any of it.
        let unmerged = try await runner.run(in: repoPath, args: ["diff", "--name-only", "--diff-filter=U"])
        guard unmerged.succeeded, unmerged.stdout.isEmpty else { return nil }
        let staged = try await runner.run(in: repoPath, args: ["diff", "--cached", "--quiet"])
        guard staged.exitCode == 1 else { return nil }

        if keyword.hasPrefix("p") {
            // A pick killed between staging and committing. `--continue`
            // refuses that state outright rather than guess; the commit it
            // was making is the picked one, message and authorship as-is —
            // unless HEAD already is that commit and what is staged is not.
            let sameAs = ["log", "-1", "--format=%an%x00%ae%x00%aI%x00%B"]
            let head = try await runner.run(in: repoPath, args: sameAs + ["HEAD"])
            let original = try await runner.run(in: repoPath, args: sameAs + [picked])
            guard head.succeeded, original.succeeded, head.stdout != original.stdout else { return nil }
            return try await runner.run(in: repoPath, args: [
                "commit", "--no-verify", "--quiet", "--allow-empty", "--reuse-message=\(picked)"
            ])
        }

        // Not git's prepared `message`: a kill can come before git rewrites
        // it, leaving the previous group's there. HEAD's own message (mid-chain
        // it still carries git's `#` template) plus the squashed commit's is
        // what git was about to write; a fixup adds nothing.
        let head = try await runner.run(in: repoPath, args: ["log", "-1", "--format=%B", "HEAD"])
        try ensureSucceeded(head)
        let stripped = try await runner.run(in: repoPath, args: ["stripspace", "--strip-comments"], stdin: head.stdout)
        try ensureSucceeded(stripped)
        var message = stripped.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.hasPrefix("s") {
            let squashed = try await commitMessageAndAuthorDate(repoPath: repoPath, hash: picked).message
            message += "\n\n" + squashed
        }
        let messageFile = dir + "/smallgit-mended-message"
        try message.write(toFile: messageFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: messageFile) }
        // The chain git was keeping is the one that went wrong. Emptied, the
        // next squash starts over from HEAD's message, which is now right.
        try? "".write(toFile: dir + "/current-fixups", atomically: true, encoding: .utf8)
        return try await runner.run(in: repoPath, args: [
            "commit", "--amend", "--no-verify", "--quiet", "--allow-empty",
            "--cleanup=verbatim", "--file=\(messageFile)"
        ])
    }

    // MARK: - Rebase outcome check

    /// What the planner asked for, kept beside git's own rebase state so the
    /// result can be checked however many stops and continues it takes —
    /// and across a restart of the app.
    struct RebasePlanRecord: Codable, Sendable {
        /// Where the branch pointed before the rebase — what Undo goes back to.
        let originalHead: String
        let branch: String?
        /// The base, resolved; nil for `--root`.
        let onto: String?
        /// One commit per pick: squashes and fixups fold into theirs, drops vanish.
        let expectedCommits: Int
    }

    private static let rebasePlanFile = "smallgit-rebase-plan.json"

    private func recordRebasePlan(repoPath: String, onto: String, todo: [RebaseTodo]) async {
        guard let head = try? await currentHeadSHA(repoPath: repoPath) else { return }
        var base: String?
        if onto != "--root" {
            guard let resolved = try? await runner.run(in: repoPath, args: ["rev-parse", "--verify", "\(onto)^{commit}"]),
                  resolved.succeeded else { return }
            base = resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let record = RebasePlanRecord(
            originalHead: head,
            branch: try? await currentBranch(repoPath: repoPath),
            onto: base,
            expectedCommits: todo.filter { $0.action == .pick }.count
        )
        let path = await layout(repoPath: repoPath).gitPath(Self.rebasePlanFile)
        try? JSONEncoder().encode(record).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func clearRebasePlan(repoPath: String) async {
        let path = await layout(repoPath: repoPath).gitPath(Self.rebasePlanFile)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Once a planned rebase is over, whether what it produced matches the
    /// plan. Nil when it does, when no planned rebase was running, or while
    /// one still is. The record is consumed either way, so it is asked once.
    func checkRebaseOutcome(repoPath: String) async -> RebaseOutcomeMismatch? {
        guard await inProgressOperation(repoPath: repoPath) == nil else { return nil }
        let path = await layout(repoPath: repoPath).gitPath(Self.rebasePlanFile)
        guard let data = FileManager.default.contents(atPath: path),
              let record = try? JSONDecoder().decode(RebasePlanRecord.self, from: data)
        else { return nil }
        try? FileManager.default.removeItem(atPath: path)

        // A branch switched away from since is a result the user moved on from.
        guard (try? await currentBranch(repoPath: repoPath)) == record.branch else { return nil }
        let range = record.onto.map { ["\($0)..HEAD"] } ?? ["HEAD"]
        guard let log = try? await runner.run(in: repoPath, args: ["log", "--format=%B%x00"] + range),
              log.succeeded else { return nil }
        let messages = log.stdout
            .components(separatedBy: "\0")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // A squash git finished properly never keeps its own template.
        let leaked = messages.filter { $0.contains("# This is a combination of") }.count
        guard messages.count != record.expectedCommits || leaked > 0 else { return nil }
        return RebaseOutcomeMismatch(
            originalHead: record.originalHead,
            branch: record.branch,
            expectedCommits: record.expectedCommits,
            actualCommits: messages.count,
            leakedSquashMessages: leaked
        )
    }

    /// Puts the branch back where it was before the rebase. `--keep` so
    /// uncommitted work survives, and refuses rather than overwrite it.
    @discardableResult
    func undoRebase(repoPath: String, to originalHead: String) async throws -> GitCommandResult {
        try await runner.run(in: repoPath, args: ["reset", "--keep", originalHead])
    }

    /// POSIX single-quote escaping for values spliced into an `exec` line.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    func reset(repoPath: String, ref: String, mode: ResetMode) async throws -> GitCommandResult {
        try await runner.run(in: repoPath, args: ["reset", mode.flag, ref])
    }

    @discardableResult
    func cherryPick(repoPath: String, hash: String) async throws -> GitCommandResult {
        try await runner.run(in: repoPath, args: ["cherry-pick", hash])
    }

    @discardableResult
    func revertCommit(repoPath: String, hash: String, noCommit: Bool = false) async throws -> GitCommandResult {
        guard await inProgressOperation(repoPath: repoPath) == nil else {
            return .outcome("git revert", failure: "Finish or abort the current operation before reverting another commit.")
        }
        await clearUncommittedRevert(repoPath: repoPath)
        var args = ["revert", "--no-edit"]
        if noCommit {
            // Persist the choice before changing files, so a conflict can
            // still be finished without committing after the app restarts.
            let target = try await runner.run(in: repoPath, args: ["rev-parse", "--verify", "\(hash)^{commit}"])
            try ensureSucceeded(target)
            guard let head = try await currentHeadSHA(repoPath: repoPath) else {
                return .outcome("git revert", failure: "Could not read HEAD before reverting.")
            }
            let index = try await runner.run(in: repoPath, args: ["write-tree"])
            try ensureSucceeded(index)
            let pending = UncommittedRevert(
                head: head,
                target: target.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                indexTree: index.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let layout = await layout(repoPath: repoPath)
            try JSONEncoder().encode(pending).write(
                to: URL(fileURLWithPath: layout.gitPath(Self.uncommittedRevertFile)),
                options: .atomic
            )
            args.append("--no-commit")
        }
        args.append(hash)
        let result = try await runner.run(in: repoPath, args: args)
        if noCommit, result.succeeded {
            // Some Git versions leave REVERT_HEAD even after a clean -n
            // revert. The result is ready for ordinary review and Commit.
            let finished = try await runner.run(in: repoPath, args: ["revert", "--quit"])
            guard finished.succeeded else { return finished }
            await clearUncommittedRevert(repoPath: repoPath)
        } else if noCommit, await uncommittedRevert(repoPath: repoPath) == nil {
            await clearUncommittedRevert(repoPath: repoPath)
        }
        return result
    }

    private struct UncommittedRevert: Codable {
        let head: String
        let target: String
        let indexTree: String
    }

    private static let uncommittedRevertFile = "smallgit-revert-no-commit"

    private func uncommittedRevert(repoPath: String) async -> UncommittedRevert? {
        let layout = await layout(repoPath: repoPath)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: layout.gitPath(Self.uncommittedRevertFile))),
              let pending = try? JSONDecoder().decode(UncommittedRevert.self, from: data),
              let target = try? String(contentsOfFile: layout.gitPath("REVERT_HEAD"), encoding: .utf8),
              pending.target == target.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        guard pending.head == (try? await currentHeadSHA(repoPath: repoPath)) else { return nil }
        return pending
    }

    private func clearUncommittedRevert(repoPath: String) async {
        let layout = await layout(repoPath: repoPath)
        try? FileManager.default.removeItem(atPath: layout.gitPath(Self.uncommittedRevertFile))
    }

    @discardableResult
    func createTag(repoPath: String, name: String, message: String? = nil, hash: String? = nil) async throws -> GitCommandResult {
        var args = ["tag"]
        if let message {
            args += ["-a", name, "-m", message]
        } else {
            args.append(name)
        }
        if let hash { args.append(hash) }
        return try await runner.run(in: repoPath, args: args)
    }

    /// Delete a local tag (`git tag -d <name>`). Does not touch the remote.
    @discardableResult
    func deleteTag(repoPath: String, name: String) async throws -> GitCommandResult {
        let r = try await runner.run(in: repoPath, args: ["tag", "-d", name])
        try ensureSucceeded(r)
        return r
    }

    /// Push a single tag to a remote (`git push <remote> <tag>`), or delete it
    /// on the remote when `delete` is true (`git push <remote> --delete <tag>`).
    /// Network operation, so no run() timeout.
    @discardableResult
    func pushTag(repoPath: String, remote: String, tag: String, delete: Bool = false) async throws -> GitCommandResult {
        var args = ["push", remote]
        if delete { args.append("--delete") }
        args.append("refs/tags/\(tag)")
        let r = try await runner.run(in: repoPath, args: args, timeout: 0)
        try ensureSucceeded(r)
        return r
    }

    @discardableResult
    func removeFile(repoPath: String, path: String, cached: Bool = false) async throws -> GitCommandResult {
        var args = ["rm"]
        if cached { args.append("--cached") }
        args += ["--", path]
        let r = try await runner.run(in: repoPath, args: args)
        try ensureSucceeded(r)
        return r
    }

    /// Apply a unified-diff patch through `git apply`. Used for hunk-level
    /// staging via `DiffPatchBuilder`.
    ///
    /// - Parameters:
    ///   - patch: Full unified-diff text (must end with a trailing newline).
    ///   - cached: When `true`, applies to the index instead of the working
    ///     tree (i.e. stages the hunks).
    ///   - reverse: When `true`, applies in reverse — used to unstage hunks.
    @discardableResult
    func applyPatch(
        repoPath: String,
        patch: String,
        cached: Bool = true,
        reverse: Bool = false
    ) async throws -> GitCommandResult {
        var args = ["apply", "--whitespace=nowarn"]
        if cached { args.append("--cached") }
        if reverse { args.append("--reverse") }
        args.append("-")
        let r = try await runner.run(in: repoPath, args: args, stdin: patch)
        try ensureSucceeded(r)
        return r
    }

    // MARK: - Patches (file-level)

    /// Build a unified-diff patch covering the supplied paths' current
    /// working-tree state vs. HEAD. Combines staged + unstaged hunks
    /// into a single patch — this is what "Create Patch" surfaces in
    /// SmartGit and is the format `git apply` consumes.
    ///
    /// Tracked and untracked files are handled separately because
    /// plain `git diff` ignores untracked paths; the untracked ones
    /// run through `git diff --no-index` against `/dev/null` so they
    /// surface as "new file" hunks the patch can recreate elsewhere.
    func createPatch(repoPath: String, files: [String]) async throws -> String {
        // Partition by whether git knows about the file. `ls-files
        // --error-unmatch` returns non-zero for untracked paths, so we
        // can probe each one cheaply.
        var tracked: [String] = []
        var untracked: [String] = []
        for f in files {
            let probe = try await runner.run(
                in: repoPath,
                args: ["ls-files", "--error-unmatch", "--", f]
            )
            if probe.succeeded { tracked.append(f) } else { untracked.append(f) }
        }

        var patch = ""

        if !tracked.isEmpty {
            // `HEAD` so the patch captures *everything* in the file's
            // current state — staged + unstaged combined — relative to
            // the last commit. `--binary` so binary files round-trip.
            let r = try await runner.run(
                in: repoPath,
                args: ["diff", "HEAD", "--binary", "--no-color", "--"] + tracked
            )
            try ensureSucceeded(r)
            patch += r.stdout
        }

        for u in untracked {
            // `git diff --no-index` exits 1 whenever a diff exists,
            // which it always will here; only treat >1 as failure.
            let r = try await runner.run(
                in: repoPath,
                args: ["diff", "--no-index", "--binary", "--no-color", "--", "/dev/null", u]
            )
            if r.exitCode > 1 {
                throw GitServiceError.gitFailed(
                    command: r.command, exitCode: r.exitCode, stderr: r.stderr
                )
            }
            patch += r.stdout
        }

        return patch
    }

    /// Build a `git format-patch` style patch for a single commit.
    /// Output is the standard mbox-ish format with subject + body that
    /// `git am` can re-apply (preserves authorship).
    func createPatch(repoPath: String, commitHash: String) async throws -> String {
        let r = try await runner.run(
            in: repoPath,
            args: ["format-patch", "-1", "--stdout", commitHash]
        )
        try ensureSucceeded(r)
        return r.stdout
    }

    /// Build a patch of everything a stash entry holds, untracked files
    /// included, that `git apply` can lay onto any working tree.
    ///
    /// Plumbing rather than `git stash show -p`: with `stash.showIncludeUntracked`
    /// set, `stash show` already lists the untracked files, and adding the
    /// third parent's diff on top would put each new file in the patch twice
    /// — which `git apply` refuses outright.
    func createPatch(repoPath: String, stashIndex: Int) async throws -> String {
        let stash = Self.stashRev(stashIndex)
        let tracked = try await runner.run(
            in: repoPath,
            args: ["diff-tree", "-p", "--binary", "\(stash)^1", stash]
        )
        try ensureSucceeded(tracked)
        var patch = tracked.stdout

        // The third parent exists only for `stash push -u`. Probed first so
        // a failing `diff-tree` below is an error, not quietly a patch with
        // the new files missing.
        let untracked = Self.stashUntrackedRev(stashIndex)
        if await refExists(repoPath: repoPath, ref: untracked) {
            let r = try await runner.run(
                in: repoPath,
                args: ["diff-tree", "-p", "--binary", "--root", "--no-commit-id", untracked]
            )
            try ensureSucceeded(r)
            patch += r.stdout
        }
        return patch
    }

    /// Apply a patch file to the working tree. `threeWay` falls back
    /// to a 3-way merge when context doesn't match — needed when the
    /// target branch has drifted from where the patch was authored.
    @discardableResult
    func applyPatchFile(
        repoPath: String,
        patchPath: String,
        threeWay: Bool = false
    ) async throws -> GitCommandResult {
        var args = ["apply", "--whitespace=nowarn"]
        if threeWay { args.append("--3way") }
        args.append(patchPath)
        let r = try await runner.run(in: repoPath, args: args)
        try ensureSucceeded(r)
        return r
    }

    /// Append paths to the repo's `.gitignore`. Existing entries are kept.
    func addToGitignore(repoPath: String, patterns: [String]) async throws {
        let url = URL(fileURLWithPath: repoPath).appendingPathComponent(".gitignore")
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        existing += patterns.joined(separator: "\n") + "\n"
        try existing.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Append `patterns` to the repository's `info/exclude`: `.gitignore`'s
    /// syntax and effect, but on this machine only — the file is never
    /// committed, so nobody else's tree changes. Returns the patterns
    /// actually written; one already in the file is not added twice.
    ///
    /// Located by asking git rather than assuming `.git/info/exclude`: in a
    /// worktree or a submodule `.git` is a file, and the exclude list lives
    /// wherever it points.
    @discardableResult
    func addToLocalExclude(repoPath: String, patterns: [String]) async throws -> [String] {
        let r = try await runner.run(in: repoPath, args: ["rev-parse", "--git-path", "info/exclude"])
        try ensureSucceeded(r)
        var path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.hasPrefix("/") { path = (repoPath as NSString).appendingPathComponent(path) }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let present = Set(existing.split(separator: "\n").map(String.init))
        let added = patterns.filter { !present.contains($0) }
        guard !added.isEmpty else { return [] }
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        existing += added.joined(separator: "\n") + "\n"
        try existing.write(to: url, atomically: true, encoding: .utf8)
        return added
    }

    /// An ignore pattern naming exactly `relativePath`: anchored, so `.env`
    /// here does not also catch an `.env` three folders down, and with the
    /// trailing slash on a folder so it cannot match a file of that name.
    /// Glob characters are escaped to stand for themselves.
    static func ignorePattern(forRelativePath relativePath: String, isDirectory: Bool) -> String {
        var escaped = ""
        for ch in relativePath {
            if "\\*?[".contains(ch) { escaped.append("\\") }
            escaped.append(ch)
        }
        // A trailing space is dropped by the parser unless escaped.
        if escaped.hasSuffix(" ") { escaped.insert("\\", at: escaped.index(before: escaped.endIndex)) }
        return "/" + escaped + (isDirectory ? "/" : "")
    }

    // MARK: - Helpers

    private func ensureSucceeded(_ r: GitCommandResult) throws {
        guard r.succeeded else {
            throw GitServiceError.gitFailed(command: r.command, exitCode: r.exitCode, stderr: r.stderr)
        }
    }
}

enum ResetMode: String, Sendable {
    case soft, mixed, hard, keep, merge

    var flag: String { "--" + rawValue }
}

enum GitServiceError: Error, CustomStringConvertible {
    case notARepository(String)
    case gitFailed(command: String, exitCode: Int32, stderr: String)

    var description: String {
        switch self {
        case .notARepository(let p):
            return "Not a git repository: \(p)"
        case .gitFailed(let cmd, let code, let stderr):
            return "[\(code)] \(cmd)\n\(stderr)"
        }
    }
}
