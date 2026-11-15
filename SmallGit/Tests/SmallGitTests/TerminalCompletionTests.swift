import XCTest
@testable import SmallGit

/// Tab in the Terminal panel.
///
/// Against a real directory, because the behaviour being copied is a
/// shell's and a shell's is defined by what is on disk: one match finishes
/// the word, several extend it as far as they agree, and what it cannot
/// finish it offers.
final class TerminalCompletionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-complete-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for dir in ["src", "scripts", "some dir"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: root.appendingPathComponent("src/nested"), withIntermediateDirectories: true)
        for file in ["README.md", "Package.swift", ".hidden", "src/main.swift", "src/model.swift"] {
            try "x".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func complete(_ line: String, executables: [String] = []) -> TerminalCompletion.Result {
        TerminalCompletion.complete(line: line, directory: root.path, executables: executables)
    }

    // MARK: - Paths

    func testOneMatchFinishesTheWord() {
        // A directory gets a slash so the next Tab can carry on into it.
        XCTAssertEqual(complete("cd sr").line, "cd src/")
        // A file gets a space, because there is nothing left to add.
        XCTAssertEqual(complete("cat READ").line, "cat README.md ")
    }

    func testSeveralMatchesExtendAsFarAsTheyAgree() {
        let result = complete("cd s")
        // `src`, `scripts` and `some dir` share only "s", so the line
        // cannot grow — but the candidates are worth showing.
        XCTAssertNil(result.line)
        XCTAssertEqual(result.suggestions, ["scripts", "some dir", "src"])

        // `main.swift` and `model.swift` share only the `m` already typed,
        // so there is no progress to make — and the answer is the list.
        let deeper = complete("cat src/m")
        XCTAssertNil(deeper.line)
        XCTAssertEqual(deeper.suggestions, ["main.swift", "model.swift"])
    }

    func testItExtendsToTheSharedPrefixWhenThereIsOne() {
        // `scripts` alone under "scr" — one match, so it finishes.
        XCTAssertEqual(complete("cd scr").line, "cd scripts/")
    }

    func testNothingMatchesIsLeftAlone() {
        XCTAssertEqual(complete("cd zzz"), .none)
        XCTAssertEqual(complete("cd src/nope"), .none)
    }

    func testHiddenFilesStayHiddenUntilAskedFor() {
        // A shell does not offer dotfiles for a bare prefix…
        XCTAssertFalse(complete("cat ").suggestions.contains(".hidden"))
        XCTAssertFalse(complete("cat R").suggestions.contains(".hidden"))
        // …but does the moment the dot is typed.
        XCTAssertEqual(complete("cat .hid").line, "cat .hidden ")
    }

    func testSpacesInNamesAreEscaped() {
        // Completed into a line the shell will parse, so the space has to
        // survive as one argument rather than becoming two.
        XCTAssertEqual(complete("cd some").line, "cd some\\ dir/")
        // And a token that already carries an escaped space still matches
        // the name it stands for.
        XCTAssertEqual(
            TerminalCompletion.currentToken(of: "cp some\\ dir/fi"),
            "some\\ dir/fi"
        )
    }

    func testAbsolutePathsComplete() {
        let line = "cat \(root.path)/READ"
        XCTAssertEqual(complete(line).line, "cat \(root.path)/README.md ")
    }

    func testCompletingAgainWalksDeeper() {
        // What the second Tab does after the first ended in a slash.
        let first = complete("cd sr")
        XCTAssertEqual(first.line, "cd src/")
        let second = complete(first.line!)
        XCTAssertEqual(second.suggestions, ["main.swift", "model.swift", "nested"])
    }

    // MARK: - Commands

    func testTheFirstWordCompletesCommands() {
        XCTAssertEqual(complete("gi").line, "git ")
        XCTAssertEqual(complete("cl").line, "clear ", "built-ins the panel handles itself count too")

        let result = complete("c", executables: ["cat", "curl"])
        XCTAssertNil(result.line, "`cd`, `clear`, `cat`, `curl` share only `c`")
        XCTAssertEqual(result.suggestions, ["cat", "cd", "clear", "curl"])
    }

    func testGitSubcommandsCompleteAfterGit() {
        XCTAssertEqual(complete("git stat").line, "git status ")
        let result = complete("git s")
        XCTAssertNil(result.line)
        XCTAssertTrue(result.suggestions.contains("stash"))
        XCTAssertTrue(result.suggestions.contains("submodule"))
    }

    func testAfterASubcommandItIsPathsAgain() {
        // `git add sr` is a path, not a third layer of subcommands.
        XCTAssertEqual(complete("git add sr").line, "git add src/")
    }

    func testATokenThatLooksLikeAPathIsNotACommand() {
        // `./scr<tab>` means the file in this directory.
        XCTAssertEqual(complete("./scr", executables: ["screen"]).line, "./scripts/")
    }

    // MARK: - Pieces

    func testCurrentTokenIsTheWordUnderTab() {
        XCTAssertEqual(TerminalCompletion.currentToken(of: "git add src/ma"), "src/ma")
        XCTAssertEqual(TerminalCompletion.currentToken(of: "git "), "")
        XCTAssertEqual(TerminalCompletion.currentToken(of: ""), "")
    }

    func testCommonPrefix() {
        XCTAssertEqual(TerminalCompletion.commonPrefix(of: ["main.swift", "model.swift"]), "m")
        XCTAssertEqual(TerminalCompletion.commonPrefix(of: ["alpha", "alps"]), "alp")
        XCTAssertEqual(TerminalCompletion.commonPrefix(of: ["one", "two"]), "")
        XCTAssertEqual(TerminalCompletion.commonPrefix(of: []), "")
    }
}
