import Foundation
import CoreServices

/// Wraps `FSEvents` to deliver coalesced filesystem change batches for a
/// set of directories. Designed for SmallGit's pattern: watch one active
/// repository at a time, fire a `@Sendable` callback with the affected
/// absolute paths so `InvalidationEngine` can map them to cache keys.
///
/// More than one root because a linked worktree's metadata is not inside the
/// checkout — see `RepoLayout.watchRoots`, which collapses to the single
/// work-tree root for an ordinary repository.
///
/// The class is `@unchecked Sendable` because the FSEvents stream and the
/// callback closure are mutated only from the actor's serial execution
/// context (the dispatch queue we own). The C callback bridges back into
/// Swift via `Unmanaged` and copies paths off the C array immediately.
final class FileWatcherService: @unchecked Sendable {

    typealias Handler = @Sendable ([String]) -> Void

    private let queue = DispatchQueue(label: "com.smallgit.filewatcher", qos: .utility)

    /// Latency in seconds for FSEvents coalescing.
    private let latency: CFTimeInterval

    private var stream: FSEventStreamRef?
    private var handler: Handler?
    /// Paths currently being watched — used to suppress duplicate `start`
    /// invocations for the same directories.
    private(set) var watchedPaths: [String] = []

    init(latency: CFTimeInterval = 0.4) {
        self.latency = latency
    }

    deinit {
        // Best-effort teardown — actor isolation cannot be guaranteed here.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    // MARK: - Public

    /// Start (or restart) watching `directories`. The handler fires on the
    /// internal queue with the absolute paths affected by each batch.
    func start(directories: [String], handler: @escaping Handler) {
        guard !directories.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()

            self.handler = handler
            self.watchedPaths = directories

            let info = Unmanaged.passUnretained(self).toOpaque()
            var context = FSEventStreamContext(
                version: 0,
                info: info,
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let paths = directories as CFArray
            let flags: FSEventStreamCreateFlags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
            )

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                fsEventsCallback,
                &context,
                paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                self.latency,
                flags
            ) else {
                self.handler = nil
                self.watchedPaths = []
                return
            }

            FSEventStreamSetDispatchQueue(stream, self.queue)
            FSEventStreamStart(stream)
            self.stream = stream
            Log.watcher("fsevents.start", detail: directories.joined(separator: ", "))
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    // MARK: - Internal

    /// Caller must already be on `queue`.
    ///
    /// Logged even though a batch has no duration, because the failure mode
    /// here is *rate*: FSEvents coalesces at `latency`, so a healthy idle app
    /// produces no batches at all. A steady stream of them while nobody is
    /// touching the repository is the signature of the app's own writes
    /// feeding back into its watcher — the exact bug this project has already
    /// hit once with `git status` refreshing the index.
    fileprivate func dispatch(_ paths: [String]) {
        Log.watcher(
            "fsevents.batch",
            detail: paths.first.map { ($0 as NSString).lastPathComponent } ?? "",
            count: paths.count
        )
        handler?(paths)
    }

    private func stopLocked() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        handler = nil
        watchedPaths = []
    }
}

// MARK: - C callback

private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallbackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallbackInfo, numEvents > 0 else { return }
    let watcher = Unmanaged<FileWatcherService>.fromOpaque(info).takeUnretainedValue()

    let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self)
    let count = CFArrayGetCount(cfPaths)
    var paths: [String] = []
    paths.reserveCapacity(count)
    for i in 0..<count {
        let raw = CFArrayGetValueAtIndex(cfPaths, i)
        guard let raw else { continue }
        let cfStr = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        paths.append(cfStr as String)
    }

    watcher.dispatch(paths)
}
