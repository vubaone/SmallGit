import XCTest
@testable import SmallGit

/// Covers the sidebar's repository folder tree.
///
/// The parts worth pinning down are the ones that decide whether the sidebar
/// stays usable on a real repository: that nothing is read until it is asked
/// for, that a listing is read once rather than on every update pass, and that
/// the flattened row list matches what the user has actually opened.
@MainActor
final class RepoTreeStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RepoTree-\(UUID().uuidString)")
        try makeTree()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A shape with the things that trip a file tree up: mixed case, files and
    /// folders interleaved, a dotfile directory, and a `.git`.
    private func makeTree() throws {
        let fm = FileManager.default
        for directory in ["src/deep", ".agents", ".git/objects", "Docs"] {
            try fm.createDirectory(at: root.appendingPathComponent(directory),
                                   withIntermediateDirectories: true)
        }
        for file in ["README.md", "apple.txt", "Banana.txt",
                     "src/main.swift", "src/deep/nested.swift",
                     ".agents/agent.md", ".git/objects/abc"] {
            try "x".write(to: root.appendingPathComponent(file),
                          atomically: true, encoding: .utf8)
        }
    }

    private func names(_ nodes: [RepoTreeNode]) -> [String] { nodes.map(\.name) }

    /// Waits for the store's detached directory read to land.
    private func settle(_ store: RepoTreeStore, path: String) async throws {
        for _ in 0..<200 {
            if store.loadedChildren(of: path) != nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("directory was never read: \(path)")
    }

    // MARK: - Listing

    func testFoldersComeFirstThenNamesCaseInsensitively() {
        let nodes = RepoTreeStore.scan(path: root.path, depth: 0)
        XCTAssertEqual(names(nodes), [".agents", "Docs", "src",
                                      "apple.txt", "Banana.txt", "README.md"])
    }

    /// Dotfiles are ordinary project content and stay; `.git` is plumbing and
    /// would bury the tree in loose objects.
    func testGitIsHiddenButOtherDotfilesAreNot() {
        let nodes = RepoTreeStore.scan(path: root.path, depth: 0)
        XCTAssertFalse(names(nodes).contains(".git"))
        XCTAssertTrue(names(nodes).contains(".agents"))
    }

    func testDirectoriesAreDistinguishedFromFiles() throws {
        let nodes = RepoTreeStore.scan(path: root.path, depth: 0)
        let src = try XCTUnwrap(nodes.first { $0.name == "src" })
        let readme = try XCTUnwrap(nodes.first { $0.name == "README.md" })
        XCTAssertTrue(src.isDirectory)
        XCTAssertFalse(readme.isDirectory)
    }

    func testDepthIsCarriedThrough() {
        XCTAssertTrue(RepoTreeStore.scan(path: root.path, depth: 3).allSatisfy { $0.depth == 3 })
    }

    /// An unreadable or absent directory renders as empty rather than taking
    /// the sidebar down around it.
    func testAMissingDirectoryScansEmpty() {
        XCTAssertTrue(RepoTreeStore.scan(path: root.path + "/nope", depth: 0).isEmpty)
    }

    // MARK: - Laziness

    /// The property the sidebar depends on: a collapsed repository costs
    /// nothing, however large it is.
    func testNothingIsReadUntilExpanded() {
        let store = RepoTreeStore()
        XCTAssertTrue(store.rows(under: root.path).isEmpty)
        XCTAssertNil(store.loadedChildren(of: root.path))
    }

    func testExpandingReadsTheDirectory() async throws {
        let store = RepoTreeStore()
        store.expand(root.path)
        try await settle(store, path: root.path)

        XCTAssertTrue(store.isExpanded(root.path))
        XCTAssertEqual(names(store.rows(under: root.path)).first, ".agents")
    }

    /// Collapsing keeps the listing, so reopening a large directory doesn't
    /// pay for a second scan.
    func testCollapsingHidesRowsButKeepsTheListing() async throws {
        let store = RepoTreeStore()
        store.expand(root.path)
        try await settle(store, path: root.path)

        store.collapse(root.path)

        XCTAssertTrue(store.rows(under: root.path).isEmpty)
        XCTAssertNotNil(store.loadedChildren(of: root.path), "re-expanding must not rescan")
    }

    /// Child paths must extend the path they were asked about. `FileManager`'s
    /// URL listing returns resolved paths — `/var/…` comes back as
    /// `/private/var/…` — which would leave a parent and its children keyed
    /// differently, and expanding a folder would splice its rows in nowhere.
    func testChildPathsExtendTheRequestedPath() {
        let nodes = RepoTreeStore.scan(path: root.path, depth: 0)
        XCTAssertFalse(nodes.isEmpty)
        for node in nodes {
            XCTAssertEqual(node.path, (root.path as NSString).appendingPathComponent(node.name))
            XCTAssertTrue(node.path.hasPrefix(root.path + "/"))
        }
    }

    // MARK: - Flattening

    /// Rows come back in display order with nested content spliced in at its
    /// parent's position — which is what makes the flat list render as a tree.
    func testExpandedChildrenAppearBeneathTheirParent() async throws {
        let store = RepoTreeStore()
        store.expand(root.path)
        try await settle(store, path: root.path)

        let src = root.appendingPathComponent("src").path
        store.expand(src, depth: 1)
        try await settle(store, path: src)

        let rows = names(store.rows(under: root.path))
        let srcIndex = try XCTUnwrap(rows.firstIndex(of: "src"))
        XCTAssertEqual(Array(rows[srcIndex...].prefix(3)), ["src", "deep", "main.swift"])
    }

    func testUnexpandedFoldersContributeNoRows() async throws {
        let store = RepoTreeStore()
        store.expand(root.path)
        try await settle(store, path: root.path)

        XCTAssertFalse(names(store.rows(under: root.path)).contains("main.swift"))
    }

    // MARK: - Refresh

    func testRefreshPicksUpAFileAddedOnDisk() async throws {
        let store = RepoTreeStore()
        store.expand(root.path)
        try await settle(store, path: root.path)
        XCTAssertFalse(names(store.rows(under: root.path)).contains("added.txt"))

        try "x".write(to: root.appendingPathComponent("added.txt"),
                      atomically: true, encoding: .utf8)
        store.refresh(root.path)
        try await settle(store, path: root.path)

        XCTAssertTrue(names(store.rows(under: root.path)).contains("added.txt"))
    }

    /// Refreshing drops descendants too — their listings describe a directory
    /// that may not exist any more.
    func testRefreshDropsCachedDescendants() async throws {
        let store = RepoTreeStore()
        store.expand(root.path)
        try await settle(store, path: root.path)
        let src = root.appendingPathComponent("src").path
        store.expand(src, depth: 1)
        try await settle(store, path: src)

        store.refresh(root.path)

        XCTAssertNil(store.loadedChildren(of: src))
        XCTAssertFalse(store.isExpanded(src))
    }

    // MARK: - Pruning

    func testPruningForgetsRepositoriesThatAreGone() async throws {
        let store = RepoTreeStore()
        store.expand(root.path)
        try await settle(store, path: root.path)

        store.prune(keepingUnder: ["/somewhere/else"])

        XCTAssertNil(store.loadedChildren(of: root.path))
        XCTAssertFalse(store.isExpanded(root.path))
    }

    func testPruningKeepsRepositoriesThatRemain() async throws {
        let store = RepoTreeStore()
        store.expand(root.path)
        try await settle(store, path: root.path)
        let src = root.appendingPathComponent("src").path
        store.expand(src, depth: 1)
        try await settle(store, path: src)

        store.prune(keepingUnder: [root.path])

        XCTAssertNotNil(store.loadedChildren(of: root.path))
        XCTAssertNotNil(store.loadedChildren(of: src), "nested listings survive too")
    }

    /// A sibling repository whose path is a prefix of another's name must not
    /// be treated as being inside it.
    func testPruningComparesWholePathComponents() async throws {
        let store = RepoTreeStore()
        store.expand(root.path)
        try await settle(store, path: root.path)

        store.prune(keepingUnder: [root.path + "-other"])

        XCTAssertNil(store.loadedChildren(of: root.path))
    }
}
