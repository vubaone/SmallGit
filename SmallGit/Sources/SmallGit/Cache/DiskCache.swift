import Foundation

/// L2 — JSON files under `~/Library/Caches/SmallGit/<repo-hash>/`.
///
/// Survives app restarts; per-repo directory; auto-purgeable by macOS.
actor DiskCache {
    static let shared = DiskCache()

    private let baseDir: URL
    private let fm = FileManager.default

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDir = baseDirectory
            try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            return
        }
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches")
        self.baseDir = caches.appendingPathComponent("SmallGit", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    // MARK: - Read

    /// Hits and misses are logged under *different* operation names rather
    /// than as one `cache.load` with a flag. The summary groups by operation,
    /// so this way the hit rate reads straight off it — and a cache that has
    /// quietly stopped serving anything is one of the easier ways for an app
    /// to look like it has an I/O problem when it has a caching problem.
    func load<T: Codable & Sendable>(
        key: CacheKey,
        repoPath: String,
        as _: T.Type
    ) -> CacheEntry<T>? {
        let clock = LogClock()
        let url = fileURL(for: key, repoPath: repoPath)
        guard let data = try? Data(contentsOf: url) else {
            Log.disk("cache.miss", detail: key.diskFileName, ms: clock.elapsedMs)
            return nil
        }
        let entry = try? Self.decoder.decode(CacheEntry<T>.self, from: data)
        Log.disk(
            entry == nil ? "cache.corrupt" : "cache.hit",
            detail: key.diskFileName,
            ms: clock.elapsedMs,
            bytes: data.count,
            outcome: entry == nil ? .failed : .ok,
            message: entry == nil ? "decode failed" : nil
        )
        return entry
    }

    // MARK: - Write

    func save<T: Codable & Sendable>(
        key: CacheKey,
        repoPath: String,
        entry: CacheEntry<T>
    ) {
        let clock = LogClock()
        let dir = repoDir(repoPath: repoPath)
        let url = dir.appendingPathComponent(key.diskFileName)
        guard let data = try? Self.encoder.encode(entry) else {
            Log.disk("cache.save", detail: key.diskFileName, ms: clock.elapsedMs,
                     outcome: .failed, message: "encode failed")
            return
        }
        do {
            try data.write(to: url, options: [.atomic])
            Log.disk("cache.save", detail: key.diskFileName, ms: clock.elapsedMs, bytes: data.count)
        } catch {
            Log.disk("cache.save", detail: key.diskFileName, ms: clock.elapsedMs,
                     bytes: data.count, outcome: .failed, message: error.localizedDescription)
        }
    }

    // MARK: - Invalidate

    func remove(key: CacheKey, repoPath: String) {
        let clock = LogClock()
        let url = fileURL(for: key, repoPath: repoPath)
        try? fm.removeItem(at: url)
        Log.disk("cache.remove", detail: key.diskFileName, ms: clock.elapsedMs)
    }

    /// Drop every cached log for the repo, whatever ref selection it was
    /// fetched for — the disk half of `MemoryCache.invalidateLogs`, and for
    /// the same reason: a log key carries a hash of its selection, so a ref
    /// that moves cannot be mapped back to the entries it invalidates.
    func removeLogs(repoPath: String) {
        let clock = LogClock()
        let dir = repoDir(repoPath: repoPath)
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix(CacheKey.logDiskFilePrefix) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
            removed += 1
        }
        Log.disk(
            "cache.removeLogs",
            detail: repoPath,
            ms: clock.elapsedMs,
            message: "\(removed) removed"
        )
    }

    func removeAll(repoPath: String) {
        let clock = LogClock()
        try? fm.removeItem(at: repoDir(repoPath: repoPath))
        Log.disk("cache.removeAll", detail: repoPath, ms: clock.elapsedMs)
    }

    /// Evict per-repo cache directories older than `maxAge`.
    /// Default is 7 days — repos the user hasn't opened recently.
    func evictStale(maxAge: TimeInterval = 7 * 24 * 3600) {
        let clock = LogClock()
        guard let contents = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)
        var evicted = 0
        for dir in contents {
            guard let values = try? dir.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? fm.removeItem(at: dir)
            evicted += 1
        }
        Log.disk(
            "cache.evictStale",
            detail: "\(contents.count) repo dirs scanned",
            ms: clock.elapsedMs,
            message: "\(evicted) evicted"
        )
    }

    // MARK: - Paths

    private func repoDir(repoPath: String) -> URL {
        let dir = baseDir.appendingPathComponent(repoPath.stableHash, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func fileURL(for key: CacheKey, repoPath: String) -> URL {
        repoDir(repoPath: repoPath).appendingPathComponent(key.diskFileName)
    }
}
