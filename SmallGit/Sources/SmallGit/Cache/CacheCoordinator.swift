import Foundation
import Observation

/// Orchestrates the 3-layer cache (L1 memory → L2 disk → L3 git).
///
/// Views and view-models call `get` / `forceRefresh` only — they never
/// touch `GitService` directly. The coordinator decides whether a read
/// is satisfied from cache, returns stale data, and schedules background
/// refreshes.
@MainActor
@Observable
final class CacheCoordinator {

    // MARK: - Dependencies

    private let l1: MemoryCache
    private let l2: DiskCache
    private let git: GitService

    // MARK: - Repo context

    private(set) var activeRepoPath: String?

    /// A repository action can rewrite the index many times (pull/rebase,
    /// autostash, etc.). Keep panels on their last snapshot until it stops.
    @ObservationIgnored private var runningActions: [String: Int] = [:]
    @ObservationIgnored private(set) var readGeneration: UInt64 = 0
    @ObservationIgnored private var latestFetches: [CacheKey: UUID] = [:]

    var isActionRunning: Bool {
        guard let path = activeRepoPath else { return false }
        return runningActions[path, default: 0] > 0
    }

    func beginAction(repoPath: String) {
        runningActions[repoPath, default: 0] += 1
        if activeRepoPath == repoPath { readGeneration &+= 1 }
    }

    func endAction(repoPath: String) {
        let remaining = runningActions[repoPath, default: 0] - 1
        if remaining > 0 {
            runningActions[repoPath] = remaining
        } else {
            runningActions.removeValue(forKey: repoPath)
        }
        if activeRepoPath == repoPath { readGeneration &+= 1 }
    }

    /// Called when a background refresh has replaced a cached value *after*
    /// `get` already handed the stale one to a caller.
    ///
    /// Without it the fresh value only reaches the cache: the panel keeps
    /// drawing what it was given and nothing asks again. That is how a branch
    /// pushed while the app was looking at another repository keeps its
    /// `origin/<branch>` chip on the commit the remote used to be at — the
    /// decoration is baked into the cached log rows, the disk snapshot that
    /// outlived the push is what gets drawn, and the corrected rows land in
    /// L1 with no one to read them.
    var onBackgroundRefresh: ((CacheKey) -> Void)?

    // MARK: - In-flight tracking (dedup concurrent background refreshes)

    private var inFlight: Set<CacheKey> = []

    init(
        memoryCache: MemoryCache = MemoryCache(),
        diskCache: DiskCache = .shared,
        gitService: GitService = .shared
    ) {
        self.l1 = memoryCache
        self.l2 = diskCache
        self.git = gitService
    }

    // MARK: - Repo lifecycle

    func switchRepo(to path: String?) {
        guard activeRepoPath != path else { return }
        activeRepoPath = path
        readGeneration &+= 1
        latestFetches.removeAll()
        l1.invalidateAll()
        // L2 stays — it's per-repo on disk.
    }

    // MARK: - Read-through accessor

    /// Returns the cached value immediately if present (possibly stale),
    /// and triggers a background refresh when `maxAge` is exceeded.
    /// Falls through to L2, then to L3 (`fetcher`) on a full miss.
    func get<T: Codable & Sendable>(
        _ key: CacheKey,
        as type: T.Type,
        maxAge: TimeInterval? = nil,
        fetcher: @escaping @Sendable (String) async throws -> T
    ) async -> T? {
        guard let repoPath = activeRepoPath else { return nil }
        let generation = readGeneration

        // L1
        if let cached = l1.get(key, as: type) {
            if let maxAge, let age = l1.age(key), age > maxAge {
                scheduleBackgroundRefresh(key: key, repoPath: repoPath, fetcher: fetcher)
            }
            return cached
        }

        // L2
        if let diskEntry: CacheEntry<T> = await l2.load(key: key, repoPath: repoPath, as: type) {
            guard activeRepoPath == repoPath, readGeneration == generation else { return nil }
            l1.setEntry(key, entry: diskEntry)
            scheduleBackgroundRefresh(key: key, repoPath: repoPath, fetcher: fetcher)
            return diskEntry.value
        }

        // L3 (blocking — first ever read)
        guard activeRepoPath == repoPath, readGeneration == generation else { return nil }
        return await fetchAndCache(key: key, repoPath: repoPath, fetcher: fetcher)
    }

    /// Bypasses all caches and writes a fresh value into L1+L2.
    @discardableResult
    func forceRefresh<T: Codable & Sendable>(
        _ key: CacheKey,
        as type: T.Type,
        fetcher: @escaping @Sendable (String) async throws -> T
    ) async -> T? {
        guard let repoPath = activeRepoPath else { return nil }
        return await fetchAndCache(key: key, repoPath: repoPath, fetcher: fetcher)
    }

    // MARK: - Invalidation API

    func invalidate(_ keys: Set<CacheKey>) {
        // Any log key standing for "the log changed" retires all of them:
        // the journal can be graphing several refs at once under a hashed
        // key, and the change that moved one ref may well belong to a
        // selection this set can't name.
        if keys.contains(where: \.isLog) {
            l1.invalidateLogs()
            // Logs go from L2 as well, unlike everything below. The panel
            // refresh that follows re-fetches only the selection on screen,
            // so every *other* selection keeps a disk entry describing the
            // repo as it was before this change — and `get` hands that
            // snapshot straight to the journal the moment the user ticks
            // that ref, then merely schedules a background refresh the view
            // never re-reads. Dropping a disk entry can never serve stale
            // data; at worst it costs one `git log` the fetch would have
            // saved.
            if let repoPath = activeRepoPath {
                Task { [l2] in await l2.removeLogs(repoPath: repoPath) }
            }
        }
        l1.invalidate(keys)
        // L2 is left in place for everything else — it gets overwritten on
        // the next L3 fetch and serves as a fallback in the meantime.
    }

    func invalidate(_ key: CacheKey) {
        l1.invalidate(key)
    }

    func invalidateAll() {
        l1.invalidateAll()
    }

    /// Drop `keys` from BOTH L1 and L2. Unlike `invalidate`, this does not
    /// leave the disk entry as a fallback — use it when stale L2 data must
    /// not be served at all. Needed after a stage/unstage for the diff
    /// modes that aren't on screen: `get` would otherwise return the
    /// pre-change disk snapshot the moment the user switches to that mode
    /// (and only schedule a background refresh the view never observes).
    func purge(_ keys: Set<CacheKey>) async {
        l1.invalidate(keys)
        guard let repoPath = activeRepoPath else { return }
        for key in keys {
            await l2.remove(key: key, repoPath: repoPath)
        }
    }

    /// Drop every L2 (disk) entry for `repoPath`. Used by the
    /// init-repo flow to wipe any cache files the previous
    /// silently-added-parent bug may have left behind so the new
    /// empty repo isn't polluted with the parent's history.
    func purgeDiskCache(forRepoPath repoPath: String) async {
        await l2.removeAll(repoPath: repoPath)
    }

    func after(_ action: GitAction) {
        invalidate(InvalidationEngine.keysAfter(action))
    }

    /// Convenience invoked by `FileWatcherService`. Returns `true` when the
    /// batch actually mapped to one or more cache keys (i.e. something the UI
    /// shows became stale). Pure git-internal churn — `index.lock`,
    /// `COMMIT_EDITMSG`, `config`, … — maps to no key and returns `false`, so
    /// the caller can skip an otherwise pointless panel refresh.
    ///
    /// Takes the layout rather than deriving it from `activeRepoPath`: a
    /// linked worktree's metadata is not under the checkout at all, so the
    /// paths in a batch may name directories the coordinator never sees.
    @discardableResult
    func onFileSystemChange(paths: [String], layout: RepoLayout) -> Bool {
        guard activeRepoPath == layout.workTree else { return false }
        let keys = InvalidationEngine.keysToInvalidate(changedPaths: paths, layout: layout)
        guard !keys.isEmpty else { return false }
        invalidate(keys)
        return true
    }

    // MARK: - Internal

    private func scheduleBackgroundRefresh<T: Codable & Sendable>(
        key: CacheKey,
        repoPath: String,
        fetcher: @escaping @Sendable (String) async throws -> T
    ) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let fresh = await self.fetchAndCache(key: key, repoPath: repoPath, fetcher: fetcher)
            self.inFlight.remove(key)
            // Only when the repository is still the one this was fetched for:
            // a switch mid-flight makes the value belong to a panel nobody is
            // looking at any more.
            guard fresh != nil, self.activeRepoPath == repoPath else { return }
            self.onBackgroundRefresh?(key)
        }
    }

    private func fetchAndCache<T: Codable & Sendable>(
        key: CacheKey,
        repoPath: String,
        fetcher: @Sendable (String) async throws -> T
    ) async -> T? {
        let generation = readGeneration
        let fetchID = UUID()
        latestFetches[key] = fetchID
        defer {
            if latestFetches[key] == fetchID { latestFetches.removeValue(forKey: key) }
        }
        do {
            let value = try await fetcher(repoPath)
            let headRef = try? await git.currentHeadSHA(repoPath: repoPath)
            // A read started before an action or repo switch, or overtaken
            // by a newer refresh, must not replace the final snapshot in L1
            // and then get delivered back to the panel as a correction.
            guard activeRepoPath == repoPath, readGeneration == generation,
                  latestFetches[key] == fetchID else { return nil }
            let entry = CacheEntry(value: value, gitRef: headRef)
            l1.setEntry(key, entry: entry)
            Task { [l2] in
                await l2.save(key: key, repoPath: repoPath, entry: entry)
            }
            return value
        } catch {
            return nil
        }
    }
}
