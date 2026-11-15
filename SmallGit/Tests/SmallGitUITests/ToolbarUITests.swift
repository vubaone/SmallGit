import XCTest
import SwiftUI
import ViewInspector
@testable import SmallGit

@MainActor
final class ToolbarUITests: XCTestCase {
    func testSettingsButtonOpensPreferences() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let view = EmptyView().toolbar { ToolbarView(appState: f.app).settingsSection }
        try UIDriver(view: view).fire("toolbar.settings")
        XCTAssertTrue(f.app.showPreferences)
    }

    func testRepositoryButtonsAreDisabledWithoutARepository() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let toolbar = ToolbarView(appState: f.app)
        let sections = [
            AnyView(EmptyView().toolbar { toolbar.leadingSection }),
            AnyView(EmptyView().toolbar { toolbar.indexSection }),
            AnyView(EmptyView().toolbar { toolbar.branchSection })
        ]
        for (section, ids) in zip(sections, [
            ["toolbar.refresh"],
            ["toolbar.commit", "toolbar.stage", "toolbar.unstage", "toolbar.discard"],
            ["toolbar.merge", "toolbar.rebase"]
        ]) {
            let ui = UIDriver(view: section)
            for id in ids {
                XCTAssertTrue(try ui.element(id).isDisabled(), id)
                XCTAssertThrowsError(try ui.fire(id), id)
            }
        }
        XCTAssertFalse(f.app.showCommitDialog)
        XCTAssertFalse(f.app.confirmDiscard)
    }

    func testRepositoryDialogButtonsOpenTheRequestedDialog() async throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let repo = try await f.makeRepo("repo")
        await f.open(repo)
        let index = UIDriver(view: EmptyView().toolbar { ToolbarView(appState: f.app).indexSection })
        try index.fire("toolbar.commit")
        XCTAssertTrue(f.app.showCommitDialog)
        f.app.showCommitDialog = false
        try index.fire("toolbar.discard")
        XCTAssertTrue(f.app.confirmDiscard)
        let branches = UIDriver(view: EmptyView().toolbar { ToolbarView(appState: f.app).branchSection })
        try branches.fire("toolbar.merge")
        XCTAssertTrue(f.app.showMergePicker)
        try branches.fire("toolbar.rebase")
        XCTAssertTrue(f.app.showRebasePicker)
    }

    func testStageAndUnstageButtonsChangeTheRealIndex() async throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let repo = try await f.makeRepo("repo")
        try f.write("new file\n", file: "change.txt", at: repo)
        await f.open(repo)
        let file = try XCTUnwrap(f.app.filesVM.files.first)
        f.app.filesVM.selectedFileIDs = [file.id]
        let ui = UIDriver(view: EmptyView().toolbar { ToolbarView(appState: f.app).indexSection })

        try ui.fire("toolbar.stage")
        try await awaitUI("stage finished") { !f.app.isWorking && f.app.filesVM.files.first?.isStaged == true }
        let staged = try await f.git(["diff", "--cached", "--name-only"], at: repo)
        XCTAssertEqual(staged.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "change.txt")

        try ui.fire("toolbar.unstage")
        try await awaitUI("unstage finished") { !f.app.isWorking && f.app.filesVM.files.first?.isStaged == false }
        let unstaged = try await f.git(["diff", "--cached", "--name-only"], at: repo)
        XCTAssertTrue(unstaged.stdout.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("change.txt").path))
    }

    func testUnstageButtonRefusesAConflictSelection() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let conflict = GitFileStatus(path: "conflict.txt", indexStatus: "U", workTreeStatus: "U", isConflict: true)
        f.app.filesVM.files = [conflict]
        f.app.filesVM.selectedFileIDs = [conflict.id]
        let ui = UIDriver(view: EmptyView().toolbar { ToolbarView(appState: f.app).indexSection })
        XCTAssertTrue(try ui.element("toolbar.unstage").isDisabled())
        XCTAssertThrowsError(try ui.fire("toolbar.unstage"))
        XCTAssertFalse(f.app.isWorking)
    }

    func testRefreshButtonPicksUpAnExternalFileChange() async throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let repo = try await f.makeRepo("repo")
        await f.open(repo)
        XCTAssertTrue(f.app.filesVM.files.isEmpty)
        try f.write("external\n", file: "external.txt", at: repo)
        let ui = UIDriver(view: EmptyView().toolbar { ToolbarView(appState: f.app).leadingSection })
        try ui.fire("toolbar.refresh")
        try await awaitUI("external file appears") { f.app.changedFileCount == 1 }
        XCTAssertEqual(f.app.filesVM.files.map(\.path), ["external.txt"])
    }

    func testSidebarButtonTogglesCompactMode() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let ui = UIDriver(view: EmptyView().toolbar { ToolbarView(appState: f.app).leadingSection })
        let before = f.app.uiState.compactMode
        try ui.fire("toolbar.sidebar")
        XCTAssertEqual(f.app.uiState.compactMode, !before)
        try ui.fire("toolbar.sidebar")
        XCTAssertEqual(f.app.uiState.compactMode, before)
    }
}

@MainActor
final class PullUITests: XCTestCase {
    private func prepare(_ f: UIFixture) async throws -> (remote: URL, local: URL) {
        let remote = try await f.makeRepo("origin")
        try f.write("base\n", file: "shared.txt", at: remote)
        try await f.git(["add", "."], at: remote)
        try await f.git(["commit", "-qm", "base"], at: remote)
        let local = try await f.clone(remote, name: "local")
        await f.open(local)
        return (remote, local)
    }

    func testPullPrimaryActionFetchesLocalOriginAndPreservesLocalChanges() async throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let (remote, local) = try await prepare(f)
        try f.write("upstream\n", file: "shared.txt", at: remote)
        try await f.git(["commit", "-qam", "upstream"], at: remote)
        try f.write("work in progress\n", file: "local.txt", at: local)
        await f.app.refreshPanels()
        let ui = UIDriver(view: EmptyView().toolbar { ToolbarView(appState: f.app).remoteSection })
        try ui.primaryAction("toolbar.pull")
        try await awaitUI("pull finished") {
            !f.app.isWorking && f.app.journalVM.commits.first?.subject == "upstream"
        }
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("shared.txt")), "upstream\n")
        XCTAssertEqual(f.app.filesVM.files.map(\.path), ["local.txt"])
        XCTAssertEqual(f.app.changedFileCount, 1)
    }

    func testPullConflictLeavesFilesReadyToResolve() async throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let (remote, local) = try await prepare(f)
        try f.write("theirs\n", file: "shared.txt", at: remote)
        try await f.git(["commit", "-qam", "theirs"], at: remote)
        try f.write("ours\n", file: "shared.txt", at: local)
        try await f.git(["commit", "-qam", "ours"], at: local)
        f.app.appConfig.pullUsesRebase = true
        let ui = UIDriver(view: EmptyView().toolbar { ToolbarView(appState: f.app).remoteSection })
        try ui.primaryAction("toolbar.pull")
        try await awaitUI("pull stopped at conflict") {
            !f.app.isWorking && f.app.filesVM.files.contains(where: \.isConflict)
        }
        XCTAssertNotNil(f.app.inProgressOperation)
        XCTAssertTrue(f.app.filesVM.files.contains { $0.path == "shared.txt" && $0.isConflict })
        XCTAssertFalse(f.app.coordinator.isActionRunning)
    }
}
