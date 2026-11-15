import Foundation

/// Monotonic millisecond stopwatch.
///
/// `DispatchTime` rather than `Date`: the wall clock can be stepped by NTP or
/// by the user mid-operation, and a duration that comes back negative because
/// the clock moved is worse than no duration at all.
struct LogClock: Sendable {
    private let start = DispatchTime.now()

    var elapsedMs: Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    var elapsed: TimeInterval { elapsedMs / 1000 }
}

/// Call site for diagnostics. Everything funnels into `LogStore.shared`.
///
/// A facade rather than direct `LogStore` calls so instrumentation reads as
/// one line at the point of interest, and so the classification and redaction
/// rules live in one place instead of being re-derived at each of them.
enum Log {

    /// Where records go. Always `LogStore.shared` in the app — the app never
    /// assigns this.
    ///
    /// It is a `var` so tests can point the instrumentation at a temporary
    /// store instead of the user's real log. Without that seam the only way
    /// to check that `ProcessRunner` and `DiskCache` are actually wired up is
    /// to run the app and read `~/Library/Logs`, and a test that leaves its
    /// fixtures in the user's diagnostics is worse than no test.
    ///
    /// `nonisolated(unsafe)` because `LogStore` handles its own locking; the
    /// unchecked part is the reassignment, which happens only from a test's
    /// `setUp` before anything else is running.
    nonisolated(unsafe) static var store: LogStore = .shared

    static func record(_ record: LogRecord) {
        store.record(record)
    }

    // MARK: - git

    /// Logs one git invocation, filed under `network` or `git` by what the
    /// subcommand actually does.
    ///
    /// `args` is the full argument vector as handed to the executable,
    /// including the `-C <repo>` prefix — `GitCommandKind` skips the global
    /// options itself rather than making every caller pre-trim them.
    static func git(
        args: [String],
        durationMs: Double,
        bytes: Int? = nil,
        outcome: LogOutcome,
        message: String? = nil
    ) {
        let subcommand = GitCommandKind.subcommand(of: args) ?? "?"
        record(LogRecord(
            category: GitCommandKind.isNetwork(args: args) ? .network : .git,
            operation: "git \(subcommand)",
            detail: LogRedaction.scrub(args.joined(separator: " ")).truncated(to: 200),
            ms: durationMs,
            bytes: bytes,
            outcome: outcome,
            message: message.map { LogRedaction.scrub($0).truncated(to: 300) }
        ))
    }

    // MARK: - Our own I/O

    static func disk(
        _ operation: String,
        detail: String = "",
        ms: Double? = nil,
        bytes: Int? = nil,
        outcome: LogOutcome = .ok,
        message: String? = nil
    ) {
        record(LogRecord(
            category: .disk,
            operation: operation,
            detail: LogRedaction.scrub(detail).truncated(to: 200),
            ms: ms,
            bytes: bytes,
            outcome: outcome,
            message: message.map { LogRedaction.scrub($0).truncated(to: 300) }
        ))
    }

    static func watcher(_ operation: String, detail: String = "", count: Int? = nil) {
        record(LogRecord(
            category: .watcher,
            operation: operation,
            detail: LogRedaction.scrub(detail).truncated(to: 200),
            bytes: nil,
            outcome: .ok,
            message: count.map { "\($0) paths" }
        ))
    }

    static func app(_ operation: String, detail: String = "") {
        record(LogRecord(
            category: .app,
            operation: operation,
            detail: LogRedaction.scrub(detail).truncated(to: 200)
        ))
    }
}

// MARK: - Classification

/// Decides whether a git invocation touches the network.
///
/// The distinction cannot be recovered later from a duration alone, and it is
/// the first question worth asking of a slow operation: `git log` taking two
/// seconds is a repository-size problem, `git fetch` taking two seconds is
/// just the network being the network.
enum GitCommandKind {

    /// Subcommands that always talk to a remote.
    static let alwaysNetwork: Set<String> = [
        "fetch", "pull", "push", "clone", "ls-remote"
    ]

    /// Subcommands that talk to a remote only in some forms — `git remote -v`
    /// is local, `git remote update` is not.
    private static let conditionalNetwork: [String: Set<String>] = [
        "remote": ["update", "prune"],
        "submodule": ["update", "sync"]
    ]

    /// Global options that swallow the argument after them, so the scan for
    /// the subcommand doesn't mistake a repository path for `status`.
    private static let optionsTakingAValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace"]

    /// The subcommand, skipping git's own global options.
    static func subcommand(of args: [String]) -> String? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            guard arg.hasPrefix("-") else { return arg }
            // `--git-dir=x` carries its value; `--git-dir x` doesn't.
            if optionsTakingAValue.contains(arg) {
                index += 2
            } else {
                index += 1
            }
        }
        return nil
    }

    static func isNetwork(args: [String]) -> Bool {
        guard let subcommand = subcommand(of: args) else { return false }
        if alwaysNetwork.contains(subcommand) { return true }
        guard let triggers = conditionalNetwork[subcommand] else { return false }
        return args.contains { triggers.contains($0) }
    }
}

// MARK: - Redaction

/// Strips secrets and personal paths from anything bound for the log.
///
/// This is not optional politeness. A log the user is invited to read is a log
/// they will paste into a bug report, and `git push` against an HTTPS remote
/// carries the credential in the URL — so an unscrubbed log hands out a token
/// the moment it is shared.
enum LogRedaction {

    static func scrub(_ text: String) -> String {
        abbreviatingHome(in: strippingURLCredentials(in: text))
    }

    /// `https://user:token@host/repo` → `https://user:***@host/repo`.
    ///
    /// The username is kept: it is rarely a secret and it is often exactly
    /// what you need to see when diagnosing "why is it authenticating as
    /// someone else".
    static func strippingURLCredentials(in text: String) -> String {
        guard text.contains("://") else { return text }
        var out = ""
        var rest = Substring(text)

        while let schemeRange = rest.range(of: "://") {
            out += rest[rest.startIndex..<schemeRange.upperBound]
            rest = rest[schemeRange.upperBound...]

            // The authority ends at the first `/`, `?`, `#` or whitespace. A
            // `@` before that is a credential separator; a `@` after it is
            // just part of a path and must be left alone.
            let authorityEnd = rest.firstIndex { "/?# \t".contains($0) } ?? rest.endIndex
            let authority = rest[rest.startIndex..<authorityEnd]

            guard let atIndex = authority.lastIndex(of: "@") else { continue }
            let userInfo = authority[authority.startIndex..<atIndex]
            guard let colonIndex = userInfo.firstIndex(of: ":") else { continue }

            out += userInfo[userInfo.startIndex...colonIndex]
            out += "***"
            rest = rest[atIndex...]
        }
        return out + rest
    }

    /// `/Users/someone/Work/repo` → `~/Work/repo`.
    static func abbreviatingHome(in text: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}

private extension String {
    /// Caps a field's contribution to the log.
    ///
    /// The budget is fixed at 5 MB, so an unbounded field trades history for
    /// detail: one `git log --format=…` command line left whole can be longer
    /// than ten complete records.
    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit)) + "…"
    }
}
