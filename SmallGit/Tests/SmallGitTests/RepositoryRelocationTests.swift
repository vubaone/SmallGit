import XCTest
@testable import SmallGit

final class RepositoryRelocationTests: XCTestCase {

    private func makeRepo(named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-relocate-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let init_ = Process()
        init_.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        init_.arguments = ["init", "-q", folder.path]
        try init_.run()
        init_.waitUntilExit()
        return folder.resolvingSymlinksInPath()
    }

    @MainActor
    func testMissingRepositoryPointsAtItsNewFolderKeepingItsPlace() async throws {
        let moved = try makeRepo(named: "moved-here")
        defer { try? FileManager.default.removeItem(at: moved.deletingLastPathComponent()) }

        let app = makeIsolatedAppState()
        let missing = RepositoryEntry(path: "/tmp/smallgit-gone-\(UUID().uuidString)/app")
        app.repositoriesConfig.groups = [RepositoryGroup(name: "Work", repositories: [missing])]
        await app.refreshRepositoryAvailability()
        XCTAssertEqual(app.availability(for: missing), .missingPath)

        let result = await app.relocateRepository(missing, to: moved.path)

        let updated = try result.get()
        XCTAssertEqual(updated.id, missing.id)
        XCTAssertEqual(updated.path, moved.path)
        // The label was just the old folder name, so it follows the folder.
        XCTAssertEqual(updated.name, "moved-here")
        XCTAssertEqual(app.repositoriesConfig.groups[0].repositories, [updated])
        XCTAssertEqual(app.availability(for: updated), .available)
    }

    @MainActor
    func testAliasSurvivesRelocation() async throws {
        let moved = try makeRepo(named: "somewhere")
        defer { try? FileManager.default.removeItem(at: moved.deletingLastPathComponent()) }

        let app = makeIsolatedAppState()
        let missing = RepositoryEntry(path: "/tmp/smallgit-gone-\(UUID().uuidString)/app", name: "My App")
        app.repositoriesConfig.ungrouped = [missing]

        let updated = try await app.relocateRepository(missing, to: moved.path).get()

        XCTAssertEqual(updated.name, "My App")
        XCTAssertEqual(app.repositoriesConfig.ungrouped.first?.path, moved.path)
    }

    @MainActor
    func testFolderThatIsNotARepositoryIsRefused() async throws {
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }

        let app = makeIsolatedAppState()
        let missing = RepositoryEntry(path: "/tmp/smallgit-gone-\(UUID().uuidString)/app")
        app.repositoriesConfig.ungrouped = [missing]

        let result = await app.relocateRepository(missing, to: plain.path)

        XCTAssertEqual(result, .failure(AppState.RelocationError(
            message: "That folder isn't the root of a Git repository."
        )))
        XCTAssertEqual(app.repositoriesConfig.ungrouped, [missing])
    }

    @MainActor
    func testFolderAlreadyInTheListIsRefused() async throws {
        let other = try makeRepo(named: "other")
        defer { try? FileManager.default.removeItem(at: other.deletingLastPathComponent()) }

        let app = makeIsolatedAppState()
        let existing = RepositoryEntry(path: other.path, name: "Other")
        let missing = RepositoryEntry(path: "/tmp/smallgit-gone-\(UUID().uuidString)/app")
        app.repositoriesConfig.ungrouped = [existing, missing]

        let result = await app.relocateRepository(missing, to: other.path)

        XCTAssertEqual(result, .failure(AppState.RelocationError(message: "Already in the list as Other.")))
        XCTAssertEqual(app.repositoriesConfig.ungrouped, [existing, missing])
    }
}
