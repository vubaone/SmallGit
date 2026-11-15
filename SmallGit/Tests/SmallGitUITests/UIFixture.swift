import XCTest
import SwiftUI
import AppKit
import ViewInspector
@testable import SmallGit

/// The suite never launches SmallGit or hosts a window. Views use this
/// isolated state and every system interaction goes through the fake below.
@MainActor
final class UIFixture {
    let root: URL
    let app: AppState
    let platform = UIPlatform()
    let runner = ProcessRunner(importsUserShellEnvironment: false)
    private let visibleWindows = Set(NSApp?.windows.filter(\.isVisible).map(\.windowNumber) ?? [])
    private let wasActive = NSApp?.isActive ?? false

    static var artifacts: URL {
        if let path = ProcessInfo.processInfo.environment["SMALLGIT_UI_ARTIFACTS"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ui-tests", isDirectory: true)
    }

    init(gitHubAuth: any GitHubAuthenticating = UnexpectedGitHubAuth()) throws {
        root = Self.artifacts.appendingPathComponent("fixtures/\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = GitService(runner: runner)
        app = AppState(
            coordinator: CacheCoordinator(diskCache: DiskCache(baseDirectory: root.appendingPathComponent("cache")),
                                          gitService: git),
            git: git, config: ConfigService(supportDirectory: root.appendingPathComponent("config")),
            platform: platform, gitHubAuth: gitHubAuth
        )
    }

    func cleanup() {
        app.cancelCredentialRequest()
        XCTAssertEqual(Set(NSApp?.windows.filter(\.isVisible).map(\.windowNumber) ?? []), visibleWindows,
                       "UI tests must not show windows")
        XCTAssertEqual(NSApp?.isActive ?? false, wasActive, "UI tests must not activate the application")
        app.fileWatcher.stop()
        app.coordinator.switchRepo(to: nil)
        app.activeRepo = nil
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func git(_ args: [String], at repo: URL) async throws -> GitCommandResult {
        let result = try await runner.run(in: repo.path, args: args)
        guard result.succeeded else {
            throw NSError(domain: "UIFixture.Git", code: Int(result.exitCode),
                          userInfo: [NSLocalizedDescriptionKey: result.combinedOutput])
        }
        return result
    }

    func makeRepo(_ name: String) async throws -> URL {
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git(["-c", "core.hooksPath=/dev/null", "init", "-q", "-b", "main"], at: repo)
        for (key, value) in [("user.name", "UI Tests"), ("user.email", "ui@smallgit.test"),
                             ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            try await git(["config", key, value], at: repo)
        }
        try await git(["commit", "-qm", "initial", "--allow-empty"], at: repo)
        return repo
    }

    func clone(_ origin: URL, name: String) async throws -> URL {
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try await git(["clone", "-q", origin.path, repo.path], at: root)
        for (key, value) in [("user.name", "UI Tests"), ("user.email", "ui@smallgit.test"),
                             ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            try await git(["config", key, value], at: repo)
        }
        return repo
    }

    func open(_ repo: URL) async {
        await app.addRepository(at: repo.path)
        // These tests drive refresh explicitly. FSEvents timing belongs to
        // the integration suite, not to a button's completion condition.
        app.fileWatcher.stop()
    }

    func write(_ text: String, file: String, at repo: URL) throws {
        try text.write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }
}

struct UnexpectedGitHubAuth: GitHubAuthenticating {
    func connect(requiresWorkflowScope: Bool, progress: @escaping @Sendable (GitHubAuthState) async -> Void) async throws {
        XCTFail("UI tests must inject a fake GitHub authentication service")
        throw GitHubAuthError.notInstalled
    }
}

/// Queries the actual SwiftUI view, not a parallel table of ID → handlers.
/// Do not use ViewHosting: its macOS implementation orders a window front.
@MainActor
struct UIDriver<V: View> {
    private let makeView: () -> V

    init(view: @autoclosure @escaping () -> V) { makeView = view }

    func element(_ id: String) throws -> InspectableView<ViewType.ClassifiedView> {
        try makeView().inspect().find(viewWithAccessibilityIdentifier: id)
    }

    func fire(_ id: String) throws {
        try element(id).button().tap()
    }

    func primaryAction(_ id: String) throws {
        let element = try element(id)
        guard !element.isDisabled() else {
            throw NSError(domain: "UIDriver.Disabled", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(id) is disabled"])
        }
        try element.menu().callPrimaryAction()
    }
}

@MainActor
func awaitUI(_ description: String, until condition: () -> Bool,
             file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out: \(description)", file: file, line: line)
            throw NSError(domain: "UIDriver.Timeout", code: 1)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
final class UIPlatform: PlatformServices {
    var folders: [URL] = []
    private(set) var pickerCalls = 0
    private(set) var pushRejectionPrompts = 0
    func pickRepositoryFolders() -> [URL] { pickerCalls += 1; return folders }
    func confirmWarning(title: String, message: String, primaryButton: String) -> Bool { false }
    func resolvePushRejection(branch: String, remote: String) -> PushRejectionChoice {
        pushRejectionPrompts += 1
        return .cancel
    }
    func resolveBehindCheckout(branch: String, upstream: String, behind: Int) -> BehindCheckoutChoice { .cancel }
    func resolveDivergedBranch(branch: String, upstream: String, ahead: Int, behind: Int) -> DivergedBranchChoice { .cancel }
    func resolveRewrittenBaseRebase(onto: String, staleSubjects: [String], ownCount: Int) -> RewrittenRebaseChoice { .cancel }
    func resolveMerge(branch: String, into current: String, canFastForward: Bool) -> MergeChoice { .cancel }
    func resolveRevert(commit: String, canCommit: Bool) -> RevertChoice { .cancel }
    func revealInFinder(path: String) { XCTFail("Unexpected Finder interaction") }
    func openInFinder(path: String) { XCTFail("Unexpected Finder interaction") }
    func openInTerminal(path: String) { XCTFail("Unexpected Terminal interaction") }
    func openInEditor(path: String, appPath: String?, bundleIDs: [String]) { XCTFail("Unexpected editor interaction") }
    func copyToPasteboard(_ string: String) { XCTFail("Unexpected system pasteboard interaction") }
}
