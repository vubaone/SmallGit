import XCTest
@testable import SmallGit

/// Reverting one line of a multi-line hunk against a real git repo:
/// discarding it from the working tree, and unstaging it from the index.
///
/// These run git because the bug they pin was invisible to a builder-only
/// test. A patch is matched against the target file by ONE side — the
/// preimage going forward, the postimage in reverse — so collapsing the
/// untargeted lines the forward way and then handing the result to
/// `--reverse` produces a patch that describes a file nobody has: the
/// dropped `+` lines are sitting in the working tree between the kept ones,
/// and the demoted `-` lines are not in it at all. git answers "patch does
/// not apply", and only git can tell us it has stopped.
final class LineRevertIntegrationTests: XCTestCase {

    private var runner: ProcessRunner!
    private var git: GitService!
    private var repo: String!
    private var tmpDir: URL!

    override func setUp() async throws {
        runner = ProcessRunner()
        git = GitService(runner: runner)

        // Skip if git is not available (sandboxed CI without xcode-select).
        do {
            _ = try await runner.gitExecutablePath()
        } catch {
            throw XCTSkip("git binary not available: \(error)")
        }

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-revert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        repo = tmpDir.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
    }

    override func tearDown() {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
    }

    private var fileURL: URL { tmpDir.appendingPathComponent("guide.md") }

    private func commit(_ text: String) async throws {
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "guide.md"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "init"])
    }

    private func write(_ text: String) throws {
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func onDisk() throws -> String {
        try String(contentsOf: fileURL, encoding: .utf8)
    }

    // MARK: - Discard one line of several

    /// The case from the bug report: three lines appended at once, and only
    /// the middle one thrown away. The other two are untouched, which is the
    /// half a forward-collapsed patch cannot express — it drops them, and
    /// they are sitting in the file.
    func testDiscardsOneAddedLineAndKeepsTheOthers() async throws {
        try await commit("intro\n- a\n- b\n- c\n")
        try write("intro\n- a\n- b\n- c\n\n## Installation\nClone it.\n")

        let hunks = try await git.diff(repoPath: repo, file: "guide.md")
        let adds = hunks.flatMap(\.lines).filter { $0.type == .add }
        XCTAssertEqual(adds.map(\.content), ["", "## Installation", "Clone it."])

        let target = try XCTUnwrap(adds.first { $0.content == "## Installation" })
        let patch = try XCTUnwrap(DiffPatchBuilder.buildLinesPatch(
            file: "guide.md", hunks: hunks, targetLineIDs: [target.id], direction: .reverse
        ))
        _ = try await git.applyPatch(repoPath: repo, patch: patch, cached: false, reverse: true)

        XCTAssertEqual(try onDisk(), "intro\n- a\n- b\n- c\n\nClone it.\n")
    }

    /// The first of the three. Nothing before it in the hunk but context, so
    /// this is the one a forward-collapsed patch comes closest to getting
    /// right — and still doesn't.
    func testDiscardsTheFirstAddedLine() async throws {
        try await commit("intro\n- a\n- b\n- c\n")
        try write("intro\n- a\n- b\n- c\n\n## Installation\nClone it.\n")

        let hunks = try await git.diff(repoPath: repo, file: "guide.md")
        let target = try XCTUnwrap(hunks.flatMap(\.lines).first { $0.type == .add })
        let patch = try XCTUnwrap(DiffPatchBuilder.buildLinesPatch(
            file: "guide.md", hunks: hunks, targetLineIDs: [target.id], direction: .reverse
        ))
        _ = try await git.applyPatch(repoPath: repo, patch: patch, cached: false, reverse: true)

        XCTAssertEqual(try onDisk(), "intro\n- a\n- b\n- c\n## Installation\nClone it.\n")
    }

    /// A deleted line put back while the other deletions stay gone. The
    /// mirror of the case above, and the one that proves the rule is about
    /// the matched side rather than about `+` lines specifically.
    func testRestoresOneDeletedLineAndLeavesTheOthersDeleted() async throws {
        try await commit("intro\none\ntwo\nthree\ntail\n")
        try write("intro\ntail\n")

        let hunks = try await git.diff(repoPath: repo, file: "guide.md")
        let dels = hunks.flatMap(\.lines).filter { $0.type == .del }
        XCTAssertEqual(dels.map(\.content), ["one", "two", "three"])

        let target = try XCTUnwrap(dels.first { $0.content == "two" })
        let patch = try XCTUnwrap(DiffPatchBuilder.buildLinesPatch(
            file: "guide.md", hunks: hunks, targetLineIDs: [target.id], direction: .reverse
        ))
        _ = try await git.applyPatch(repoPath: repo, patch: patch, cached: false, reverse: true)

        XCTAssertEqual(try onDisk(), "intro\ntwo\ntail\n")
    }

    /// A modification — a `-` and a `+` on the same side-by-side row, which
    /// the arrow hands over as one pair. Reverting has to take the `+` away
    /// and put the `-` back together, or the line ends up neither version.
    func testRevertsAModifiedLineAsAPair() async throws {
        try await commit("intro\nalpha\nbeta\ngamma\ntail\n")
        try write("intro\nALPHA\nBETA\nGAMMA\ntail\n")

        let hunks = try await git.diff(repoPath: repo, file: "guide.md")
        let lines = hunks.flatMap(\.lines)
        let del = try XCTUnwrap(lines.first { $0.type == .del && $0.content == "beta" })
        let add = try XCTUnwrap(lines.first { $0.type == .add && $0.content == "BETA" })

        let patch = try XCTUnwrap(DiffPatchBuilder.buildLinesPatch(
            file: "guide.md", hunks: hunks, targetLineIDs: [del.id, add.id], direction: .reverse
        ))
        _ = try await git.applyPatch(repoPath: repo, patch: patch, cached: false, reverse: true)

        XCTAssertEqual(try onDisk(), "intro\nALPHA\nbeta\nGAMMA\ntail\n")
    }

    // MARK: - Unstage one line of several

    /// The same collapse, against the index rather than the working tree.
    /// `--cached --reverse` matches the postimage against the index, so it
    /// needs the identical mirror — and a direction-blind builder breaks
    /// both operations for the price of one.
    func testUnstagesOneLineAndLeavesTheRestStaged() async throws {
        try await commit("intro\n- a\n- b\n- c\n")
        try write("intro\n- a\n- b\n- c\n\n## Installation\nClone it.\n")
        _ = try await runner.run(in: repo, args: ["add", "guide.md"])

        let hunks = try await git.diff(repoPath: repo, file: "guide.md", mode: .headVsIndex)
        let target = try XCTUnwrap(
            hunks.flatMap(\.lines).first { $0.type == .add && $0.content == "## Installation" }
        )
        let patch = try XCTUnwrap(DiffPatchBuilder.buildLinesPatch(
            file: "guide.md", hunks: hunks, targetLineIDs: [target.id], direction: .reverse
        ))
        _ = try await git.applyPatch(repoPath: repo, patch: patch, cached: true, reverse: true)

        // The index lost that one line; the working tree kept everything.
        let staged = try await runner.run(in: repo, args: ["show", ":guide.md"])
        XCTAssertEqual(staged.stdout, "intro\n- a\n- b\n- c\n\nClone it.\n")
        XCTAssertEqual(try onDisk(), "intro\n- a\n- b\n- c\n\n## Installation\nClone it.\n")
    }

    // MARK: - The forward direction still works

    /// The mirror has to leave staging alone: same hunk, same one line, the
    /// other way round. Staging drops the untargeted `+` lines because the
    /// index genuinely does not have them.
    func testStagingOneLineIsUnaffected() async throws {
        try await commit("intro\n- a\n- b\n- c\n")
        try write("intro\n- a\n- b\n- c\n\n## Installation\nClone it.\n")

        let hunks = try await git.diff(repoPath: repo, file: "guide.md")
        let target = try XCTUnwrap(
            hunks.flatMap(\.lines).first { $0.type == .add && $0.content == "## Installation" }
        )
        let patch = try XCTUnwrap(DiffPatchBuilder.buildLinesPatch(
            file: "guide.md", hunks: hunks, targetLineIDs: [target.id], direction: .forward
        ))
        _ = try await git.applyPatch(repoPath: repo, patch: patch, cached: true, reverse: false)

        let staged = try await runner.run(in: repo, args: ["show", ":guide.md"])
        XCTAssertEqual(staged.stdout, "intro\n- a\n- b\n- c\n## Installation\n")
    }
}
