import XCTest
@testable import SmallGit

/// Opening a submodule's log, which points a window of its own at it.
///
/// Two reported bugs live here, and they are the same mistake twice: for a
/// while this made the submodule the *active* repository. That moved the
/// main window off the repository being worked in, and — because the commit
/// dialog belongs to whatever is active — put the submodule's commit dialog
/// over the wrong window. Looking into a submodule now changes nothing
/// about the main window; switching to it is a separate, explicit action.
@MainActor
final class OpenSubmoduleTests: XCTestCase {

    private struct Fixture {
        let app: AppState
        let runner: ProcessRunner
        let root: URL
        var superPath: String { root.appendingPathComponent("super").path }
    }

    private func makeFixture() async throws -> Fixture {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-opensub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func configure(_ path: String) async throws {
            _ = try await runner.run(in: path, args: ["config", "user.email", "t@x"])
            _ = try await runner.run(in: path, args: ["config", "user.name", "T"])
            _ = try await runner.run(in: path, args: ["config", "commit.gpgsign", "false"])
        }

        let lib = root.appendingPathComponent("lib").path
        try FileManager.default.createDirectory(atPath: lib, withIntermediateDirectories: true)
        _ = try await runner.run(in: lib, args: ["init", "-q", "-b", "main"])
        try await configure(lib)
        _ = try await runner.run(in: lib, args: ["commit", "-q", "--allow-empty", "-m", "lib: first"])

        let superPath = root.appendingPathComponent("super").path
        try FileManager.default.createDirectory(atPath: superPath, withIntermediateDirectories: true)
        _ = try await runner.run(in: superPath, args: ["init", "-q", "-b", "main"])
        try await configure(superPath)
        _ = try await runner.run(in: superPath, args: ["commit", "-q", "--allow-empty", "-m", "super: first"])
        let added = try await runner.run(in: superPath, args: [
            "-c", "protocol.file.allow=always",
            "submodule", "add", "-q", "--", lib, "vendor/lib"
        ])
        guard added.succeeded else { throw XCTSkip("submodule add unavailable: \(added.stderr)") }
        _ = try await runner.run(in: superPath, args: ["commit", "-q", "-m", "vendor lib"])

        let app = makeIsolatedAppState(git: GitService(runner: runner))
        await app.addRepository(at: superPath)
        return Fixture(app: app, runner: runner, root: root)
    }

    func testOpeningASubmoduleLeavesTheMainWindowWhereItWas() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertEqual(f.app.activeRepo?.path, f.superPath)

        let opened = await f.app.openSubmoduleLog(path: "vendor/lib")
        XCTAssertTrue(opened)
        XCTAssertEqual(f.app.submoduleLogTarget?.path, "vendor/lib")
        // The reported problem: looking into B moved the main window off A,
        // and took A's Repositories selection and commit dialog with it.
        XCTAssertEqual(
            f.app.activeRepo?.path, f.superPath,
            "the submodule window has its own repository; the main window keeps A"
        )
        XCTAssertFalse(
            f.app.allRepositories.contains { $0.name == "lib" },
            "and nothing was added to the sidebar behind the user's back"
        )
    }

    func testOpeningTwiceIsStillTheSameTarget() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        _ = await f.app.openSubmoduleLog(path: "vendor/lib")
        let first = f.app.submoduleLogTarget
        _ = await f.app.openSubmoduleLog(path: "vendor/lib")
        XCTAssertEqual(f.app.submoduleLogTarget, first, "same target, so the window reloads rather than rebuilds")
        XCTAssertEqual(f.app.activeRepo?.path, f.superPath)
    }

    func testOpeningAsARepositoryIsTheExplicitActionThatDoesSwitch() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // The window points at it first, the way it does in the app.
        _ = await f.app.openSubmoduleLog(path: "vendor/lib")
        await f.app.openSubmoduleAsRepository(path: "vendor/lib")
        XCTAssertEqual(f.app.activeRepo?.name, "lib")

        // Handing over closes the window, and the target is cleared with it
        // so asking for the same submodule again still registers as a
        // change and reloads rather than opening onto a stale session.
        f.app.submoduleLogTarget = nil
        let reopened = await f.app.openSubmoduleLog(path: "vendor/lib")
        XCTAssertFalse(reopened, "and from inside the submodule there is no vendor/lib to open")

        // And again, from the parent: the "already exists" path used to
        // leave the parent active instead of selecting the submodule.
        let parent = try XCTUnwrap(f.app.allRepositories.first { $0.path == f.superPath })
        await f.app.selectRepo(parent)
        await f.app.openSubmoduleAsRepository(path: "vendor/lib")
        XCTAssertEqual(f.app.activeRepo?.name, "lib")
        XCTAssertEqual(f.app.allRepositories.filter { $0.name == "lib" }.count, 1)
    }

    func testOpeningAsARepositoryAsksTheListToScrollToIt() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // Looking into a submodule moves nothing, so there is no row to
        // scroll to and the list is left where the user had it.
        _ = await f.app.openSubmoduleLog(path: "vendor/lib")
        XCTAssertNil(f.app.sidebarRevealTarget)

        await f.app.openSubmoduleAsRepository(path: "vendor/lib")
        XCTAssertEqual(
            f.app.sidebarRevealTarget, f.app.activeRepo?.id,
            "the row of the repository just handed over"
        )

        // A submodule that cannot be opened hands over nothing, so it must
        // not send the list somewhere either.
        f.app.sidebarRevealTarget = nil
        await f.app.openSubmoduleAsRepository(path: "vendor/nope")
        XCTAssertNil(f.app.sidebarRevealTarget)
    }

    func testAnUninitializedSubmoduleIsNotOpened() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.runner.run(in: f.superPath, args: ["submodule", "deinit", "-f", "--", "vendor/lib"])

        let opened = await f.app.openSubmoduleLog(path: "vendor/lib")
        XCTAssertFalse(opened, "there is no repository there yet to show")
        XCTAssertNil(f.app.submoduleLogTarget, "so no window is pointed at it")
    }

    func testAPathThatIsNotASubmoduleIsNotOpened() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let opened = await f.app.openSubmoduleLog(path: ".gitmodules")
        XCTAssertFalse(opened)
        XCTAssertNil(f.app.submoduleLogTarget)
    }
}
