import Foundation

/// One thing a streamed command has to say: a line of output, or how it
/// ended. The exit code arrives in-band, as the last event, so a consumer
/// reading the stream to completion never has to ask separately.
enum ShellEvent: Sendable {
    case line(String)
    case exit(Int32)
}

enum ProcessError: Error, CustomStringConvertible, Sendable {
    case launchFailed(String)
    case timedOut(String)
    case gitNotFound

    var description: String {
        switch self {
        case .launchFailed(let msg): return "Process launch failed: \(msg)"
        case .timedOut(let cmd):     return "Process timed out: \(cmd)"
        case .gitNotFound:           return "git executable not found"
        }
    }
}

/// Thin async wrapper around `Process` for git CLI invocations.
/// Actor isolation guarantees serialized access to the runner's state;
/// concurrent git invocations spawn independent processes inside `run`.
actor ProcessRunner {
    static let shared = ProcessRunner()

    private var resolvedGitPath: String?
    private let importsUserShellEnvironment: Bool

    init(gitPath: String? = nil, importsUserShellEnvironment: Bool = true) {
        self.resolvedGitPath = gitPath
        self.importsUserShellEnvironment = importsUserShellEnvironment
    }

    func setGitPath(_ path: String?) {
        self.resolvedGitPath = path
    }

    /// Standard package-manager bin dirs that a GUI-launched process won't
    /// inherit on its PATH. Apple Silicon Homebrew, Intel Homebrew, and
    /// MacPorts respectively — the usual homes of `git-lfs` and other tools
    /// git hooks shell out to.
    private static let extraPathDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    /// Return `current` with `extraPathDirs` appended (dedup'd), so subprocess
    /// hooks can find tools like `git-lfs` even when launched from Finder.
    static func augmentedPath(_ current: String?) -> String {
        var entries = (current ?? "").split(separator: ":").map(String.init)
        let existing = Set(entries)
        for dir in extraPathDirs where !existing.contains(dir) {
            entries.append(dir)
        }
        return entries.joined(separator: ":")
    }

    // MARK: - User shell environment

    /// A GUI launched from Finder/Dock does not inherit variables exported by
    /// the user's shell startup files. That is particularly visible for
    /// HTTPS_PROXY/NO_PROXY: `git fetch` in Terminal and the same fetch in the
    /// app can take different network routes and receive different answers.
    ///
    /// Start one interactive login shell per app session and capture its
    /// environment. The result is shared by every ProcessRunner so toolbar
    /// Git operations, hooks, and the built-in Terminal all see the same
    /// proxy/PATH/SSH-agent setup as a newly opened macOS Terminal window.
    private func userShellEnvironment() async -> [String: String] {
        guard importsUserShellEnvironment else {
            return ProcessInfo.processInfo.environment
        }
        return await UserShellEnvironment.shared.load()
    }

    private static let shellEnvironmentMarker = "SMALLGIT_ENVIRONMENT_START_7D88E2C9"
    private static let proxyEnvironmentKeys = [
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy"
    ]

    /// Parse only bytes after our NUL-delimited marker. Interactive startup
    /// files sometimes print banners or tool warnings; neither belongs in an
    /// environment key, and none of it should leak into the Output panel.
    static func parseShellEnvironment(_ data: Data) -> [String: String]? {
        var marker = Data([0])
        marker.append(contentsOf: shellEnvironmentMarker.utf8)
        marker.append(0)
        guard let markerRange = data.range(of: marker) else { return nil }

        var environment: [String: String] = [:]
        for entry in data[markerRange.upperBound...].split(separator: 0) {
            guard let equals = entry.firstIndex(of: UInt8(ascii: "=")),
                  equals != entry.startIndex,
                  let key = String(data: Data(entry[..<equals]), encoding: .utf8),
                  let value = String(data: Data(entry[entry.index(after: equals)...]), encoding: .utf8)
            else { continue }
            environment[key] = value
        }
        return environment.isEmpty ? nil : environment
    }

    /// Kept separate from the shared runner to avoid recursively asking for
    /// the shell environment while the command that discovers it is running.
    /// A file-link launcher, IDE, or parent shell can give SmallGit private
    /// proxy variables that a separately launched Terminal does not have.
    /// Begin with launchd's values for this small family of transport keys,
    /// then let the interactive shell profile deliberately add/change them.
    /// This keeps a launcher's own proxy from silently changing Git's route.
    static func shellLaunchEnvironment(
        inherited: [String: String],
        launchdProxy: [String: String]
    ) -> [String: String] {
        var environment = inherited
        for key in proxyEnvironmentKeys { environment.removeValue(forKey: key) }
        for (key, value) in launchdProxy where proxyEnvironmentKeys.contains(key) {
            environment[key] = value
        }
        return environment
    }

    static func captureUserShellEnvironment() async -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let configuredShell = inherited["SHELL"] ?? ""
        let shell = FileManager.default.isExecutableFile(atPath: configuredShell)
            ? configuredShell
            : "/bin/zsh"
        let probe = ProcessRunner(importsUserShellEnvironment: false)
        var launchdProxy: [String: String] = [:]
        if FileManager.default.isExecutableFile(atPath: "/bin/launchctl") {
            for key in proxyEnvironmentKeys {
                guard let result = try? await probe.runRaw(
                    executable: "/bin/launchctl",
                    args: ["getenv", key],
                    cwd: nil,
                    timeout: 1,
                    inheritUserShellEnvironment: false
                ) else { continue }
                let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { launchdProxy[key] = value }
            }
        }
        let launchEnvironment = shellLaunchEnvironment(
            inherited: inherited,
            launchdProxy: launchdProxy
        )
        let command = "printf '\\000\(shellEnvironmentMarker)\\000'; /usr/bin/env -0"
        guard let raw = try? await probe.runRaw(
            executable: shell,
            args: ["-lic", command],
            cwd: nil,
            timeout: 5,
            inheritUserShellEnvironment: false,
            baseEnvironment: launchEnvironment
        ) else { return launchEnvironment }
        return parseShellEnvironment(Data(raw.stdout.utf8)) ?? launchEnvironment
    }

    /// The environment a child process gets: a base, with `PATH` widened and
    /// the caller's own variables last.
    ///
    /// A `.app` launched from Finder/Dock/Xcode inherits only the bare macOS
    /// PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) — Homebrew/MacPorts dirs are
    /// missing. git itself we resolve by absolute path, but the hooks git
    /// spawns (e.g. the LFS `post-checkout`, which does `command -v git-lfs
    /// || exit 2`) run with this PATH and fail to find their tools,
    /// surfacing as a non-zero exit on otherwise successful commands. The
    /// common package-manager bins go on the end so git-lfs and friends
    /// resolve regardless of how we were launched.
    private static func mergedEnvironment(
        base: [String: String],
        overrides: [String: String]?
    ) -> [String: String] {
        var merged = base
        merged["PATH"] = augmentedPath(merged["PATH"])
        if let overrides {
            for (key, value) in overrides { merged[key] = value }
        }
        return merged
    }

    /// Locate the git executable. Caches result.
    func gitExecutablePath() async throws -> String {
        if let p = resolvedGitPath, FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            resolvedGitPath = c
            return c
        }
        // Fall back to `which git` via /bin/sh
        let which = try await runRaw(
            executable: "/bin/sh",
            args: ["-lc", "command -v git"],
            cwd: nil
        )
        let path = which.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            resolvedGitPath = path
            return path
        }
        throw ProcessError.gitNotFound
    }

    /// Run a git subcommand in a repository and return the buffered result.
    /// Optional `stdin` is piped into the subprocess (used by `git apply`
    /// for hunk-level staging, `git hash-object`, etc.). Optional `env`
    /// supplements the inherited environment — useful for setting
    /// `GIT_SEQUENCE_EDITOR` / `GIT_EDITOR` during interactive rebase so
    /// git reads its todo from a pre-written file instead of opening
    /// a terminal editor.
    func run(
        in repoPath: String?,
        args: [String],
        stdin: String? = nil,
        env: [String: String]? = nil,
        timeout: TimeInterval = 120
    ) async throws -> GitCommandResult {
        // Every git invocation in the app arrives here — all 90-odd call sites
        // in `GitService` funnel through this one method — and git is also the
        // only thing that touches the network. So instrumenting this function
        // covers both halves of "is our I/O or our networking misbehaving"
        // without scattering timing code through the service layer.
        let clock = LogClock()
        let git: String
        do {
            git = try await gitExecutablePath()
        } catch {
            Log.git(
                args: args,
                durationMs: clock.elapsedMs,
                outcome: Self.outcome(for: error),
                message: String(describing: error)
            )
            throw error
        }

        var fullArgs: [String] = []
        if let repoPath { fullArgs += ["-C", repoPath] }
        fullArgs += args
        let display = "git " + fullArgs.joined(separator: " ")

        do {
            let raw = try await runRaw(
                executable: git,
                args: fullArgs,
                cwd: repoPath,
                stdin: stdin,
                env: env,
                timeout: timeout
            )
            let succeeded = raw.exitCode == 0
            Log.git(
                args: fullArgs,
                durationMs: clock.elapsedMs,
                // Output volume is the other half of an I/O picture: a command
                // that is slow because it returned 40 MB is a different
                // problem from one that is slow having returned nothing.
                bytes: raw.stdout.utf8.count + raw.stderr.utf8.count,
                outcome: succeeded ? .ok : .failed,
                // git writes progress to stderr on success too, so only a
                // failure's stderr is worth the bytes in the log.
                message: succeeded ? nil : Self.firstLine(of: raw.stderr)
            )
            return GitCommandResult(
                command: display,
                exitCode: raw.exitCode,
                stdout: raw.stdout,
                stderr: raw.stderr,
                // Monotonic, unlike the wall clock this used to subtract: an
                // NTP step mid-fetch could otherwise report a negative
                // duration for the one command slow enough to span one.
                duration: clock.elapsed
            )
        } catch {
            // The failures worth catching are exactly the ones that never
            // reach `GitCommandResult` — a timeout or a cancelled task leaves
            // no exit code behind, so without this they are invisible.
            Log.git(
                args: fullArgs,
                durationMs: clock.elapsedMs,
                outcome: Self.outcome(for: error),
                message: String(describing: error)
            )
            throw error
        }
    }

    private static func outcome(for error: Error) -> LogOutcome {
        if error is CancellationError { return .cancelled }
        if case ProcessError.timedOut = error { return .timedOut }
        return .failed
    }

    private static func firstLine(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    /// Stream the combined stdout+stderr line-by-line as the process runs,
    /// then the exit code.
    ///
    /// Unlike `run`, nothing here is buffered until the end: this is for
    /// commands whose output is worth watching arrive — the Terminal panel's
    /// whole reason for existing.
    ///
    /// stdin is `/dev/null` rather than inherited. A GUI app has no terminal,
    /// so anything that tries to *ask* something — an editor, a passphrase
    /// prompt — would otherwise sit there reading from a handle that never
    /// answers, and the only sign would be a command that never finishes.
    /// Against `/dev/null` it reads EOF and gives up immediately, which is a
    /// failure the user can at least see.
    func stream(
        executable: String,
        args: [String],
        cwd: String?,
        env: [String: String]? = nil
    ) async -> AsyncThrowingStream<ShellEvent, Error> {
        let baseEnvironment = await userShellEnvironment()
        return AsyncThrowingStream { continuation in
            let process = Process()
            let box = ProcessBox()
            box.process = process
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

            process.environment = Self.mergedEnvironment(base: baseEnvironment, overrides: env)
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // Cancelling the consuming task has to reach the process itself,
            // or a `sleep 100` typed by mistake keeps a shell alive with
            // nobody left reading it.
            continuation.onTermination = { @Sendable _ in box.terminate() }

            let buffer = DataBox()
            // A process can exit with output still sitting in the pipe, so
            // the exit code cannot be the signal to stop reading: a command
            // that prints a lot and exits quickly (`seq 1 5000`) would lose
            // most of its output to the race. NSFileHandle marks the end by
            // calling the handler once with no data, and that — not
            // termination — is when everything has actually been read.
            // The exit and the EOF are counted rather than waited on, so no
            // thread sits blocked on another — see `EventLatch`.
            let exitStatus = ExitStatusBox()
            let finished = EventLatch(count: 2) {
                // Whatever the last write left without a newline is still
                // output — a shell prompt fragment, a progress line — and
                // dropping it would lose the end of the answer.
                if let tail = buffer.drainRemainder() {
                    continuation.yield(.line(tail))
                }
                continuation.yield(.exit(exitStatus.value))
                continuation.finish()
            }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    finished.signal()
                    return
                }
                buffer.append(data)
                for line in buffer.drainLines() {
                    continuation.yield(.line(line))
                }
            }
            process.terminationHandler = { proc in
                exitStatus.value = proc.terminationStatus
                finished.signal()
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: ProcessError.launchFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Internal

    /// Resolve an auxiliary CLI using the same PATH as Git's children,
    /// including tools installed by Homebrew when launched from Finder.
    func executablePath(named name: String) async -> String? {
        let environment = await userShellEnvironment()
        let path = Self.augmentedPath(environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        for directory in path.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Buffered auxiliary command. Unlike `run`, this deliberately does not
    /// log output: authentication tools may print sensitive information.
    func runExecutable(
        _ executable: String, args: [String], env: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> GitCommandResult {
        let clock = LogClock()
        let raw = try await runRaw(executable: executable, args: args, cwd: nil,
                                   env: env, timeout: timeout)
        return GitCommandResult(command: URL(fileURLWithPath: executable).lastPathComponent + " " + args.joined(separator: " "),
                                exitCode: raw.exitCode, stdout: raw.stdout, stderr: raw.stderr,
                                duration: clock.elapsed)
    }

    private struct RawResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func runRaw(
        executable: String,
        args: [String],
        cwd: String?,
        stdin: String? = nil,
        env: [String: String]? = nil,
        timeout: TimeInterval = 120,
        inheritUserShellEnvironment: Bool = true,
        baseEnvironment: [String: String]? = nil
    ) async throws -> RawResult {
        let processBox = ProcessBox()
        let effectiveBaseEnvironment: [String: String]
        if let baseEnvironment {
            effectiveBaseEnvironment = baseEnvironment
        } else if inheritUserShellEnvironment {
            effectiveBaseEnvironment = await userShellEnvironment()
        } else {
            effectiveBaseEnvironment = ProcessInfo.processInfo.environment
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RawResult, Error>) in
            let process = Process()
            processBox.process = process
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            // `GIT_OPTIONAL_LOCKS=0` stops read-only queries (notably
            // `git status`) from taking `.git/index.lock` and rewriting
            // `.git/index` just to refresh their stat cache. Those writes
            // land inside the directory our FileWatcher observes, so without
            // this every status poll generates fresh FSEvents that trigger
            // another refresh — a feedback loop that churns the disk at idle.
            // Optional locks are not the *required* locks that write commands
            // (commit, checkout, …) take, so disabling them is safe globally.
            var base = effectiveBaseEnvironment
            base["GIT_OPTIONAL_LOCKS"] = "0"
            process.environment = Self.mergedEnvironment(base: base, overrides: env)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Wire stdin if supplied. We write the entire buffer then close
            // the write end so `git apply` (and friends) see EOF.
            var stdinPipe: Pipe?
            if let stdin {
                let pipe = Pipe()
                process.standardInput = pipe
                stdinPipe = pipe
                let handle = pipe.fileHandleForWriting
                let data = Data(stdin.utf8)
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try handle.write(contentsOf: data)
                        try handle.close()
                    } catch {
                        try? handle.close()
                    }
                }
            }
            _ = stdinPipe // keep alive until terminationHandler retains via process

            let outBox = DataBox()
            let errBox = DataBox()

            // We need an explicit EOF signal from each pipe before we
            // resume the continuation — otherwise the final chunk
            // delivered by `readabilityHandler` on its private queue
            // can race the `terminationHandler` and we end up
            // returning a truncated (often empty) stdout.
            //
            // NSFileHandle signals EOF by invoking `readabilityHandler`
            // one last time with `availableData == empty`. We treat
            // that as our cue to mark the pipe drained.
            //
            // Both EOFs and the exit are counted rather than waited on, so
            // no thread sits blocked on another — see `EventLatch`.
            let state = ContinuationState<RawResult>()
            let exitStatus = ExitStatusBox()
            let watchdog = WatchdogBox()
            let finished = EventLatch(count: 3) {
                // The watchdog outlives the command it guards unless it is
                // told to stop, and it holds the `Process` — and through it
                // both pipes' read ends — for the whole timeout. A 30 ms
                // `rev-parse` would keep two descriptors open for two
                // minutes; a sidebar refresh fires one per repository, and
                // the app runs out of descriptors long before the user is
                // done. Then every spawn fails, and a repository git could
                // not be asked about reads as one that isn't a repository.
                watchdog.cancel()
                let stdout = String(data: outBox.data, encoding: .utf8) ?? ""
                let stderr = String(data: errBox.data, encoding: .utf8) ?? ""
                state.resume(cont) {
                    RawResult(
                        exitCode: exitStatus.value,
                        stdout: stdout,
                        stderr: stderr
                    )
                }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    finished.signal()
                } else {
                    outBox.append(data)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    finished.signal()
                } else {
                    errBox.append(data)
                }
            }

            process.terminationHandler = { proc in
                exitStatus.value = proc.terminationStatus
                finished.signal()
            }

            do {
                try process.run()
                if timeout > 0 {
                    watchdog.arm(Task {
                        let ns = UInt64(timeout * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: ns)
                        // Cancelled means the process already finished and
                        // the result is on its way out; there is nothing
                        // left to time out, and returning here is what lets
                        // go of the process and its descriptors.
                        guard !Task.isCancelled, process.isRunning else { return }
                        process.terminate() // SIGTERM
                        let pid = process.processIdentifier
                        Task {
                            // Grace period for a clean SIGTERM exit, then
                            // force-kill so a process ignoring SIGTERM can't
                            // leak (the continuation has already resumed, so
                            // nothing else will reap it).
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            if process.isRunning {
                                kill(pid, SIGKILL)
                            }
                        }
                        state.resume(cont, throwing: ProcessError.timedOut("\(executable) \(args.joined(separator: " "))"))
                    })
                }
            } catch {
                state.resume(cont, throwing: ProcessError.launchFailed(error.localizedDescription))
            }
            }
        } onCancel: {
            processBox.terminate()
        }
    }
}

/// Thread-safe data accumulator for pipe readers. Both the buffered-result
/// path (`runRaw`) and the line-streaming path (`stream`) use it; they only
/// touch the byte sink mutators (`append`, `drainLines`, `drainRemainder`).
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return _data
    }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        _data.append(chunk)
    }
    /// Pops every fully-buffered line (terminated by `\n`) and returns them.
    func drainLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var lines: [String] = []
        while let idx = _data.firstIndex(of: 0x0A) {
            let lineData = _data.subdata(in: _data.startIndex..<idx)
            _data.removeSubrange(_data.startIndex...idx)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }
    /// Returns any unterminated trailing bytes as a final string and clears
    /// the buffer.
    func drainRemainder() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !_data.isEmpty else { return nil }
        let s = String(data: _data, encoding: .utf8)
        _data.removeAll(keepingCapacity: false)
        return s
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _process: Process?

    var process: Process? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _process
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _process = newValue
        }
    }

    func terminate() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
    }
}

/// Counts the events a result depends on and runs the completion when the
/// last of them lands, on whichever thread delivered it.
///
/// This replaces a `DispatchSemaphore` the finishing side used to block on.
/// A pipe's `readabilityHandler` runs on NSFileHandle's own default-QoS
/// queue, so blocking a `.userInitiated` thread until that queue signalled
/// was a priority inversion — the runtime flags it, and the high-priority
/// thread was stalled on a lower-priority one for the whole command. Nobody
/// waits now: each handler decrements on its own queue and the last one in
/// does the work.
private final class EventLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var completion: (() -> Void)?

    init(count: Int, completion: @escaping () -> Void) {
        self.remaining = count
        self.completion = completion
    }

    /// Marks one event done. Runs — and releases — the completion once every
    /// counted event has arrived, and only ever once.
    func signal() {
        lock.lock()
        remaining -= 1
        guard remaining <= 0, let completion else {
            lock.unlock()
            return
        }
        self.completion = nil
        lock.unlock()
        completion()
    }
}

/// The timeout watchdog, held so that finishing normally can cancel it.
///
/// Armed after `Process.run()` succeeds, which is after the latch that
/// cancels it already exists — so a command that finishes before the task
/// is stored still stops it, by way of the remembered `cancelled` flag.
private final class WatchdogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func arm(_ task: Task<Void, Never>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let armed = task
        task = nil
        lock.unlock()
        armed?.cancel()
    }
}

/// The exit status, handed from the termination handler to whichever thread
/// finishes the result. The two are no longer the same one.
private final class ExitStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int32 = 0

    var value: Int32 {
        get {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _value = newValue
        }
    }
}

private final class ContinuationState<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ continuation: CheckedContinuation<T, Error>,
        _ value: () -> T
    ) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        continuation.resume(returning: value())
    }

    func resume(
        _ continuation: CheckedContinuation<T, Error>,
        throwing error: Error
    ) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        continuation.resume(throwing: error)
    }
}
