import XCTest
@testable import SmallGit

/// The Terminal panel, against a real shell.
///
/// The behaviours worth pinning are the ones that separate a usable command
/// runner from a hang: that a command finishes, that its exit code survives,
/// that `cd` means anything at all when every command is its own process,
/// and that nothing waits on a terminal this app does not have.
@MainActor
final class TerminalViewModelTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Submit a command and wait for it to finish. The deadline is the point:
    /// a command that waits for input it can never get would hang here, which
    /// is exactly the failure being guarded against.
    private func run(
        _ viewModel: TerminalViewModel,
        _ command: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        viewModel.input = command
        viewModel.submit()
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(viewModel.isRunning, "\(command) never finished", file: file, line: line)
    }

    // MARK: - Running

    func testOutputAndExitCodeComeBack() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = TerminalViewModel()
        viewModel.setRepository(root.path)

        try await run(viewModel, "echo hello")
        XCTAssertEqual(viewModel.entries.last?.lines, ["hello"])
        XCTAssertEqual(viewModel.entries.last?.exitCode, 0)
        XCTAssertFalse(viewModel.entries.last?.failed ?? true)

        try await run(viewModel, "exit 3")
        XCTAssertEqual(viewModel.entries.last?.exitCode, 3)
        XCTAssertTrue(viewModel.entries.last?.failed ?? false)
    }

    func testStderrIsInTheTranscriptToo() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = TerminalViewModel()
        viewModel.setRepository(root.path)

        // git says most of what matters on stderr; a panel that showed only
        // stdout would stay blank for exactly the commands worth watching.
        try await run(viewModel, "echo to-stderr 1>&2")
        XCTAssertEqual(viewModel.entries.last?.lines, ["to-stderr"])
    }

    func testCommandsRunInTheRepository() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = TerminalViewModel()
        viewModel.setRepository(root.path)

        try await run(viewModel, "pwd")
        // /var vs /private/var: the shell reports the resolved path.
        XCTAssertEqual(
            viewModel.entries.last?.lines.last.map { ($0 as NSString).lastPathComponent },
            root.lastPathComponent
        )
    }

    func testNothingWaitsOnATerminalThatIsNotThere() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = TerminalViewModel()
        viewModel.setRepository(root.path)

        // `cat` with no argument reads stdin. Inherited from a `.app` that
        // has no terminal, this is a command that never returns; against
        // /dev/null it reads EOF and exits. The short timeout is the assert.
        try await run(viewModel, "cat", timeout: 5)
        XCTAssertEqual(viewModel.entries.last?.exitCode, 0)
    }

    func testCredentialPromptFailureOpensTerminalAtCurrentDirectory() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var openedPaths: [String] = []
        let viewModel = TerminalViewModel { openedPaths.append($0) }
        viewModel.setRepository(root.path)

        try await run(
            viewModel,
            "printf \"fatal: could not read Username for 'https://example.com': terminal prompts disabled\\n\" >&2; exit 128"
        )

        XCTAssertEqual(openedPaths, [root.path])
        XCTAssertTrue(
            viewModel.entries.last?.lines.last?.contains("opened Terminal.app") ?? false
        )
        XCTAssertEqual(viewModel.entries.last?.exitCode, 128)
    }

    func testOrdinaryFailureDoesNotOpenTerminal() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var openedPaths: [String] = []
        let viewModel = TerminalViewModel { openedPaths.append($0) }
        viewModel.setRepository(root.path)

        try await run(viewModel, "echo ordinary-error >&2; exit 1")

        XCTAssertTrue(openedPaths.isEmpty)
    }

    func testColourIsAskedForAndStrippedAnyway() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = TerminalViewModel()
        viewModel.setRepository(root.path)

        try await run(viewModel, "echo $TERM")
        XCTAssertEqual(viewModel.entries.last?.lines, ["dumb"],
                       "tools are asked not to colour their output")

        // Asking is not the same as being obeyed, so the escapes come out
        // on the way in as well.
        try await run(viewModel, "printf '\\033[32mgreen\\033[0m\\n'")
        XCTAssertEqual(viewModel.entries.last?.lines, ["green"])
    }

    func testStoppingKillsTheCommand() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = TerminalViewModel()
        viewModel.setRepository(root.path)

        viewModel.input = "sleep 30"
        viewModel.submit()
        XCTAssertTrue(viewModel.isRunning)

        viewModel.cancel()
        let deadline = Date().addingTimeInterval(5)
        while viewModel.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(viewModel.isRunning, "stop has to reach the process, not just stop listening")
        XCTAssertTrue(viewModel.entries.last?.wasCancelled ?? false)
    }

    func testWithoutARepositoryItSaysSoRatherThanRunningSomewhereElse() async throws {
        let viewModel = TerminalViewModel()
        try await run(viewModel, "echo nowhere")
        XCTAssertEqual(viewModel.entries.last?.exitCode, 1)
        XCTAssertTrue(viewModel.entries.last?.lines.first?.contains("nowhere to run") ?? false)
    }

    // MARK: - Built-ins

    func testCDPersistsBetweenCommands() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"), withIntermediateDirectories: true
        )
        let viewModel = TerminalViewModel()
        viewModel.setRepository(root.path)

        // Each command is its own shell, so `cd` has to be ours: passed
        // through, it would change a directory in a process that then exits.
        try await run(viewModel, "cd src")
        XCTAssertEqual(viewModel.directory, root.appendingPathComponent("src").path)
        XCTAssertTrue(viewModel.prompt.hasSuffix("/src $"), viewModel.prompt)

        try await run(viewModel, "pwd")
        XCTAssertEqual(viewModel.entries.last?.lines.last?.hasSuffix("/src"), true)

        // Bare `cd` goes back to the repository, not to the home directory:
        // in a git client that is the useful "back".
        try await run(viewModel, "cd")
        XCTAssertEqual(viewModel.directory, root.path)
    }

    func testCDToNowhereChangesNothing() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = TerminalViewModel()
        viewModel.setRepository(root.path)

        try await run(viewModel, "cd does-not-exist")
        XCTAssertEqual(viewModel.directory, root.path)
        XCTAssertEqual(viewModel.entries.last?.exitCode, 1)
        XCTAssertTrue(viewModel.entries.last?.lines.first?.contains("no such file") ?? false)
    }

    func testCDAsPartOfAnExpressionGoesToTheShell() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"), withIntermediateDirectories: true
        )
        let viewModel = TerminalViewModel()
        viewModel.setRepository(root.path)

        // `cd src && pwd` is a shell expression. Treating it as the built-in
        // would run half of it and silently drop the rest.
        try await run(viewModel, "cd src && pwd")
        XCTAssertEqual(viewModel.entries.last?.lines.last?.hasSuffix("/src"), true)
        XCTAssertEqual(viewModel.directory, root.path, "the shell's cd stays in the shell")
    }

    func testClearEmptiesTheTranscript() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = TerminalViewModel()
        viewModel.setRepository(root.path)

        try await run(viewModel, "echo one")
        XCTAssertFalse(viewModel.entries.isEmpty)
        try await run(viewModel, "clear")
        XCTAssertTrue(viewModel.entries.isEmpty)
        XCTAssertEqual(viewModel.history.suffix(2), ["echo one", "clear"],
                       "cleared from the screen, not from the history")
    }

    // MARK: - History

    func testHistoryWalksBackAndReturnsTheDraft() {
        let viewModel = TerminalViewModel()
        viewModel.setRepository("/tmp")
        for command in ["git status", "git log", "git status"] {
            viewModel.input = command
            viewModel.submit()
        }

        viewModel.input = "half-typ"
        viewModel.recallPrevious()
        XCTAssertEqual(viewModel.input, "git status")
        viewModel.recallPrevious()
        XCTAssertEqual(viewModel.input, "git log")
        viewModel.recallNext()
        XCTAssertEqual(viewModel.input, "git status")
        // Walking forward past the newest command returns what was being
        // typed before the up-arrow was pressed, not an empty field.
        viewModel.recallNext()
        XCTAssertEqual(viewModel.input, "half-typ")
    }

    func testRepeatedCommandIsOneHistoryEntry() {
        let viewModel = TerminalViewModel()
        viewModel.setRepository("/tmp")
        for _ in 0..<3 {
            viewModel.input = "git status"
            viewModel.submit()
        }
        XCTAssertEqual(viewModel.history, ["git status"])
    }

    func testHistoryAtTheBeginningStaysThere() {
        let viewModel = TerminalViewModel()
        viewModel.setRepository("/tmp")
        viewModel.input = "only"
        viewModel.submit()

        viewModel.recallPrevious()
        viewModel.recallPrevious()
        XCTAssertEqual(viewModel.input, "only")
    }

    // MARK: - Prompt

    func testPromptNamesTheRepositoryAndThePathBelowIt() {
        let viewModel = TerminalViewModel()
        XCTAssertEqual(viewModel.prompt, "$", "nothing open, nothing to name")

        viewModel.setRepository("/work/project")
        XCTAssertEqual(viewModel.prompt, "project $")
    }

    // MARK: - Escape stripping

    func testControlCodesAreStripped() {
        XCTAssertEqual(TerminalOutput.strippingControlCodes("\u{1B}[32mok\u{1B}[0m"), "ok")
        XCTAssertEqual(TerminalOutput.strippingControlCodes("\u{1B}[1;31merror\u{1B}[m!"), "error!")
        // OSC (window-title) sequences, terminated by BEL and by ESC \.
        XCTAssertEqual(TerminalOutput.strippingControlCodes("\u{1B}]0;title\u{07}after"), "after")
        XCTAssertEqual(TerminalOutput.strippingControlCodes("\u{1B}]0;title\u{1B}\\after"), "after")
        // Progress lines rewriting themselves with \r would otherwise look
        // like one unreadable overwritten line.
        XCTAssertEqual(TerminalOutput.strippingControlCodes("50%\r100%"), "50%100%")
        // Plain text, including text that merely mentions brackets.
        XCTAssertEqual(TerminalOutput.strippingControlCodes("[ZSOC-1325] fix"), "[ZSOC-1325] fix")
        XCTAssertEqual(TerminalOutput.strippingControlCodes(""), "")
    }

    // MARK: - Limits

    func testScrollbackIsCapped() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = TerminalViewModel()
        viewModel.setRepository(root.path)

        // A stray `cat` of something enormous should not grow without limit;
        // the tail is what anyone reads.
        let lines = TerminalViewModel.maxLinesPerCommand + 500
        try await run(viewModel, "seq 1 \(lines)", timeout: 30)
        let entry = try XCTUnwrap(viewModel.entries.last)
        XCTAssertEqual(entry.lines.count, TerminalViewModel.maxLinesPerCommand)
        XCTAssertEqual(entry.lines.last, "\(lines)", "the end is what is kept")
    }
}
