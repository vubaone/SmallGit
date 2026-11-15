import XCTest
@testable import SmallGit

/// Covers the caps that stop the in-memory caches growing without limit.
///
/// Both were unbounded: the git cache holds one entry per file per diff mode,
/// and the sidebar tree held a listing for every directory ever expanded in
/// every repository. Neither is a leak — both are cleared eventually — but
/// within one session on a large project both grow with use and nothing
/// reclaims them.
@MainActor
final class CacheEvictionTests: XCTestCase {

    // MARK: - MemoryCache

    private func diffKey(_ name: String) -> CacheKey {
        .diff(file: name, mode: .indexVsWorkingTree, compact: true)
    }

    func testTheCacheStopsGrowingAtItsCap() {
        let cache = MemoryCache(maxEntries: 10)
        for i in 0..<100 {
            cache.set(diffKey("file-\(i).swift"), value: ["line"])
        }
        XCTAssertEqual(cache.count, 10)
    }

    /// The newest entries are the ones worth keeping — they are what the user
    /// is looking at.
    func testTheOldestEntriesAreDroppedFirst() {
        let cache = MemoryCache(maxEntries: 3)
        for name in ["a", "b", "c", "d"] {
            cache.set(diffKey(name), value: [name])
        }
        XCTAssertNil(cache.get(diffKey("a"), as: [String].self), "the oldest went")
        XCTAssertNotNil(cache.get(diffKey("d"), as: [String].self))
    }

    /// Reading counts as use. Without this a file the user keeps returning to
    /// would be evicted while files they opened once and left survive.
    func testReadingAnEntryProtectsItFromEviction() {
        let cache = MemoryCache(maxEntries: 3)
        for name in ["a", "b", "c"] { cache.set(diffKey(name), value: [name]) }

        _ = cache.get(diffKey("a"), as: [String].self)   // a is now the newest
        cache.set(diffKey("d"), value: ["d"])            // evicts the oldest

        XCTAssertNotNil(cache.get(diffKey("a"), as: [String].self), "recently read, so kept")
        XCTAssertNil(cache.get(diffKey("b"), as: [String].self), "untouched longest, so dropped")
    }

    /// Re-writing a key must not add a second slot for it.
    func testOverwritingAKeyDoesNotConsumeExtraCapacity() {
        let cache = MemoryCache(maxEntries: 3)
        for _ in 0..<20 { cache.set(diffKey("same"), value: ["x"]) }
        XCTAssertEqual(cache.count, 1)
    }

    func testInvalidatingFreesCapacity() {
        let cache = MemoryCache(maxEntries: 3)
        for name in ["a", "b", "c"] { cache.set(diffKey(name), value: [name]) }
        cache.invalidate(diffKey("a"))
        cache.set(diffKey("d"), value: ["d"])

        XCTAssertNotNil(cache.get(diffKey("b"), as: [String].self),
                        "the freed slot took the new entry, not an eviction")
        XCTAssertEqual(cache.count, 3)
    }

    func testInvalidateAllEmptiesIt() {
        let cache = MemoryCache(maxEntries: 10)
        for name in ["a", "b"] { cache.set(diffKey(name), value: [name]) }
        cache.invalidateAll()
        XCTAssertEqual(cache.count, 0)
        cache.set(diffKey("c"), value: ["c"])
        XCTAssertEqual(cache.count, 1, "recency was cleared alongside the store")
    }

    // MARK: - RepoTreeStore

    private func makeDirectories(_ count: Int) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Evict-\(UUID().uuidString)")
        for i in 0..<count {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("dir-\(i)"), withIntermediateDirectories: true
            )
        }
        return root
    }

    private func settle(_ store: RepoTreeStore, path: String) async throws {
        for _ in 0..<200 {
            if store.loadedChildren(of: path) != nil { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("never read: \(path)")
    }

    func testTheTreeStopsCachingListingsAtItsCap() async throws {
        let root = try makeDirectories(12)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RepoTreeStore(maxCachedListings: 4)

        for i in 0..<12 {
            let path = root.appendingPathComponent("dir-\(i)").path
            store.expand(path)
            try await settle(store, path: path)
            store.collapse(path)
        }

        var cached = 0
        for i in 0..<12 where store.loadedChildren(of: root.appendingPathComponent("dir-\(i)").path) != nil {
            cached += 1
        }
        XCTAssertLessThanOrEqual(cached, 4)
        XCTAssertGreaterThan(cached, 0, "it keeps the recent ones rather than emptying itself")
    }

    /// An expanded directory's listing is what draws its rows, so evicting it
    /// would silently empty a folder the user is looking at.
    func testAnExpandedDirectoryIsNeverEvicted() async throws {
        let root = try makeDirectories(12)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RepoTreeStore(maxCachedListings: 2)

        let pinned = root.appendingPathComponent("dir-0").path
        store.expand(pinned)
        try await settle(store, path: pinned)

        for i in 1..<12 {
            let path = root.appendingPathComponent("dir-\(i)").path
            store.expand(path)
            try await settle(store, path: path)
            store.collapse(path)
        }

        XCTAssertNotNil(store.loadedChildren(of: pinned),
                        "still expanded, so its rows still need it")
    }
}
