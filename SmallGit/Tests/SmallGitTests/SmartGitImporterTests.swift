import XCTest
@testable import SmallGit

final class SmartGitImporterTests: XCTestCase {

    func testMaterializeAddsValidReposIntoGroups() async {
        let importer = SmartGitImporter()
        let config = SmartGitConfig(
            version: "25.1",
            configPath: URL(fileURLWithPath: "/tmp/smartgit"),
            repositories: [
                SmartGitRepository(path: "/repos/alpha", name: "alpha", group: "Work", valid: true),
                SmartGitRepository(path: "/repos/beta",  name: "beta",  group: "Work", valid: true),
                SmartGitRepository(path: "/repos/loose", name: "loose", group: nil,    valid: true),
                SmartGitRepository(path: "/repos/missing", name: "missing", group: "Work", valid: false)
            ],
            credentials: [],
            shortcuts: [:]
        )

        let result = await importer.materialize(
            config,
            into: RepositoriesConfig(),
            includeMissing: false
        )

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].name, "Work")
        XCTAssertEqual(result.groups[0].repositories.map(\.path), ["/repos/alpha", "/repos/beta"])
        XCTAssertEqual(result.ungrouped.map(\.path), ["/repos/loose"])
    }

    func testMaterializeRespectsExistingPaths() async {
        let importer = SmartGitImporter()
        let existing = RepositoriesConfig(
            groups: [RepositoryGroup(name: "Work", repositories: [
                RepositoryEntry(path: "/repos/alpha")
            ])],
            ungrouped: []
        )
        let config = SmartGitConfig(
            version: "25.1",
            configPath: URL(fileURLWithPath: "/tmp/smartgit"),
            repositories: [
                SmartGitRepository(path: "/repos/alpha", name: "alpha", group: "Work", valid: true),
                SmartGitRepository(path: "/repos/beta",  name: "beta",  group: "Work", valid: true)
            ],
            credentials: [],
            shortcuts: [:]
        )
        let result = await importer.materialize(config, into: existing)
        // alpha should NOT be duplicated; beta should be added to existing group.
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].repositories.map(\.path), ["/repos/alpha", "/repos/beta"])
    }

    func testMaterializeIncludeMissing() async {
        let importer = SmartGitImporter()
        let config = SmartGitConfig(
            version: "25.1",
            configPath: URL(fileURLWithPath: "/tmp/smartgit"),
            repositories: [
                SmartGitRepository(path: "/repos/gone", name: "gone", group: nil, valid: false)
            ],
            credentials: [],
            shortcuts: [:]
        )
        let withoutMissing = await importer.materialize(config, into: RepositoriesConfig(), includeMissing: false)
        XCTAssertTrue(withoutMissing.ungrouped.isEmpty)
        let withMissing = await importer.materialize(config, into: RepositoriesConfig(), includeMissing: true)
        XCTAssertEqual(withMissing.ungrouped.map(\.path), ["/repos/gone"])
    }
}
