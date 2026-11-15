import XCTest
@testable import SmallGit

/// Read-only sanity check against the real SmartGit install on the
/// developer's machine, if one exists. Skipped silently otherwise so CI
/// never depends on local state.
final class SmartGitImporterLiveTests: XCTestCase {

    func testParsesLocalSmartGitConfigIfPresent() async throws {
        guard ProcessInfo.processInfo.environment["SMALLGIT_RUN_LOCAL_SMARTGIT_TESTS"] == "1" else {
            throw XCTSkip("Set SMALLGIT_RUN_LOCAL_SMARTGIT_TESTS=1 to inspect local SmartGit config")
        }

        let importer = SmartGitImporter()
        guard let detected = await importer.detect() else {
            throw XCTSkip("No SmartGit install at ~/Library/Preferences/SmartGit/")
        }
        // Sanity: if a SmartGit install exists at all we expect at least one
        // repo (the user's "recentlyUsed" list almost always has entries).
        XCTAssertGreaterThan(detected.repositories.count, 0)
    }
}
