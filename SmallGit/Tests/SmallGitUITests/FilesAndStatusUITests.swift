import XCTest
import SwiftUI
import ViewInspector
@testable import SmallGit

@MainActor
final class FilesAndStatusUITests: XCTestCase {
    func testFileTypeButtonsFilterRowsButAlwaysKeepConflicts() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let vm = f.app.filesVM
        vm.files = [
            GitFileStatus(path: "staged.txt", indexStatus: "M", workTreeStatus: "."),
            GitFileStatus(path: "unstaged.txt", indexStatus: ".", workTreeStatus: "M"),
            GitFileStatus(path: "new.txt", indexStatus: "?", workTreeStatus: "?"),
            GitFileStatus(path: "conflict.txt", indexStatus: "U", workTreeStatus: "U", isConflict: true)
        ]
        let ui = UIDriver(view: FileTypeFilterBar(viewModel: vm, appState: f.app))
        XCTAssertEqual(vm.filteredFiles.count, 4)
        for id in ["files.showStaged", "files.showUnstaged", "files.showUntracked"] {
            try ui.fire(id)
        }
        XCTAssertEqual(vm.filteredFiles.map(\.path), ["conflict.txt"])
        try ui.fire("files.showUntracked")
        XCTAssertEqual(Set(vm.filteredFiles.map(\.path)), ["new.txt", "conflict.txt"])
    }

    func testTypingInTheFilterUpdatesTheDisplayedFileSet() async throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let repo = try await f.makeRepo("repo")
        try f.write("one", file: "keep.txt", at: repo)
        try f.write("two", file: "other.txt", at: repo)
        await f.open(repo)
        let ui = UIDriver(view: FilesTableView(appState: f.app, viewModel: f.app.filesVM))
        try ui.element("files.filter").textField().setInput("KEEP")
        XCTAssertEqual(f.app.filesVM.filteredFiles.map(\.path), ["keep.txt"])
        try ui.element("files.filter").textField().setInput("")
        XCTAssertEqual(f.app.filesVM.filteredFiles.count, 2)
    }

    func testIgnoredFilesButtonLoadsIgnoredRows() async throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let repo = try await f.makeRepo("repo")
        try f.write("ignored.txt\n", file: ".gitignore", at: repo)
        try f.write("ignored\n", file: "ignored.txt", at: repo)
        await f.open(repo)
        XCTAssertFalse(f.app.filesVM.files.contains { $0.path == "ignored.txt" })
        let ui = UIDriver(view: FileTypeFilterBar(viewModel: f.app.filesVM, appState: f.app))
        try ui.fire("files.showIgnored")
        try await awaitUI("ignored file appears") { f.app.filesVM.files.contains { $0.path == "ignored.txt" } }
        XCTAssertTrue(f.app.filesVM.filteredFiles.contains { $0.path == "ignored.txt" && $0.state == .ignored })
        try ui.fire("files.showIgnored")
        try await awaitUI("ignored file disappears") { !f.app.filesVM.files.contains { $0.path == "ignored.txt" } }
    }

    func testNoRepositoryShowsTheEmptyState() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let view = FilesTableView(appState: f.app, viewModel: f.app.filesVM)
        XCTAssertNoThrow(try view.inspect().find(text: "No repository open"))
        XCTAssertThrowsError(try UIDriver(view: view).element("files.filter"))
    }

    func testAssumeUnchangedButtonLoadsFlaggedPaths() async throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let repo = try await f.makeRepo("repo")
        try f.write("config\n", file: "local.txt", at: repo)
        try await f.git(["add", "local.txt"], at: repo)
        try await f.git(["commit", "-qm", "config"], at: repo)
        try await f.git(["update-index", "--assume-unchanged", "local.txt"], at: repo)
        try f.write("local changes\n", file: "local.txt", at: repo)
        await f.open(repo)
        XCTAssertTrue(f.app.filesVM.filteredFiles.isEmpty)
        let ui = UIDriver(view: FileTypeFilterBar(viewModel: f.app.filesVM, appState: f.app))
        try ui.fire("files.showAssumeUnchanged")
        try await awaitUI("flagged paths loaded") { f.app.filesVM.hasLoadedAssumeUnchanged }
        XCTAssertEqual(f.app.filesVM.filteredFiles.map(\.path), ["local.txt"])
        XCTAssertEqual(f.app.filesVM.filteredFiles.first?.isAssumeUnchanged, true)
    }

    func testBusyStatusShowsProgressAndTheCurrentFileCount() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let ui = UIDriver(view: StatusBar(statusText: "Pull…", changedFileCount: 7,
                                         cursorInfo: nil, isWorking: true))
        XCTAssertEqual(try ui.element("status.message").text().string(), "Pull…")
        XCTAssertEqual(try ui.element("status.fileCount").text().string(), "7 Files")
        XCTAssertNoThrow(try ui.element("status.progress").progressView())
        XCTAssertThrowsError(try ui.element("status.cursor"))
    }

    func testIdleStatusRemovesProgressAndShowsCursorPosition() throws {
        let f = try UIFixture()
        defer { f.cleanup() }
        let ui = UIDriver(view: StatusBar(statusText: "Ready", changedFileCount: 0,
                                         cursorInfo: "12:4", isWorking: false))
        XCTAssertThrowsError(try ui.element("status.progress"))
        XCTAssertEqual(try ui.element("status.cursor").text().string(), "12:4")
        XCTAssertEqual(try ui.element("status.message").text().string(), "Ready")
    }
}
