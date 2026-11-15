import Foundation

/// What Tab does in the Terminal panel.
///
/// A shell's Tab is three behaviours in one, and all three matter: complete
/// when there is one answer, extend as far as the answers agree when there
/// are several, and show them when it cannot get further. Anything less
/// reads as broken to someone whose fingers already know what Tab does.
///
/// Completion happens at the end of the line rather than at the cursor:
/// SwiftUI's `TextField` does not publish a cursor position, and Tab pressed
/// mid-line is rare enough that guessing wrong there is better than not
/// offering it at all.
enum TerminalCompletion {

    struct Result: Equatable {
        /// The line as it should be after Tab, or nil to leave it alone.
        let line: String?
        /// Candidates to show when Tab could not finish the job. Empty when
        /// there was one answer, or none.
        let suggestions: [String]

        static let none = Result(line: nil, suggestions: [])
    }

    /// Subcommands offered after `git`. Not every one git has — the list is
    /// there to save typing, and a hundred entries of which five are used
    /// saves less than a dozen that are.
    static let gitSubcommands = [
        "add", "am", "bisect", "blame", "branch", "checkout", "cherry-pick",
        "clean", "clone", "commit", "config", "describe", "diff", "fetch",
        "grep", "init", "log", "merge", "mv", "pull", "push", "rebase",
        "reflog", "remote", "reset", "restore", "revert", "rm", "show",
        "stash", "status", "submodule", "switch", "tag", "worktree"
    ]

    /// Built-ins the panel handles itself, which no PATH lookup would find.
    static let builtins = ["cd", "clear"]

    /// Complete `line` against `directory`.
    ///
    /// `executables` is injected rather than read from PATH here so the
    /// behaviour can be tested without depending on what happens to be
    /// installed on the machine running the tests.
    static func complete(
        line: String,
        directory: String?,
        executables: @autoclosure () -> [String] = []
    ) -> Result {
        let token = currentToken(of: line)
        let prefix = String(line.dropLast(token.count))

        // First word: a command. Anything after it: a path — which is
        // wrong for `git com<tab>`, so that one case is named.
        let candidates: [String]
        if prefix.trimmingCharacters(in: .whitespaces).isEmpty, !prefix.contains(" "),
           !looksLikePath(token) {
            candidates = commandCandidates(matching: token, executables: executables())
        } else if isGitSubcommandPosition(prefix) {
            candidates = gitSubcommands.filter { $0.hasPrefix(token) }
        } else {
            return completePath(token: token, prefix: prefix, directory: directory)
        }

        guard !candidates.isEmpty else { return .none }
        if candidates.count == 1 {
            return Result(line: prefix + candidates[0] + " ", suggestions: [])
        }
        let shared = commonPrefix(of: candidates)
        return Result(
            line: shared.count > token.count ? prefix + shared : nil,
            suggestions: candidates
        )
    }

    // MARK: - Commands

    /// `./script`, `../tool`, `~/bin/x` — a first word that names a file
    /// rather than a command, and completes like one.
    private static func looksLikePath(_ token: String) -> Bool {
        token.contains("/") || token.hasPrefix("~")
    }

    private static func commandCandidates(matching token: String, executables: [String]) -> [String] {
        let all = Set(builtins + ["git"] + executables)
        return all.filter { $0.hasPrefix(token) }.sorted()
    }

    /// True when the token being completed is the subcommand slot of a git
    /// invocation — `git <tab>`, but not `git commit <tab>`.
    private static func isGitSubcommandPosition(_ prefix: String) -> Bool {
        let words = prefix.split(separator: " ", omittingEmptySubsequences: true)
        return words.count == 1 && words[0] == "git"
    }

    // MARK: - Paths

    private static func completePath(token: String, prefix: String, directory: String?) -> Result {
        // Only expand an actual tilde: `expandingTildeInPath` also
        // normalises, and the normalisation drops a trailing slash — which
        // turned `cd src/` + Tab back into `cd src/` instead of listing
        // what is inside.
        let expanded = token.hasPrefix("~")
            ? (token as NSString).expandingTildeInPath + (token.hasSuffix("/") ? "/" : "")
            : token
        // Split into "directory part" and "what is being typed", the way a
        // shell does: `src/ma` looks in `src` for names starting `ma`.
        let slash = expanded.lastIndex(of: "/")
        let dirPart = slash.map { String(expanded[..<$0]) } ?? ""
        let namePart = slash.map { String(expanded[expanded.index(after: $0)...]) } ?? expanded

        let searchDir: String
        if expanded.hasPrefix("/") {
            searchDir = dirPart.isEmpty ? "/" : dirPart
        } else if let directory {
            searchDir = dirPart.isEmpty ? directory : (directory as NSString).appendingPathComponent(dirPart)
        } else {
            return .none
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: searchDir) else {
            return .none
        }
        // Hidden files stay hidden until asked for by name, as in a shell.
        let unescapedName = unescape(namePart)
        let matches = entries
            .filter { $0.hasPrefix(unescapedName) }
            .filter { unescapedName.hasPrefix(".") || !$0.hasPrefix(".") }
            .sorted()

        guard !matches.isEmpty else { return .none }

        // The visible token keeps whatever the user typed — `~/Doc` stays
        // `~/Doc…` rather than being rewritten to an absolute path.
        let typedDirPart: String = {
            guard let slash = token.lastIndex(of: "/") else { return "" }
            return String(token[...slash])
        }()

        if matches.count == 1 {
            let name = matches[0]
            let full = (searchDir as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory)
            // A directory gets a slash so the next Tab can keep going; a
            // file gets a space, because it is finished.
            let suffix = isDirectory.boolValue ? "/" : " "
            return Result(line: prefix + typedDirPart + escape(name) + suffix, suggestions: [])
        }

        let shared = commonPrefix(of: matches)
        return Result(
            line: shared.count > unescapedName.count
                ? prefix + typedDirPart + escape(shared)
                : nil,
            suggestions: matches
        )
    }

    // MARK: - Words

    /// The word Tab is completing: everything after the last unescaped
    /// space. `cp a\ b/fi` completes `a\ b/fi`, not `b/fi`.
    static func currentToken(of line: String) -> String {
        var token = ""
        var escaped = false
        for character in line {
            if escaped {
                token.append(character)
                escaped = false
            } else if character == "\\" {
                token.append(character)
                escaped = true
            } else if character == " " {
                token = ""
            } else {
                token.append(character)
            }
        }
        return token
    }

    /// Backslash-escape the spaces in a name, so the shell that runs the
    /// line sees one argument.
    static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "\\ ")
    }

    static func unescape(_ token: String) -> String {
        token.replacingOccurrences(of: "\\ ", with: " ")
    }

    /// Longest prefix every candidate shares — how far Tab can get when it
    /// cannot finish.
    static func commonPrefix(of candidates: [String]) -> String {
        guard var shared = candidates.first else { return "" }
        for candidate in candidates.dropFirst() {
            shared = String(shared.commonPrefix(with: candidate))
            if shared.isEmpty { break }
        }
        return shared
    }

    /// Executable names on `PATH`, for completing the first word.
    static func executablesOnPath(_ path: String?) -> [String] {
        let dirs = (path ?? "").split(separator: ":").map(String.init)
        let fm = FileManager.default
        var names: Set<String> = []
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where fm.isExecutableFile(atPath: (dir as NSString).appendingPathComponent(entry)) {
                names.insert(entry)
            }
        }
        return Array(names)
    }
}
