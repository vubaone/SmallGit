import XCTest
@testable import SmallGit

final class RepositoryRemovalTests: XCTestCase {

    @MainActor
    func testRemoveRequestPresentsThemedDialogWithoutMutatingList() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-remove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let app = makeIsolatedAppState()
        let repository = RepositoryEntry(path: folder.path, name: "Example")
        app.repositoriesConfig.ungrouped = [repository]

        await app.removeRepository(repository)

        XCTAssertEqual(app.pendingRepositoryRemoval?.repository, repository)
        XCTAssertEqual(app.pendingRepositoryRemoval?.folderExists, true)
        XCTAssertEqual(app.repositoriesConfig.ungrouped, [repository])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor
    func testMissingFolderRequestOffersListRemoval() async {
        let app = makeIsolatedAppState()
        let repository = RepositoryEntry(
            path: "/tmp/smallgit-missing-\(UUID().uuidString)",
            name: "Missing"
        )
        app.repositoriesConfig.ungrouped = [repository]

        await app.removeRepository(repository)

        XCTAssertEqual(app.pendingRepositoryRemoval?.folderExists, false)
        XCTAssertEqual(app.repositoriesConfig.ungrouped, [repository])
    }

    @MainActor
    func testConfirmRemoveFromListKeepsFolderOnDisk() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let app = makeIsolatedAppState()
        let repository = RepositoryEntry(path: folder.path, name: "Keep Files")
        app.repositoriesConfig.ungrouped = [repository]
        await app.removeRepository(repository)
        let target = try XCTUnwrap(app.pendingRepositoryRemoval)

        await app.confirmRepositoryRemoval(target, choice: .removeFromList)

        XCTAssertNil(app.pendingRepositoryRemoval)
        XCTAssertTrue(app.repositoriesConfig.ungrouped.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(app.statusText, "Removed Keep Files from list")
    }

    @MainActor
    func testCancelKeepsRepositoryAndFolder() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let app = makeIsolatedAppState()
        let repository = RepositoryEntry(path: folder.path, name: "Cancel")
        app.repositoriesConfig.ungrouped = [repository]
        await app.removeRepository(repository)

        app.cancelRepositoryRemoval()

        XCTAssertNil(app.pendingRepositoryRemoval)
        XCTAssertEqual(app.repositoriesConfig.ungrouped, [repository])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
}
