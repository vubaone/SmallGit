import XCTest
@testable import SmallGit

/// Dropping several stashes is the one multi-selection action here that
/// nothing undoes, and git renumbers the list underneath it after every
/// single drop. These run it against a real git and check the survivors by
/// message, not by index — an index is exactly what the bug would corrupt.
@MainActor
final class StashMultiDropTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        let repo: String
        let root: URL
    }

    /// A repo with four stashes. git lists newest first, so the stash made
    /// from "one" ends up at the highest index:
    /// @{0} four, @{1} three, @{2} two, @{3} one.
    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let git = GitService(runner: runner)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-multidrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("work").path

        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main", "work"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        let file = URL(fileURLWithPath: repo).appendingPathComponent("a.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "a.txt"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "base"])

        for label in ["one", "two", "three", "four"] {
            try "\(label)\n".write(to: file, atomically: true, encoding: .utf8)
            _ = try await runner.run(in: repo, args: ["stash", "push", "-q", "-m", label])
        }

        return Sandbox(runner: runner, git: git, repo: repo, root: root)
    }

    private func app(for box: Sandbox) -> AppState {
        let app = makeIsolatedAppState(git: box.git)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "work")
        app.coordinator.switchRepo(to: box.repo)
        return app
    }

    /// Stash messages, newest first, as git currently has them.
    private func messages(_ box: Sandbox) async throws -> [String] {
        try await box.git.stashList(repoPath: box.repo).map(\.message)
    }

    private func contains(_ messages: [String], _ label: String) -> Bool {
        messages.contains { $0.contains(label) }
    }

    // MARK: -

    func testSandboxOrdersStashesNewestFirst() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let listed = try await messages(box)
        XCTAssertEqual(listed.count, 4)
        XCTAssertTrue(contains([listed[0]], "four"), listed[0])
        XCTAssertTrue(contains([listed[3]], "one"), listed[3])
    }

    func testDroppingSeveralRemovesExactlyThoseSelected() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        // @{1} is "three" and @{3} is "one". Dropping the lower index first
        // would renumber "one" out from under the second drop and take the
        // wrong stash with it.
        let ok = await app(for: box).stashDrop(indices: [1, 3])
        XCTAssertTrue(ok)

        let listed = try await messages(box)
        XCTAssertEqual(listed.count, 2)
        XCTAssertTrue(contains(listed, "four"), "\(listed)")
        XCTAssertTrue(contains(listed, "two"), "\(listed)")
        XCTAssertFalse(contains(listed, "three"), "\(listed)")
        XCTAssertFalse(contains(listed, "one"), "\(listed)")
    }

    func testDroppingAdjacentIndicesLeavesTheRestAlone() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let ok = await app(for: box).stashDrop(indices: [0, 1, 2])
        XCTAssertTrue(ok)

        let listed = try await messages(box)
        XCTAssertEqual(listed.count, 1)
        XCTAssertTrue(contains(listed, "one"), "\(listed)")
    }

    func testDroppingEveryStashEmptiesTheList() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let ok = await app(for: box).stashDrop(indices: [3, 0, 2, 1])
        XCTAssertTrue(ok)
        let listed = try await messages(box)
        XCTAssertTrue(listed.isEmpty, "\(listed)")
    }

    func testDuplicateIndicesDropOnce() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        // Dropping @{2} twice would take "two" and then "one" with it.
        let ok = await app(for: box).stashDrop(indices: [2, 2])
        XCTAssertTrue(ok)

        let listed = try await messages(box)
        XCTAssertEqual(listed.count, 3)
        XCTAssertTrue(contains(listed, "one"), "\(listed)")
        XCTAssertFalse(contains(listed, "two"), "\(listed)")
    }

    func testNoIndicesIsNotAnAction() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let ok = await app(for: box).stashDrop(indices: [])
        XCTAssertFalse(ok)
        let listed = try await messages(box)
        XCTAssertEqual(listed.count, 4)
    }

    func testAnOutOfRangeIndexStopsTheRun() async throws {
        let box = try await makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }

        // Highest first, so the bad index is attempted before the good one
        // and nothing is dropped on a list we can no longer reason about.
        let ok = await app(for: box).stashDrop(indices: [0, 9])
        XCTAssertFalse(ok)

        let listed = try await messages(box)
        XCTAssertEqual(listed.count, 4, "a failed drop must not take others with it: \(listed)")
    }
}
