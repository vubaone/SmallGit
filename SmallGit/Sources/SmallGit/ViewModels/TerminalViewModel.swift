import Foundation
import Observation

/// One command and everything it had to say.
///
/// Kept as a unit rather than as a flat list of lines so the panel can show
/// where each command started and how it ended — which is the difference
/// between a transcript and a wall of text.
struct TerminalEntry: Identifiable, Sendable {
    let id = UUID()
    /// Directory the command ran in, shown in its prompt line. A transcript
    /// spanning a `cd` is unreadable without it.
    let directory: String
    let command: String
    var lines: [String] = []
    /// Nil while the command is still running.
    var exitCode: Int32?
    var wasCancelled = false

    var isRunning: Bool { exitCode == nil && !wasCancelled }
    var failed: Bool { (exitCode ?? 0) != 0 }
}

/// The Terminal panel: type a command, see what it says.
///
/// Deliberately a command runner rather than a terminal emulator. Each
/// command is one non-interactive shell with no tty, which is what makes it
/// safe to run from a GUI — but it also means anything that wants to *talk
/// back* (an editor, `git rebase -i`, a passphrase prompt) has nowhere to do
/// it and will fail rather than hang. Commands that print and exit — which
/// is nearly all of git — behave exactly as they do in Terminal.app.
@MainActor
@Observable
final class TerminalViewModel {

    /// Transcript, oldest first.
    private(set) var entries: [TerminalEntry] = []
    /// What is being typed right now. Bound to the input field.
    var input: String = "" {
        didSet {
            // Any edit makes the last Tab's candidates stale — they were
            // an answer to a line that no longer exists.
            if !suggestions.isEmpty, oldValue != input, !isCompleting {
                suggestions = []
            }
        }
    }
    private(set) var inputFocusRequest = UUID()
    /// Set while `completeInput` writes to `input`, so the write does not
    /// clear the candidates it is about to publish.
    private var isCompleting = false
    /// Directory commands run in. Follows the active repository, and `cd`.
    private(set) var directory: String?
    /// Repository root — where `cd` with no argument goes back to, since in
    /// a git client that is far more useful than the home directory.
    private(set) var repositoryRoot: String?

    private(set) var isRunning = false
    /// Candidates from the last Tab that could not finish on its own —
    /// what a shell prints under the prompt. Cleared by typing or running.
    private(set) var suggestions: [String] = []

    /// Commands typed this session, oldest first, for up-arrow recall.
    private(set) var history: [String] = []
    /// How far back the up-arrow has walked, or nil when editing fresh
    /// input. Held separately from `input` so walking back down returns
    /// what was half-typed rather than an empty field.
    private var historyCursor: Int?
    private var draft: String = ""

    private var task: Task<Void, Never>?
    private let runner: ProcessRunner
    private let openInTerminal: (String) -> Void

    /// Scrollback ceiling, in lines per command. A stray `cat` of something
    /// enormous would otherwise grow the transcript without limit; the tail
    /// is what matters, so the head is what goes.
    static let maxLinesPerCommand = 5_000
    /// Commands kept in the transcript.
    static let maxEntries = 200

    init(
        runner: ProcessRunner = .shared,
        openInTerminal: @escaping (String) -> Void = {
            MacPlatformServices().openInTerminal(path: $0)
        }
    ) {
        self.runner = runner
        self.openInTerminal = openInTerminal
    }

    // MARK: - Repository

    /// Point the terminal at a repository. Resets `cd` — the previous
    /// repository's subdirectory means nothing here — but keeps the
    /// transcript, which is a log of what the user did, not of where.
    func setRepository(_ path: String?) {
        repositoryRoot = path
        directory = path
    }

    /// What the input field shows to the left of the cursor. The repository
    /// name, plus the path below it when `cd` has moved somewhere.
    var prompt: String {
        guard let directory else { return "$" }
        guard let root = repositoryRoot else {
            return "\((directory as NSString).lastPathComponent) $"
        }
        let name = (root as NSString).lastPathComponent
        guard directory != root else { return "\(name) $" }
        if directory.hasPrefix(root + "/") {
            return "\(name)/\(String(directory.dropFirst(root.count + 1))) $"
        }
        return "\((directory as NSString).lastPathComponent) $"
    }

    // MARK: - Running

    /// Fill the command line without executing it or changing the transcript.
    /// App setup can happen before a repository exists (for example, clone).
    func prepareCommand(_ command: String) {
        if directory == nil {
            directory = FileManager.default.homeDirectoryForCurrentUser.path
        }
        input = command
        historyCursor = nil
        draft = ""
        suggestions = []
        inputFocusRequest = UUID()
    }

    /// Tab: complete the word being typed.
    ///
    /// Path names come from the directory the next command would run in,
    /// so completion and execution can never disagree about where "here"
    /// is. Executables are read from the PATH the panel's own shell would
    /// use, for the same reason.
    func completeInput() {
        let result = TerminalCompletion.complete(
            line: input,
            directory: directory,
            executables: Self.pathExecutables
        )
        isCompleting = true
        if let line = result.line { input = line }
        isCompleting = false
        suggestions = result.suggestions
    }

    /// Take one of the offered candidates, as if it had been typed and
    /// completed. Directories keep the trailing slash so the next Tab can
    /// carry on into them.
    func accept(_ candidate: String) {
        let token = TerminalCompletion.currentToken(of: input)
        let head = String(input.dropLast(token.count))
        // Whatever directory part the token already had stays: picking
        // `main.swift` while typing `src/ma` means `src/main.swift`.
        let typedDirPart: String = {
            guard let slash = token.lastIndex(of: "/") else { return "" }
            return String(token[...slash])
        }()
        let full = (directory as NSString?)?
            .appendingPathComponent(TerminalCompletion.unescape(typedDirPart + candidate))
        var isDirectory: ObjCBool = false
        let exists = full.map {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
        } ?? false
        let suffix = (exists && isDirectory.boolValue) ? "/" : " "
        isCompleting = true
        input = head + typedDirPart + TerminalCompletion.escape(candidate) + suffix
        isCompleting = false
        suggestions = []
    }

    /// Cached: a PATH scan is a dozen directory listings, and Tab is
    /// pressed far more often than PATH changes within a session.
    private static let pathExecutables: [String] = TerminalCompletion.executablesOnPath(
        ProcessInfo.processInfo.environment["PATH"]
    )

    /// Run whatever is in the input field.
    func submit() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        suggestions = []
        historyCursor = nil
        draft = ""
        guard !command.isEmpty else { return }
        remember(command)

        // Built-ins are handled here rather than passed to the shell,
        // because a shell that exits takes its answer with it: `cd src` in
        // one process tells the next process nothing.
        switch Builtin(command) {
        case .clear:
            entries.removeAll()
            return
        case .changeDirectory(let argument):
            changeDirectory(to: argument, command: command)
            return
        case .none:
            break
        }

        guard let directory else {
            append(TerminalEntry(
                directory: "",
                command: command,
                lines: ["No repository is open — there is nowhere to run this."],
                exitCode: 1
            ))
            return
        }

        append(TerminalEntry(directory: directory, command: command))
        isRunning = true
        let index = entries.count - 1
        task = Task { [weak self] in
            await self?.stream(command: command, in: directory, into: index)
        }
    }

    /// Stop the running command. The process is killed through the stream's
    /// cancellation handler, so this is not merely stopping to listen.
    func cancel() {
        guard isRunning else { return }
        task?.cancel()
    }

    func clear() {
        entries.removeAll()
    }

    private func stream(command: String, in directory: String, into index: Int) async {
        defer {
            isRunning = false
            task = nil
        }
        let events = await runner.stream(
            executable: Self.shellPath,
            args: ["-lc", command],
            cwd: directory,
            env: Self.environment
        )
        do {
            for try await event in events {
                switch event {
                case .line(let line):
                    appendLine(TerminalOutput.strippingControlCodes(line), to: index)
                case .exit(let code):
                    openExternalTerminalForCredentialsIfNeeded(
                        index: index,
                        exitCode: code,
                        directory: directory
                    )
                    finish(index: index, exitCode: code)
                }
            }
            // The stream can end without an exit event if the task was
            // cancelled mid-command; mark it so the transcript doesn't show
            // a command that never came back.
            if entries.indices.contains(index), entries[index].isRunning {
                entries[index].wasCancelled = true
            }
        } catch {
            appendLine(String(describing: error), to: index)
            finish(index: index, exitCode: -1)
        }
    }

    private func append(_ entry: TerminalEntry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    private func appendLine(_ line: String, to index: Int) {
        guard entries.indices.contains(index) else { return }
        entries[index].lines.append(line)
        if entries[index].lines.count > Self.maxLinesPerCommand {
            let overflow = entries[index].lines.count - Self.maxLinesPerCommand
            entries[index].lines.removeFirst(overflow)
        }
    }

    private func finish(index: Int, exitCode: Int32) {
        guard entries.indices.contains(index) else { return }
        entries[index].exitCode = exitCode
    }

    /// This panel is deliberately not a tty, so Git cannot conduct an
    /// interactive username/password exchange here. Once Git says that is
    /// exactly what stopped it, continue the workflow in Terminal.app at the
    /// same directory instead of leaving the user at a dead end.
    private func openExternalTerminalForCredentialsIfNeeded(
        index: Int,
        exitCode: Int32,
        directory: String
    ) {
        guard exitCode != 0,
              !Task.isCancelled,
              entries.indices.contains(index)
        else { return }
        let output = entries[index].lines.joined(separator: "\n")
        guard GitCredentials.urlNeedingCredentials(in: output) != nil else { return }

        appendLine(
            "Authentication needs an interactive prompt — opened Terminal.app here. Run the command again there.",
            to: index
        )
        openInTerminal(directory)
    }

    // MARK: - Built-ins

    private enum Builtin {
        case clear
        case changeDirectory(String?)
        case none

        init(_ command: String) {
            let parts = command.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = parts.first else { self = .none; return }
            switch first {
            case "clear":
                self = parts.count == 1 ? .clear : .none
            case "cd":
                // Only the plain forms. `cd foo && make` is a shell
                // expression, and pretending otherwise would silently run
                // half of it.
                guard parts.count <= 2, !command.contains("&&"), !command.contains(";") else {
                    self = .none
                    return
                }
                self = .changeDirectory(parts.count == 2 ? String(parts[1]) : nil)
            default:
                self = .none
            }
        }
    }

    private func changeDirectory(to argument: String?, command: String) {
        guard let current = directory else { return }
        guard let argument else {
            directory = repositoryRoot ?? current
            append(TerminalEntry(directory: current, command: command, exitCode: 0))
            return
        }
        let expanded = (argument as NSString).expandingTildeInPath
        let target = expanded.hasPrefix("/")
            ? expanded
            : (current as NSString).appendingPathComponent(expanded)
        let resolved = (target as NSString).standardizingPath

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            append(TerminalEntry(
                directory: current,
                command: command,
                lines: ["cd: no such file or directory: \(argument)"],
                exitCode: 1
            ))
            return
        }
        directory = resolved
        append(TerminalEntry(directory: current, command: command, exitCode: 0))
    }

    // MARK: - History

    private func remember(_ command: String) {
        // A command repeated back-to-back is one history entry, the way
        // every shell with `HIST_IGNORE_DUPS` behaves.
        if history.last != command {
            history.append(command)
        }
    }

    /// Walk back through history. Keeps whatever was half-typed so walking
    /// forward again returns it.
    func recallPrevious() {
        suggestions = []
        guard !history.isEmpty else { return }
        if historyCursor == nil {
            draft = input
            historyCursor = history.count
        }
        guard let cursor = historyCursor, cursor > 0 else { return }
        historyCursor = cursor - 1
        input = history[cursor - 1]
    }

    /// Walk forward again, ending at the half-typed draft.
    func recallNext() {
        suggestions = []
        guard let cursor = historyCursor else { return }
        let next = cursor + 1
        if next >= history.count {
            historyCursor = nil
            input = draft
            return
        }
        historyCursor = next
        input = history[next]
    }

    // MARK: - Shell

    /// The user's own shell, so their PATH and profile apply. `-l` (login)
    /// rather than `-i` (interactive): a non-interactive shell reading
    /// `.zshrc` on a pipe is where job-control warnings come from, and
    /// aliases are not much use to a runner that takes one command at a time.
    static var shellPath: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    }

    /// `TERM=dumb` asks every well-behaved tool not to colour its output,
    /// since this panel renders text and not escape sequences. The git
    /// variables stop it reaching for a pager or a terminal prompt it does
    /// not have.
    static let environment: [String: String] = [
        "TERM": "dumb",
        "NO_COLOR": "1",
        "CLICOLOR": "0",
        "GIT_PAGER": "cat",
        "PAGER": "cat",
        "GIT_TERMINAL_PROMPT": "0"
    ]
}

/// Text arriving from a command, made fit to display.
enum TerminalOutput {

    /// Strip ANSI escape sequences and stray carriage returns.
    ///
    /// `TERM=dumb` asks tools not to emit colour, but asking is all it is —
    /// anything run with `--color=always`, or any tool with its own opinion,
    /// still sends escape sequences. Rendering those literally turns output
    /// into `ESC[32mok ESC[0m`, so they come out here.
    static func strippingControlCodes(_ line: String) -> String {
        var result = ""
        result.reserveCapacity(line.count)
        var iterator = line.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "\u{1B}" else {
                // A lone carriage return is a progress line rewriting itself.
                // Keeping it would leave the transcript looking overwritten,
                // so it goes; \r\n has already been split on \n.
                if character != "\r" { result.append(character) }
                continue
            }
            guard let next = iterator.next() else { break }
            if next == "[" {
                // CSI: parameters, then a letter that ends the sequence.
                while let code = iterator.next() {
                    if code.isLetter { break }
                }
            } else if next == "]" {
                // OSC: runs until BEL or ST (ESC \).
                var previous: Character?
                while let code = iterator.next() {
                    if code == "\u{07}" { break }
                    if previous == "\u{1B}", code == "\\" { break }
                    previous = code
                }
            } else if next != "\u{1B}" {
                // Two-character escape: already consumed.
                continue
            } else {
                pending = next
            }
        }
        return result
    }
}
