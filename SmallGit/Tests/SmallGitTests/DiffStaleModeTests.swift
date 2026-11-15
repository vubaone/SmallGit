import XCTest
@testable import SmallGit

/// Regression: a stage changes every compare mode for the file, but only
/// the on-screen mode used to refresh. The others kept a stale L2 (disk)
/// snapshot, so switching to them showed pre-stage hunks. `reloadAfterStaging`
/// purges the off-screen modes from L1+L2 so the next switch re-fetches.
@MainActor
final class DiffStaleModeTests: XCTestCase {

    private let runner = ProcessRunner()

    private func makeRepo() async throws -> (path: String, root: URL) {
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-stalemode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: root.path, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: root.path, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: root.path, args: ["config", "commit.gpgsign", "false"])
        return (root.path, root)
    }

    func testSwitchingModeAfterStageShowsFreshDiff() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let file = URL(fileURLWithPath: repo.path).appendingPathComponent("a.txt")

        try "a\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo.path, args: ["add", "a.txt"])
        _ = try await runner.run(in: repo.path, args: ["commit", "-q", "-m", "init"])
        // Working tree gains a line; nothing staged yet.
        try "a\nb\n".write(to: file, atomically: true, encoding: .utf8)

        let coord = CacheCoordinator()
        coord.switchRepo(to: repo.path)
        let dvm = DiffViewModel(coordinator: coord)

        // Prime HEAD↔Index (currently empty — index == HEAD) so its empty
        // result lands in L1+L2. This is the snapshot that used to go stale.
        await dvm.loadDiff(file: "a.txt", mode: .headVsIndex)
        XCTAssertTrue(dvm.hunks.isEmpty, "nothing staged yet")

        // Show Index↔Working and stage the whole file there.
        await dvm.loadDiff(file: "a.txt", mode: .indexVsWorkingTree)
        XCTAssertFalse(dvm.hunks.isEmpty)
        _ = try await runner.run(in: repo.path, args: ["add", "a.txt"])

        // The app calls this after a successful stage.
        await dvm.reloadAfterStaging()
        // Current mode (Index↔Working) is now clean — change moved to index.
        XCTAssertTrue(dvm.hunks.isEmpty, "Index↔Working should be empty after staging")

        // Switching to HEAD↔Index must show the staged change, not the
        // primed-empty disk snapshot.
        await dvm.loadDiff(file: "a.txt", mode: .headVsIndex)
        XCTAssertEqual(
            dvm.hunks.flatMap(\.lines).filter { $0.type == .add }.map(\.content),
            ["b"],
            "HEAD↔Index should reflect the freshly staged line, not stale cache"
        )
    }
}
