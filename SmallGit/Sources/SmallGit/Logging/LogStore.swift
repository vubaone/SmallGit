import Foundation

/// Append-only, size-capped diagnostic log.
///
/// Three constraints shape this, and they pull against each other:
///
/// 1. **It must not distort what it measures.** A logger that writes
///    synchronously would add a disk write to every operation it times —
///    including the disk operations — so the numbers would describe the
///    logger. Records are buffered in memory and flushed on a background
///    queue, which turns thousands of tiny writes into one write a second.
/// 2. **It must be callable from anywhere.** Records come from two actors
///    (`ProcessRunner`, `DiskCache`), a `nonisolated` config write, the
///    FSEvents queue, and the main actor. So `record` is a plain synchronous
///    method guarded by a lock rather than actor-isolated — an `await` at
///    those call sites would reorder the very work being measured.
/// 3. **It must stay inside 5 MB.** Not one 5 MB file that is deleted whole
///    on rotation, which would throw away all history at the worst moment.
///    Two files of half that: the live one and its predecessor, so there is
///    always between 2.5 MB and 5 MB of history on disk.
///
/// The file lives under `~/Library/Logs/SmallGit/`, deliberately nowhere near
/// a repository — writing a log into a directory the app's own `FileWatcher`
/// observes would generate the FSEvents it is meant to be recording.
final class LogStore: @unchecked Sendable {

    static let shared = LogStore()

    /// 5 MB total, as two 2.5 MB files.
    static let defaultMaxTotalBytes = 5 * 1024 * 1024

    private let directory: URL
    private let maxTotalBytes: Int
    /// Flush after this long, so a burst of records costs one write.
    private let flushInterval: TimeInterval
    /// …or immediately once the buffer reaches this, so a storm of events
    /// can't grow the buffer without bound between ticks.
    private let flushThreshold: Int

    private let queue: DispatchQueue
    private let lock = NSLock()

    private var buffer: [LogRecord] = []
    private var flushScheduled = false
    private var enabled = true
    /// Set when the log directory can't be created or written. Stops the
    /// store retrying — and failing — on every single record.
    private var writeDisabled = false

    init(
        directory: URL? = nil,
        maxTotalBytes: Int = LogStore.defaultMaxTotalBytes,
        flushInterval: TimeInterval = 1.0,
        flushThreshold: Int = 256,
        queue: DispatchQueue? = nil
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.maxTotalBytes = maxTotalBytes
        self.flushInterval = flushInterval
        self.flushThreshold = flushThreshold
        self.queue = queue ?? DispatchQueue(label: "com.smallgit.logstore", qos: .utility)
    }

    static var defaultDirectory: URL {
        // Under XCTest, somewhere disposable instead.
        //
        // The instrumentation lives in `ProcessRunner` and `DiskCache`, which
        // the integration suites drive directly — so every `git init`, commit
        // and push those tests run against their temp repositories was landing
        // in the user's real diagnostics log. Observed: a single `swift test`
        // added 1,601 records of `/var/folders/…` traffic, burning through the
        // 5 MB budget and burying the app's own activity under fixtures.
        if isRunningTests {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SmallGitTestLogs", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/SmallGit", isDirectory: true)
    }

    /// True in a test process, false in the app.
    ///
    /// The loaded-class check is the one that actually works everywhere: the
    /// app target never links XCTest, so the class is absent there and present
    /// in any test runner. `XCTestConfigurationFilePath` is checked too, but
    /// only Xcode's runner sets it — under `swift test` it is unset, which is
    /// exactly how the first version of this let the suite write to the user's
    /// real log anyway.
    static var isRunningTests: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The live file. The previous generation sits beside it as `.1`.
    var currentURL: URL { directory.appendingPathComponent("smallgit.log") }
    var previousURL: URL { directory.appendingPathComponent("smallgit.1.log") }

    private var maxFileBytes: Int { max(1024, maxTotalBytes / 2) }

    // MARK: - Writing

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    /// Turning logging off drops the buffered records too. Keeping them would
    /// mean they surface later if it is switched back on, dated to a session
    /// the user had already opted out of recording.
    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        if !value { buffer.removeAll(keepingCapacity: false) }
        lock.unlock()
    }

    /// Returns immediately. The record is written on the background queue.
    func record(_ record: LogRecord) {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return
        }
        buffer.append(record)
        let shouldFlushNow = buffer.count >= flushThreshold
        let shouldSchedule = !flushScheduled && !shouldFlushNow
        if shouldFlushNow {
            flushScheduled = false
        } else if shouldSchedule {
            flushScheduled = true
        }
        lock.unlock()

        if shouldFlushNow {
            queue.async { [weak self] in self?.performFlush() }
        } else if shouldSchedule {
            queue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.flushScheduled = false
                self.lock.unlock()
                self.performFlush()
            }
        }
    }

    /// Writes anything buffered and waits for it to land.
    ///
    /// Needed in two places: before reading, or the newest records — the ones
    /// the user just went looking for — would be invisible; and at app
    /// termination, where a background flush would not get to run.
    func flushNow() {
        queue.sync { performFlush() }
    }

    private func performFlush() {
        lock.lock()
        guard !writeDisabled, !buffer.isEmpty else {
            lock.unlock()
            return
        }
        let pending = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()

        // A batch bigger than a whole generation would blow the cap the moment
        // it landed, since rotation only moves what is already on disk. Drop
        // its oldest records so the promise holds unconditionally rather than
        // only for batch sizes we happen to expect.
        let data = Self.trimmingLeadingLines(LogCodec.encode(pending), to: maxFileBytes)
        guard !data.isEmpty else { return }

        do {
            try ensureDirectory()
            try rotateIfNeeded(incoming: data.count)
            try append(data)
        } catch {
            // Nowhere to report this — the reporting channel is what failed.
            // Give up permanently rather than retry per record: a read-only
            // Library or a full disk will not fix itself, and a logger that
            // throws on every operation is worse than one that is silent.
            lock.lock()
            writeDisabled = true
            lock.unlock()
        }
    }

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Moves the live file aside once it would exceed its half of the budget.
    ///
    /// Checked *before* writing rather than after, so the cap is never
    /// exceeded even briefly — the alternative lets a large batch push the
    /// file over and only corrects on the next flush.
    private func rotateIfNeeded(incoming: Int) throws {
        let current = fileSize(currentURL)
        guard current > 0, current + incoming > maxFileBytes else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: previousURL.path) {
            try fm.removeItem(at: previousURL)
        }
        try fm.moveItem(at: currentURL, to: previousURL)
    }

    private func append(_ data: Data) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: currentURL.path) {
            guard fm.createFile(atPath: currentURL.path, contents: data) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return
        }
        let handle = try FileHandle(forWritingTo: currentURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Drops whole leading records until `data` fits in `limit`.
    ///
    /// Whole records, never a byte prefix: the format is one JSON object per
    /// line, and cutting mid-line would leave a fragment at the head of the
    /// file. The decoder tolerates that, but it would silently cost a record
    /// that could have been kept intact instead.
    static func trimmingLeadingLines(_ data: Data, to limit: Int) -> Data {
        guard data.count > limit else { return data }
        var start = data.startIndex
        while data.count - (start - data.startIndex) > limit {
            guard let newline = data[start...].firstIndex(of: 0x0A) else { return Data() }
            start = data.index(after: newline)
        }
        return Data(data[start...])
    }

    private func fileSize(_ url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    // MARK: - Reading

    /// Bytes currently on disk across both generations.
    var totalSizeBytes: Int {
        fileSize(previousURL) + fileSize(currentURL)
    }

    var sizeLimitBytes: Int { maxTotalBytes }

    /// The most recent `limit` records, oldest first.
    ///
    /// Reads the previous generation before the current one so the result
    /// stays in chronological order across a rotation. `limit` bounds what the
    /// viewer has to hold and lay out — the file itself can hold far more
    /// records than anyone will scroll through.
    func read(limit: Int = 20_000) -> [LogRecord] {
        flushNow()
        var records: [LogRecord] = []
        for url in [previousURL, currentURL] {
            guard let data = try? Data(contentsOf: url) else { continue }
            records.append(contentsOf: LogCodec.decode(data))
        }
        if records.count > limit {
            records.removeFirst(records.count - limit)
        }
        return records
    }

    /// Drops everything, on disk and buffered.
    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        queue.sync {
            try? FileManager.default.removeItem(at: currentURL)
            try? FileManager.default.removeItem(at: previousURL)
            lock.lock()
            // A previous write failure may have been a full disk that the
            // user has since cleared; clearing the log is a reasonable moment
            // to try again.
            writeDisabled = false
            lock.unlock()
        }
    }
}
