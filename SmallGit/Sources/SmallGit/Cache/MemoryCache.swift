import Foundation

/// L1 — in-process, instant reads, lives for the app session.
///
/// Type-erased over heterogeneous `CacheEntry<T>` values via an internal
/// protocol box. Reads/writes are scoped to `@MainActor` so it can be
/// composed with `@Observable` view-models without extra synchronization.
@MainActor
final class MemoryCache {

    private var store: [CacheKey: any AnyMemoryEntry] = [:]
    /// Keys in least-recently-used order; the last entry is the newest touch.
    private var recency: [CacheKey] = []
    private let maxEntries: Int

    /// Why there is a cap at all: `CacheKey.diff(file:mode:compact:)` is one
    /// key *per file per mode*, so browsing a repository's files accumulates a
    /// diff in memory for every one of them and nothing ever evicts it. The
    /// cache is cleared when the repository changes, but within a single
    /// session on a large repository that is unbounded growth.
    ///
    /// 120 is generous: a repository's non-diff keys number about six, so the
    /// rest is roughly the last hundred files looked at — far more than anyone
    /// scrolls back through, and a miss only costs one `git diff`.
    ///
    /// The cap counts entries, not bytes. Sizing by bytes would mean encoding
    /// every value to measure it, which costs more than the eviction saves;
    /// this bounds the count that grows without limit, which is the actual
    /// defect.
    init(maxEntries: Int = 120) {
        self.maxEntries = max(1, maxEntries)
    }

    func get<T: Codable & Sendable>(_ key: CacheKey, as type: T.Type) -> T? {
        guard let value = (store[key] as? TypedMemoryEntry<T>)?.entry.value else { return nil }
        touch(key)
        return value
    }

    func set<T: Codable & Sendable>(_ key: CacheKey, value: T, gitRef: String? = nil) {
        setEntry(key, entry: CacheEntry(value: value, gitRef: gitRef))
    }

    func setEntry<T: Codable & Sendable>(_ key: CacheKey, entry: CacheEntry<T>) {
        store[key] = TypedMemoryEntry(entry: entry)
        touch(key)
        evictIfNeeded()
    }

    func invalidate(_ key: CacheKey) {
        store.removeValue(forKey: key)
        recency.removeAll { $0 == key }
    }

    func invalidate(_ keys: Set<CacheKey>) {
        for key in keys { store.removeValue(forKey: key) }
        recency.removeAll { keys.contains($0) }
    }

    /// Drop every cached log, whatever ref selection it was fetched for.
    /// A log key carries a hash of its selection, so a ref moving can't be
    /// mapped back to the individual entries it invalidates — but every
    /// one of them is suspect, and a log is cheap to re-read.
    func invalidateLogs() {
        let stale = store.keys.filter(\.isLog)
        for key in stale { store.removeValue(forKey: key) }
        recency.removeAll { $0.isLog }
    }

    func invalidateAll() {
        store.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
    }

    /// Number of entries held, for tests and diagnostics.
    var count: Int { store.count }

    private func touch(_ key: CacheKey) {
        // Linear, but `recency` is bounded by `maxEntries` — a hash-plus-list
        // LRU would be faster asymptotically and slower in practice at this
        // size, for more moving parts.
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func evictIfNeeded() {
        while store.count > maxEntries, let oldest = recency.first {
            recency.removeFirst()
            store.removeValue(forKey: oldest)
        }
    }

    func has(_ key: CacheKey) -> Bool {
        store[key] != nil
    }

    func age(_ key: CacheKey) -> TimeInterval? {
        store[key]?.age
    }

    var keys: Set<CacheKey> {
        Set(store.keys)
    }
}

// MARK: - Type erasure

protocol AnyMemoryEntry {
    var age: TimeInterval { get }
}

private struct TypedMemoryEntry<T: Codable & Sendable>: AnyMemoryEntry {
    let entry: CacheEntry<T>
    var age: TimeInterval { entry.age }
}
