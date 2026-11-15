import XCTest
@testable import SmallGit

/// `probeWorkTree` is what the Repositories panel asks before it labels a
/// row, and its three answers have to stay three. "Not a repository" is a
/// verdict that sticks until the app is relaunched, so a question git never
/// got to answer must not produce it.
final class WorkTreeProbeTests: XCTestCase {

    private var root: URL!
    private let git = GitService.shared

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                          "git not available")
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func initRepository(at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "init", "-q", "-b", "main", "."]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    func testRepositoryRootAnswersWithItsOwnPath() async throws {
        try initRepository(at: root)
        let probe = await git.probeWorkTree(at: root.path)
        guard case .workTree(let reported) = probe else {
            return XCTFail("Expected a work tree, got \(probe)")
        }
        // `--show-toplevel` resolves symlinks, and /tmp is one, so the two
        // are compared the way `AppState.detectAvailability` compares them.
        XCTAssertEqual(
            URL(fileURLWithPath: reported).resolvingSymlinksInPath().path,
            root.resolvingSymlinksInPath().path
        )
    }

    func testPlainFolderIsNotARepository() async throws {
        let probe = await git.probeWorkTree(at: root.path)
        XCTAssertEqual(probe, .notARepository)
    }

    func testSubdirectoryReportsTheRootAboveIt() async throws {
        try initRepository(at: root)
        let sub = root.appendingPathComponent("src/nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let probe = await git.probeWorkTree(at: sub.path)
        guard case .workTree(let reported) = probe else {
            return XCTFail("Expected a work tree, got \(probe)")
        }
        // The sidebar's rows are roots, so the caller turns this into
        // "Not a Repo" — but by comparing paths, not by git refusing.
        XCTAssertNotEqual(
            URL(fileURLWithPath: reported).resolvingSymlinksInPath().path,
            sub.resolvingSymlinksInPath().path
        )
    }

    /// Git that cannot even be started says nothing about the folder. This
    /// is the case that used to paint every repository in the sidebar
    /// "Not a Repo" at once when the app ran out of file descriptors.
    func testGitThatCannotRunIsNotAnAnswer() async throws {
        let missing = root.appendingPathComponent("gone").path
        let probe = await git.probeWorkTree(at: missing)
        XCTAssertEqual(probe, .unknown)
    }
}
