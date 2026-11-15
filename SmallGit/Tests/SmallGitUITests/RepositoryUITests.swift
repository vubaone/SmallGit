import XCTest
import SwiftUI
import ViewInspector
@testable import SmallGit

@MainActor
final class RepositoryUITests: XCTestCase {
    func testAddButtonCallsTheFolderPicker() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        try UIDriver(view: RepositoryAddMenu(appState: f.app)).fire("repositories.add")
        XCTAssertEqual(f.platform.pickerCalls, 1)
        XCTAssertTrue(f.app.allRepositories.isEmpty)
    }

    func testAddAndCloneMenuItemsOpenTheirOwnDialogs() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let ui = UIDriver(view: RepositoryAddMenu(appState: f.app))
        try ui.fire("repositories.addGroup")
        XCTAssertTrue(f.app.showAddGroupSheet)
        XCTAssertFalse(f.app.showCloneSheet)
        f.app.showAddGroupSheet = false
        try ui.fire("repositories.clone")
        XCTAssertTrue(f.app.showCloneSheet)
        XCTAssertFalse(f.app.showAddGroupSheet)
    }

    func testAddingSeveralFoldersActivatesTheLastNewRepository() async throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let first = try await f.makeRepo("first")
        let last = try await f.makeRepo("last")
        f.platform.folders = [first, last, first]
        try UIDriver(view: RepositoryAddMenu(appState: f.app)).fire("repositories.add")
        try await awaitUI("finish adding the selected folders") {
            f.app.statusText.contains("skipped 1 folder")
        }
        XCTAssertEqual(f.app.allRepositories.map(\.path), [first.path, last.path])
        XCTAssertEqual(f.app.activeRepo?.path, last.path)
        XCTAssertEqual(f.app.appConfig.lastOpenedRepoID, f.app.activeRepo?.id)
        let saved = await f.app.config.loadRepositories()
        XCTAssertEqual(saved.ungrouped.map(\.path), [first.path, last.path])
    }

    func testGroupContextButtonUsesTheTargetGroup() async throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let first = try await f.makeRepo("first")
        let last = try await f.makeRepo("last")
        f.platform.folders = [first, last]
        let button = AddRepositoryButton(appState: f.app, targetGroup: "Work",
                                         identifier: "repositories.addToGroup.Work")
        try UIDriver(view: button).fire("repositories.addToGroup.Work")
        try await awaitUI("last repository loaded") {
            f.app.activeRepo?.path == last.path && f.app.journalVM.commits.first?.subject == "initial"
        }
        XCTAssertEqual(f.app.repositoriesConfig.groups.first?.name, "Work")
        XCTAssertEqual(f.app.repositoriesConfig.groups.first?.repositories.map(\.path), [first.path, last.path])
        XCTAssertTrue(f.app.repositoriesConfig.ungrouped.isEmpty)
    }

    func testCancellingThePickerKeepsTheOpenRepository() async throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let repo = try await f.makeRepo("existing")
        await f.open(repo)
        let before = f.app.activeRepo
        try UIDriver(view: RepositoryAddMenu(appState: f.app)).fire("repositories.add")
        XCTAssertEqual(f.app.activeRepo, before)
        XCTAssertEqual(f.app.allRepositories.count, 1)
        XCTAssertEqual(f.platform.pickerCalls, 1)
    }

    func testUnknownButtonIDFailsInsteadOfDoingNothing() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        XCTAssertThrowsError(try UIDriver(view: RepositoryAddMenu(appState: f.app)).fire("repositories.missing"))
        XCTAssertEqual(f.platform.pickerCalls, 0)
    }
}
