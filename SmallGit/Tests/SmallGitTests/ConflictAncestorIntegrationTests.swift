import XCTest
@testable import SmallGit

/// Covers making the common ancestor available when git didn't write it.
///
/// The resolver shows a BASE pane sourced from stage 1 of the index, but the
/// per-chunk "Base" action needs the ancestor to be *in the file's markers* —
/// and git's default `merge.conflictStyle` doesn't put it there. Seeing the
/// base on screen while the button that takes it is dead is the worst of both.
final class ConflictAncestorIntegrationTests: XCTestCase {

    private var repo: URL!
    private let git = GitService.shared

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                          "git not available")
        repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Ancestor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try makeConflict()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ text: String) throws {
        try text.write(to: repo.appendingPathComponent("u.swift"), atomically: true, encoding: .utf8)
    }

    private var working: String {
        (try? String(contentsOf: repo.appendingPathComponent("u.swift"), encoding: .utf8)) ?? ""
    }

    /// Ancestor has two functions; each side replaces them differently, so the
    /// ancestor content exists but appears in neither side.
    private func makeConflict() throws {
        try run(["init", "-q", "-b", "main", "."])
        try run(["config", "user.email", "t@t"])
        try run(["config", "user.name", "t"])
        // Explicitly the default style, which is the situation being fixed.
        try run(["config", "merge.conflictStyle", "merge"])
        try write("import Foundation\n\nfunc add() {}\nfunc multiply() {}\n")
        try run(["add", "-A"])
        try run(["commit", "-qm", "base"])
        try run(["checkout", "-qb", "feature"])
        try write("import Foundation\n\nenum MathB {}\n")
        try run(["commit", "-qam", "theirs"])
        try run(["checkout", "-q", "main"])
        try write("import Foundation\n\nenum MathA {}\n")
        try run(["commit", "-qam", "ours"])
        try run(["merge", "feature"])
    }

    /// The starting position: conflicted, and the ancestor is nowhere in the
    /// file even though it is in the index.
    func testDefaultMarkersCarryNoAncestor() throws {
        XCTAssertTrue(working.contains("<<<<<<<"))
        XCTAssertFalse(working.contains("|||||||"))

        let chunk = try XCTUnwrap(ConflictParser.parse(working).chunks.first)
        XCTAssertNil(chunk.baseText, "nothing for the Base button to take")

        let stageOne = try run(["show", ":1:u.swift"])
        XCTAssertTrue(stageOne.contains("func add"), "…yet the index has it all along")
    }

    /// The fix: regenerate the markers from the index in diff3 style.
    func testRestoringMarkersAddsTheAncestor() async throws {
        let result = try await git.restoreConflictMarkersWithAncestor(
            repoPath: repo.path, path: "u.swift"
        )
        XCTAssertTrue(result.succeeded)

        XCTAssertTrue(working.contains("|||||||"))
        let chunk = try XCTUnwrap(ConflictParser.parse(working).chunks.first)
        let base = try XCTUnwrap(chunk.baseText)
        XCTAssertTrue(base.contains("func add"))
        XCTAssertTrue(base.contains("func multiply"))
    }

    /// It must not resolve or stage anything — the user is still mid-merge.
    func testTheFileStaysConflictedAndUnstaged() async throws {
        _ = try await git.restoreConflictMarkersWithAncestor(repoPath: repo.path, path: "u.swift")

        let unmerged = try run(["diff", "--name-only", "--diff-filter=U"])
        XCTAssertTrue(unmerged.contains("u.swift"))
        let operation = await git.inProgressOperation(repoPath: repo.path)
        XCTAssertEqual(operation, .merge)
    }

    /// End to end: after restoring, taking Base yields the ancestor's code —
    /// which is the thing that was unreachable before.
    func testTakingBaseAfterwardsProducesTheAncestorCode() async throws {
        _ = try await git.restoreConflictMarkersWithAncestor(repoPath: repo.path, path: "u.swift")

        let parsed = ConflictParser.parse(working)
        let chunk = try XCTUnwrap(parsed.chunks.first)
        let rebuilt = parsed.segments[0] + chunk.resolvedText(.base) + parsed.segments[1]

        XCTAssertTrue(rebuilt.contains("func add"))
        XCTAssertTrue(rebuilt.contains("func multiply"))
        XCTAssertTrue(rebuilt.contains("import Foundation"), "context above the chunk survives")
        XCTAssertFalse(rebuilt.contains("<<<<<<<"))
        XCTAssertFalse(rebuilt.contains("MathA"))
        XCTAssertFalse(rebuilt.contains("MathB"))
    }

    /// And the contrast that started all this: Neither drops the region, so
    /// the ancestor's code does *not* come back.
    func testNeitherStillDropsEverythingIncludingTheAncestor() async throws {
        _ = try await git.restoreConflictMarkersWithAncestor(repoPath: repo.path, path: "u.swift")

        let parsed = ConflictParser.parse(working)
        let chunk = try XCTUnwrap(parsed.chunks.first)
        let rebuilt = parsed.segments[0] + chunk.resolvedText(.neither) + parsed.segments[1]

        XCTAssertFalse(rebuilt.contains("func add"), "Neither is not Base")
        XCTAssertTrue(rebuilt.contains("import Foundation"))
    }
}
