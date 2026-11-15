import Foundation

/// What kind of work a record describes.
///
/// The split that matters for diagnosis is `network` vs everything else: a
/// slow `git log` is a disk or repository-size problem, a slow `git fetch` is
/// a connectivity problem, and telling them apart after the fact is the whole
/// point of separating them here rather than filing both under "git".
enum LogCategory: String, Codable, Sendable, CaseIterable, Hashable {
    /// git talking to a remote — fetch, push, pull, clone, ls-remote.
    case network
    /// git working entirely on local disk.
    case git
    /// Our own file reads and writes: the disk cache, config, UI state.
    case disk
    /// FSEvents batches. Here because the interesting failure is *rate*, not
    /// duration — a watcher firing continuously at idle is the shape of a
    /// feedback loop, and it shows up nowhere else.
    case watcher
    /// Launch, repo switch, and other landmarks that make a log readable.
    case app

    var label: String {
        switch self {
        case .network: return "Network"
        case .git:     return "Git"
        case .disk:    return "Disk"
        case .watcher: return "Watcher"
        case .app:     return "App"
        }
    }
}

enum LogOutcome: String, Codable, Sendable, Hashable {
    case ok
    case failed
    case timedOut
    case cancelled

    var isFailure: Bool { self != .ok }

    var label: String {
        switch self {
        case .ok:        return "ok"
        case .failed:    return "failed"
        case .timedOut:  return "timed out"
        case .cancelled: return "cancelled"
        }
    }
}

/// One logged operation.
///
/// Deliberately *not* `Identifiable`. Identity would have to be a UUID or a
/// sequence number carried in the file, and both cost bytes in a size-capped
/// log while buying nothing: records are append-only, so their file order is
/// their order, and the viewer indexes them when it reads them.
struct LogRecord: Codable, Sendable, Hashable {
    let at: Date
    let category: LogCategory
    /// Stable name used to group records in the summary — `git fetch`,
    /// `cache.load`, `fsevents.batch`. Must not contain per-call detail, or
    /// every call becomes its own summary row and the aggregate says nothing.
    let operation: String
    /// Per-call context: which repo, which cache key, which path. Free-form
    /// and never grouped on.
    let detail: String
    /// Wall-clock duration in milliseconds. `nil` for events with no span,
    /// such as an FSEvents batch arriving.
    let ms: Double?
    /// Bytes read or written, where the operation moves a measurable amount.
    let bytes: Int?
    let outcome: LogOutcome
    /// Error text, or any note worth keeping. Trimmed hard — a log that
    /// stores whole stderr dumps rotates away the history you wanted.
    let message: String?

    init(
        at: Date = Date(),
        category: LogCategory,
        operation: String,
        detail: String = "",
        ms: Double? = nil,
        bytes: Int? = nil,
        outcome: LogOutcome = .ok,
        message: String? = nil
    ) {
        self.at = at
        self.category = category
        self.operation = operation
        self.detail = detail
        self.ms = ms
        self.bytes = bytes
        self.outcome = outcome
        self.message = message
    }

    /// Short keys, but still words. A single-letter scheme would fit perhaps
    /// 15% more records into the same 5 MB; being able to read the raw file in
    /// any text editor — or pipe it through `jq` — is worth more than that.
    enum CodingKeys: String, CodingKey {
        case at
        case category = "cat"
        case operation = "op"
        case detail
        case ms
        case bytes
        case outcome = "result"
        case message = "msg"
    }
}

// MARK: - JSON Lines

/// One JSON object per line.
///
/// Chosen over a single JSON array because the log is written by appending and
/// read after crashes: an array would have to be rewritten whole on every
/// flush, and a process killed mid-write would leave a file no parser accepts.
/// With JSON Lines a torn write costs exactly the last line.
enum LogCodec {

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // No pretty-printing and no sorted keys: a newline is the record
        // separator here, so an encoder that emits them mid-record would
        // corrupt the format outright.
        encoder.outputFormatting = []
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Encodes `records` as newline-terminated JSON, skipping any that fail to
    /// encode rather than losing the whole batch with them.
    static func encode(_ records: [LogRecord]) -> Data {
        var out = Data()
        for record in records {
            guard var line = try? encoder.encode(record) else { continue }
            line.append(0x0A)
            out.append(line)
        }
        return out
    }

    /// Decodes whatever the file holds, ignoring lines that don't parse.
    ///
    /// Tolerance is the point: the first line of a rotated-into file can be a
    /// fragment, the last line of a killed process can be half-written, and
    /// neither should cost the user the rest of their log.
    static func decode(_ data: Data) -> [LogRecord] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(LogRecord.self, from: Data($0))
        }
    }
}
