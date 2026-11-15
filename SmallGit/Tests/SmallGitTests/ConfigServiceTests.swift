import XCTest
@testable import SmallGit

final class ConfigServiceTests: XCTestCase {

    func testInvalidConfigIsPreservedBeforeDefaulting() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmallGitConfigServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appendingPathComponent("config.json")
        try "{ invalid json".write(to: configURL, atomically: true, encoding: .utf8)

        let service = ConfigService(supportDirectory: dir)
        let loaded = await service.loadAppConfig()

        XCTAssertEqual(loaded.fontSize, 13)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("config.json.invalid-") }
        XCTAssertEqual(backups.count, 1)
    }
}
