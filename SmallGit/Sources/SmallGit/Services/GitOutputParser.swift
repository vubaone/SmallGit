import Foundation

enum GitOutputParser {

    /// What `--autostash` did during a pull.
    ///
    /// git reports all three of these on a zero exit code, so a pull that
    /// left the working tree conflicted looks exactly like a clean one to
    /// anything that only checks the status.
    enum AutostashOutcome: Equatable, Sendable {
        /// The tree was clean; nothing was stashed.
        case none
        /// Local changes were stashed and put back.
        case applied
        /// Local changes were stashed but wouldn't reapply. The stash is
        /// still in the list and the working tree holds conflict markers —
        /// the user resolves and drops it, which is what SmartGit leaves
        /// behind too.
        case conflicted
    }

    static func autostashOutcome(in output: String) -> AutostashOutcome {
        if output.contains("Applying autostash resulted in conflicts") { return .conflicted }
        if output.contains("Applied autostash") || output.contains("Created autostash") {
            return .applied
        }
        return .none
    }

    // MARK: - Status (porcelain v2)
    //
    // Reference: `git status --porcelain=v2 -z` style entries.
    // NUL-delimited records preserve paths containing whitespace, tabs,
    // quotes, and newlines. The parser also accepts newline-delimited
    // output for older tests and cached fixtures.
    //
    //   1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
    //   2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\t<origPath>
    //   u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
    //   ? <path>
    //   ! <path>

    static func parseStatus(_ output: String) -> [GitFileStatus] {
        if output.contains("\0") {
            return parseStatusZ(output)
        }
        return parseStatusLines(output.split(whereSeparator: { $0 == "\n" }).map(String.init))
    }

    private static func parseStatusZ(_ output: String) -> [GitFileStatus] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var results: [GitFileStatus] = []
        var i = 0
        while i < records.count {
            let line = records[i]
            if line.hasPrefix("2 ") {
                let parts = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count >= 10 else {
                    i += 1
                    continue
                }
                let xy = String(parts[1])
                let newPath = String(parts[9])
                let origPath = i + 1 < records.count ? records[i + 1] : nil
                results.append(GitFileStatus(
                    path: newPath,
                    indexStatus: String(xy.prefix(1)),
                    workTreeStatus: String(xy.suffix(1)),
                    originalPath: origPath,
                    // Field 3 of a v2 record: `N...` for a file, `S<c><m><u>`
                    // for a submodule. Both a moved pointer and a dirty
                    // checkout arrive as `.M` in `XY`; this is what tells
                    // them apart.
                    submodule: SubmoduleFileState(field: String(parts[2]))
                ))
                i += 2
                continue
            }
            results.append(contentsOf: parseStatusLines([line]))
            i += 1
        }
        return results
    }

    private static func parseStatusLines(_ lines: [String]) -> [GitFileStatus] {
        var results: [GitFileStatus] = []
        for line in lines {
            guard !line.isEmpty else { continue }

            if line.hasPrefix("1 ") {
                let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count >= 9 else { continue }
                let xy = String(parts[1])
                let path = String(parts[8])
                let index = String(xy.prefix(1))
                let work  = String(xy.suffix(1))
                results.append(GitFileStatus(
                    path: path,
                    indexStatus: index,
                    workTreeStatus: work,
                    // Field 3: `N...` for a file, `S<c><m><u>` for a
                    // submodule. A moved pointer and a dirty checkout both
                    // arrive as `.M` in `XY`; this is what tells them apart.
                    submodule: SubmoduleFileState(field: String(parts[2]))
                ))
            } else if line.hasPrefix("2 ") {
                let parts = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count >= 10 else { continue }
                let xy = String(parts[1])
                let pathField = String(parts[9])
                let segs = pathField.split(separator: "\t", maxSplits: 1).map(String.init)
                let newPath = segs.first ?? pathField
                let origPath = segs.count > 1 ? segs[1] : nil
                results.append(GitFileStatus(
                    path: newPath,
                    indexStatus: String(xy.prefix(1)),
                    workTreeStatus: String(xy.suffix(1)),
                    originalPath: origPath,
                    submodule: SubmoduleFileState(field: String(parts[2]))
                ))
            } else if line.hasPrefix("u ") {
                let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count >= 11 else { continue }
                let xy = String(parts[1])
                let path = String(parts[10])
                // Keep the real letters rather than flattening every
                // unmerged path to `UU`. `DU` / `UD` / `DD` say a side
                // deleted the file, which changes both what the State
                // column should read and what "take ours" can even mean —
                // there is no stage to check out on the deleted side.
                results.append(GitFileStatus(
                    path: path,
                    indexStatus: String(xy.prefix(1)),
                    workTreeStatus: String(xy.suffix(1)),
                    isConflict: true
                ))
            } else if line.hasPrefix("? ") {
                results.append(GitFileStatus(
                    path: String(line.dropFirst(2)),
                    indexStatus: "?",
                    workTreeStatus: "?"
                ))
            } else if line.hasPrefix("! ") {
                results.append(GitFileStatus(
                    path: String(line.dropFirst(2)),
                    indexStatus: "!",
                    workTreeStatus: "!"
                ))
            }
        }
        return results
    }

    // MARK: - Index flags (ls-files -v)

    /// Paths flagged `assume-unchanged` in `git ls-files -v -z` output.
    ///
    /// Each record is `<tag><space><path>`, NUL-terminated (newline
    /// records are accepted too, for fixtures and for a caller that
    /// forgets `-z`). The flag is encoded as *case*: git prints the tag
    /// lowercase when the entry is assume-unchanged, so `h` is a plain
    /// tracked file that is flagged and `s` is a skip-worktree file that
    /// is flagged, while uppercase `H` and `S` are the same entries
    /// without it. Matching on `h` alone would miss every flagged file
    /// that is anything other than ordinarily cached.
    static func parseAssumeUnchanged(_ output: String) -> [String] {
        output
            .split(whereSeparator: { $0 == "\0" || $0 == "\n" })
            .compactMap { record in
                guard let tag = record.first,
                      tag.isLetter, tag.isLowercase,
                      record.dropFirst().first == " " else { return nil }
                let path = record.dropFirst(2)
                return path.isEmpty ? nil : String(path)
            }
    }

    // MARK: - Blame (line-porcelain)
    //
    // `git blame --line-porcelain <file>` emits, for EVERY line:
    //   <40-hex sha> <origLine> <finalLine> [<groupCount>]
    //   author <name>
    //   author-mail <email>
    //   author-time <unix>
    //   author-tz <tz>
    //   committer ...
    //   summary <subject>
    //   ...
    //   boundary            (only on boundary commits)
    //   filename <path>
    //   \t<source line content>
    //
    // Unlike `--porcelain`, the full block repeats per line, so each record
    // is self-contained: we accumulate fields until the TAB-prefixed content
    // line, emit, and reset the per-line flag.
    static func parseBlame(_ output: String) -> [GitBlameLine] {
        var result: [GitBlameLine] = []
        var hash = ""
        var author = ""
        var summary = ""
        var time: TimeInterval?
        var finalLine = 0
        var isBoundary = false

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("\t") {
                result.append(GitBlameLine(
                    lineNumber: finalLine,
                    commitHash: hash,
                    shortHash: String(hash.prefix(8)),
                    author: author,
                    date: time.map { Date(timeIntervalSince1970: $0) },
                    summary: summary,
                    content: String(line.dropFirst()),
                    isBoundary: isBoundary
                ))
                isBoundary = false
            } else if line.hasPrefix("author-time ") {
                time = TimeInterval(line.dropFirst("author-time ".count))
            } else if line.hasPrefix("author ") {
                author = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("summary ") {
                summary = String(line.dropFirst("summary ".count))
            } else if line == "boundary" {
                isBoundary = true
            } else {
                // Candidate SHA header: "<sha> <orig> <final> [<count>]".
                let parts = line.split(separator: " ")
                if let first = parts.first,
                   first.count >= 7,
                   first.allSatisfy({ $0.isHexDigit }),
                   parts.count >= 3 {
                    hash = String(first)
                    finalLine = Int(parts[2]) ?? finalLine
                }
            }
        }
        return result
    }

    // MARK: - Log
    //
    // Format: %H\0%h\0%s\0%an\0%ae\0%aI\0%D\0%P
    // Records separated by \n. The final \0%P field is space-separated
    // parent SHAs (empty for the root commit). Tolerant to the previous
    // 7-field format so old disk caches still decode.
    static func parseLog(_ output: String) -> [GitCommit] {
        output.split(whereSeparator: { $0 == "\n" }).compactMap { raw in
            let line = String(raw)
            guard !line.isEmpty else { return nil }
            let parts = line.split(separator: "\0", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6 else { return nil }
            let date = DateFormatters.parseISO(parts[5]) ?? Date()
            let refs = parts.count > 6 ? parts[6] : ""
            let parents: [String]
            if parts.count > 7 {
                parents = parts[7]
                    .split(separator: " ")
                    .map(String.init)
                    .filter { !$0.isEmpty }
            } else {
                parents = []
            }
            return GitCommit(
                hash: parts[0],
                shortHash: parts[1],
                subject: parts[2],
                authorName: parts[3],
                authorEmail: parts[4],
                date: date,
                refs: refs,
                parentHashes: parents
            )
        }
    }

    // MARK: - Branches
    //
    // Format: %(refname:short)\0%(upstream:short)\0%(worktreepath)\0%(HEAD)
    //
    // For remote branches, git emits two pieces of noise we don't want in
    // the sidebar:
    //   - "<remote>/HEAD"  the symbolic HEAD ref itself
    //   - "<remote>"       the bare alias git sometimes resolves the
    //                      symbolic ref to (depends on git version and
    //                      remote config)
    // Both are filtered when `remote == true` so the panel shows only
    // real branch refs.
    static func parseBranches(_ output: String, remote: Bool = false) -> [GitBranch] {
        output.split(whereSeparator: { $0 == "\n" }).compactMap { raw in
            let line = String(raw)
            guard !line.isEmpty else { return nil }
            let parts = line.split(separator: "\0", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard let name = parts.first, !name.isEmpty else { return nil }
            if remote, isRemoteHeadRef(name) { return nil }
            let upstream = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            let worktree = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
            let head = parts.count > 3 && parts[3] == "*"
            let remoteName = parts.count > 4 && !parts[4].isEmpty ? parts[4] : nil
            let track = parts.count > 5 && !parts[5].isEmpty ? parts[5] : nil
            return GitBranch(
                name: name,
                upstream: upstream,
                worktreePath: worktree,
                isHead: head,
                isRemote: remote,
                remoteName: remoteName,
                upstreamTrack: track
            )
        }
    }

    /// `true` if `name` is the symbolic HEAD pointer for a remote (`origin/HEAD`)
    /// or the bare remote alias git emits when resolving that pointer (`origin`).
    /// Exposed for unit testing.
    static func isRemoteHeadRef(_ name: String) -> Bool {
        if name.hasSuffix("/HEAD") { return true }
        if !name.contains("/") { return true }
        return false
    }

    // MARK: - Diff (unified)

    /// `diff --git a/src/main.swift b/src/main.swift` → `src/main.swift`.
    ///
    /// The post-image (`b/`) side is preferred: for a rename it is the name
    /// the file now has, and for a deletion git still writes it.
    static func pathFromGitDiffHeader(_ line: String) -> String? {
        // Paths containing spaces are quoted by git, and the quoted form has
        // to be tried first — ` b/` also appears inside ` "b/…"`.
        if let range = line.range(of: " \"b/", options: .backwards) {
            let tail = line[range.upperBound...]
            let path = tail.hasSuffix("\"") ? String(tail.dropLast()) : String(tail)
            return path.isEmpty ? nil : path
        }
        guard let range = line.range(of: " b/", options: .backwards) else { return nil }
        let path = String(line[range.upperBound...])
        return path.isEmpty ? nil : path
    }

    /// `--name-status` rows (`M\tpath`, `R100\told\tnew`, …) as
    /// `GitFileStatus` values, so a commit's or a stash's file list renders
    /// with the same rows the working-tree Files table uses. The worktree
    /// letter is left as "." — these files are a snapshot, not a state the
    /// user can stage.
    static func parseNameStatus(_ output: String) -> [GitFileStatus] {
        var out: [GitFileStatus] = []
        for raw in output.split(whereSeparator: { $0 == "\n" }) {
            let line = String(raw)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let statusLetter = parts.first?.first.map(String.init) else { continue }
            // Renames / copies have an extra "newPath\toldPath" pair:
            //   "R100\told.swift\tnew.swift"
            let path: String
            let origPath: String?
            if statusLetter == "R" || statusLetter == "C", parts.count >= 3 {
                path = parts[2]
                origPath = parts[1]
            } else if parts.count >= 2 {
                path = parts[1]
                origPath = nil
            } else {
                continue
            }
            out.append(GitFileStatus(
                path: path,
                indexStatus: statusLetter,
                workTreeStatus: ".",
                originalPath: origPath
            ))
        }
        return out
    }

    static func parseDiff(_ output: String) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var current: DiffHunk?
        var oldLine = 0
        var newLine = 0
        /// The file whose hunks are currently being read. A stash or commit
        /// diff is several files concatenated, so this changes as we go.
        var currentFile: String?
        /// Set while the base85 payload of a `GIT binary patch` is being
        /// walked past. Those lines are neither headers nor diff content —
        /// left to the chain below they would be read as context.
        var skippingBinaryPayload = false

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                skippingBinaryPayload = false
                // Anchored on `diff --git` rather than on `+++`, because a
                // deleted line whose content happens to start with `--` is
                // indistinguishable from a `---` header once the leading `-`
                // is in place. `diff --git` has no such collision: a context
                // line is prefixed with a space and an added/removed one with
                // `+`/`-`, so none of them can begin with `diff `.
                currentFile = pathFromGitDiffHeader(line)
                continue
            }
            if skippingBinaryPayload { continue }
            // Binary files have no hunks: git says so in one line and moves
            // on. Recorded per file rather than for the whole output, because
            // a stash or a commit is several files at once — one image in it
            // used to turn the entire diff into "binary", hiding every text
            // change beside it.
            if isBinaryMarker(line) {
                if let h = current { hunks.append(h) }
                current = nil
                hunks.append(DiffHunk(
                    oldStart: 0, oldCount: 0,
                    newStart: 0, newCount: 0,
                    lines: [DiffLine(type: .context, content: "(binary file — preview not available)")],
                    file: currentFile
                ))
                skippingBinaryPayload = true
                continue
            }
            if line.hasPrefix("@@") {
                if let h = current { hunks.append(h) }
                let header = parseHunkHeader(line)
                oldLine = header.oldStart
                newLine = header.newStart
                current = DiffHunk(
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount,
                    lines: [],
                    file: currentFile
                )
            } else if line.hasPrefix("\\ No newline") {
                // Marker for the line just emitted — its file has no trailing
                // newline. Flag the preceding line so DiffPatchBuilder can
                // reproduce the marker; without it `git apply` rejects the
                // patch ("patch does not apply").
                if let lastIdx = current?.lines.indices.last {
                    current?.lines[lastIdx].noNewlineAtEOF = true
                }
            } else if line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity") || line.hasPrefix("rename ") {
                continue
            } else if line.hasPrefix("-") {
                current?.lines.append(DiffLine(
                    type: .del,
                    content: String(line.dropFirst()),
                    oldLineNumber: oldLine,
                    newLineNumber: nil
                ))
                oldLine += 1
            } else if line.hasPrefix("+") {
                current?.lines.append(DiffLine(
                    type: .add,
                    content: String(line.dropFirst()),
                    oldLineNumber: nil,
                    newLineNumber: newLine
                ))
                newLine += 1
            } else if line.hasPrefix(" ") {
                // Real context lines are always prefixed with a single space
                // (an empty line in the file appears as exactly " "). A truly
                // empty raw line is the trailing-newline artefact of
                // `String.split(separator:omittingEmptySubsequences:false)`
                // and must NOT become a context entry — git apply rejects
                // patches with stray trailing context that doesn't match.
                current?.lines.append(DiffLine(
                    type: .context,
                    content: String(line.dropFirst()),
                    oldLineNumber: oldLine,
                    newLineNumber: newLine
                ))
                oldLine += 1
                newLine += 1
            }
        }
        if let h = current { hunks.append(h) }
        return hunks
    }

    /// `true` if the raw diff output is git's "Binary files differ"
    /// notice (or a `GIT binary patch` block). Exposed internal so we can
    /// keep the heuristic in one place.
    static func isBinaryDiff(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n").contains { isBinaryMarker(String($0)) }
    }

    /// One line of git's way of saying "no textual diff for this file".
    private static func isBinaryMarker(_ line: String) -> Bool {
        (line.hasPrefix("Binary files ") && line.hasSuffix(" differ"))
            || line.hasPrefix("GIT binary patch")
    }

    private struct HunkHeader {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
    }

    private static func parseHunkHeader(_ line: String) -> HunkHeader {
        // @@ -oldStart,oldCount +newStart,newCount @@
        var oldStart = 0, oldCount = 1, newStart = 0, newCount = 1
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = nil
        _ = scanner.scanString("@@")
        _ = scanner.scanCharacters(from: .whitespaces)
        _ = scanner.scanString("-")
        oldStart = scanner.scanInt() ?? 0
        if scanner.scanString(",") != nil {
            oldCount = scanner.scanInt() ?? 1
        }
        _ = scanner.scanCharacters(from: .whitespaces)
        _ = scanner.scanString("+")
        newStart = scanner.scanInt() ?? 0
        if scanner.scanString(",") != nil {
            newCount = scanner.scanInt() ?? 1
        }
        return HunkHeader(
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount
        )
    }

    // MARK: - Stash list
    //
    // Format: %gd%x00%gs%x00%aI  (stash@{N}  message  date)
    static func parseStashList(_ output: String) -> [GitStash] {
        output.split(whereSeparator: { $0 == "\n" }).enumerated().compactMap { idx, raw in
            let line = String(raw)
            guard !line.isEmpty else { return nil }
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            let message = parts.count > 1 ? parts[1] : line
            let date = parts.count > 2 ? DateFormatters.parseISO(parts[2]) : nil
            return GitStash(
                index: idx,
                message: message,
                branch: extractBranchFromStashMessage(message),
                date: date
            )
        }
    }

    // MARK: - Reflog
    //
    // Format: %H%x09%h%x09%gd%x09%gs%x09%cI
    //   %H   full hash
    //   %h   short hash
    //   %gd  reflog selector (HEAD@{N})
    //   %gs  reflog subject ("commit: foo", "checkout: moving from a to b", ...)
    //   %cI  committer ISO-8601 date
    static func parseReflog(_ output: String) -> [GitReflogEntry] {
        output.split(whereSeparator: { $0 == "\n" }).enumerated().compactMap { idx, raw in
            let line = String(raw)
            guard !line.isEmpty else { return nil }
            let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count >= 4 else { return nil }
            let subject = parts[3]
            let date = parts.count > 4 ? DateFormatters.parseISO(parts[4]) : nil
            return GitReflogEntry(
                index: idx,
                selector: parts[2],
                hash: parts[0],
                shortHash: parts[1],
                subject: subject,
                action: ReflogAction(subject: subject),
                date: date
            )
        }
    }

    // MARK: - Maintenance
    //
    // `git count-objects -v` prints `key: value` lines. `size` is the
    // loose-object footprint, `size-pack` the packed footprint — both
    // in KiB. Their sum approximates the object database's disk usage.
    static func parseObjectDatabaseSizeKiB(_ output: String) -> Int64 {
        var kib: Int64 = 0
        for rawLine in output.split(whereSeparator: { $0 == "\n" }) {
            let parts = rawLine.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard key == "size" || key == "size-pack" else { continue }
            kib += Int64(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return kib
    }

    // MARK: - Worktrees
    //
    // `git worktree list --porcelain` prints one attribute-per-line
    // block per worktree, blocks separated by a blank line:
    //
    //   worktree /path/to/main
    //   HEAD abc123…
    //   branch refs/heads/main
    //
    //   worktree /path/to/wt
    //   HEAD def456…
    //   detached
    //   locked reason text        (optional; reason may be absent)
    //   prunable gitdir file points to non-existent location
    //
    // The first block is always the main worktree.
    static func parseWorktrees(_ output: String) -> [GitWorktree] {
        let blocks = output
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return blocks.enumerated().compactMap { idx, block in
            var path: String?
            var head = ""
            var branch: String?
            var locked = false
            var lockReason: String?
            var prunable = false
            var bare = false

            for rawLine in block.split(whereSeparator: { $0 == "\n" }) {
                let line = String(rawLine)
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("HEAD ") {
                    head = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst("branch ".count))
                    branch = ref.hasPrefix("refs/heads/")
                        ? String(ref.dropFirst("refs/heads/".count))
                        : ref
                } else if line == "locked" {
                    locked = true
                } else if line.hasPrefix("locked ") {
                    locked = true
                    lockReason = String(line.dropFirst("locked ".count))
                } else if line == "prunable" || line.hasPrefix("prunable ") {
                    prunable = true
                } else if line == "bare" {
                    bare = true
                }
                // "detached" carries no extra data — branch stays nil.
            }

            guard let path else { return nil }
            return GitWorktree(
                path: path,
                headSHA: head,
                branch: branch,
                isMain: idx == 0,
                isLocked: locked,
                lockReason: lockReason,
                isPrunable: prunable,
                isBare: bare
            )
        }
    }

    /// Extract the branch name from a `git stash` reflog message.
    /// Handles both "On <branch>: ..." and "WIP on <branch>: ..." forms,
    /// case-insensitively. Returns `nil` if the message doesn't follow
    /// either pattern (e.g. a custom user message).
    private static func extractBranchFromStashMessage(_ message: String) -> String? {
        let pattern = #"^(?:WIP )?[Oo]n ([^:]+):"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(message.startIndex..., in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              match.numberOfRanges >= 2,
              let group = Range(match.range(at: 1), in: message) else { return nil }
        return String(message[group])
    }

    // MARK: - Submodules

    /// Parses `git submodule status`.
    ///
    /// Each line is `<marker><sha> <path>` with an optional ` (<describe>)`.
    /// The marker is a single character and is significant: a space means the
    /// submodule sits exactly where the parent points, and the others each
    /// mean something the user needs to act on differently.
    ///
    /// Paths are taken verbatim rather than split on whitespace: a submodule
    /// can live at `vendor/my lib`, and splitting would truncate it — the
    /// describe suffix is stripped from the end instead.
    static func parseSubmoduleStatus(_ output: String) -> [(path: String, sha: String, describe: String?, state: GitSubmodule.State)] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let line = String(raw)
            guard let marker = line.first else { return nil }

            let state: GitSubmodule.State
            switch marker {
            case " ": state = .current
            case "-": state = .uninitialized
            case "+": state = .modified
            case "U": state = .conflicted
            // Anything else is not a status line we understand. Skipping is
            // right: git prefixes warnings and errors to the same stream, and
            // one of those must not become a phantom submodule row.
            default:  return nil
            }

            let rest = line.dropFirst()
            guard let separator = rest.firstIndex(of: " ") else { return nil }
            let sha = String(rest[rest.startIndex..<separator])
            guard !sha.isEmpty else { return nil }

            var remainder = String(rest[rest.index(after: separator)...])
            var describe: String?
            // The describe suffix is the *last* parenthesised group, so a path
            // that itself contains parentheses survives.
            if remainder.hasSuffix(")"), let open = remainder.lastIndex(of: "(") {
                describe = String(remainder[remainder.index(after: open)..<remainder.index(before: remainder.endIndex)])
                remainder = String(remainder[remainder.startIndex..<open])
            }
            let path = remainder.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }

            return (path: path, sha: sha, describe: describe, state: state)
        }
    }

    /// Parses the `.gitmodules` file into path → (name, url).
    ///
    /// Hand-rolled rather than run through `git config -f .gitmodules`: the
    /// file is plain INI, reading it costs no subprocess, and a repository
    /// whose `.gitmodules` is missing or malformed should degrade to "no URL
    /// known" rather than failing the whole listing.
    static func parseGitmodules(_ contents: String) -> [String: (name: String, url: String?)] {
        var out: [String: (name: String, url: String?)] = [:]
        var currentName: String?
        var currentPath: String?
        var currentURL: String?

        func flush() {
            if let path = currentPath {
                out[path] = (name: currentName ?? path, url: currentURL)
            }
            currentName = nil
            currentPath = nil
            currentURL = nil
        }

        for raw in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[submodule") {
                flush()
                // `[submodule "name"]` — the quoted part is the name.
                if let first = line.firstIndex(of: "\""),
                   let last = line.lastIndex(of: "\""), first < last {
                    currentName = String(line[line.index(after: first)..<last])
                }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "path": currentPath = value
            case "url":  currentURL = value.isEmpty ? nil : value
            default:     break
            }
        }
        flush()
        return out
    }

    /// Joins the two sources into the model the UI uses.
    ///
    /// Driven by `status`, not by `.gitmodules`: the index is the authority on
    /// which submodules the parent actually has. One that has been removed
    /// from `.gitmodules` but not from the index still exists and still needs
    /// to be visible — that state is precisely when someone goes looking.
    static func mergeSubmodules(
        status: String,
        gitmodules: String
    ) -> [GitSubmodule] {
        let records = parseGitmodules(gitmodules)
        return parseSubmoduleStatus(status).map { entry in
            let record = records[entry.path]
            return GitSubmodule(
                path: entry.path,
                name: record?.name ?? entry.path,
                url: record?.url,
                sha: entry.sha,
                describe: entry.describe,
                state: entry.state
            )
        }
    }
}
