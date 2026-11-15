import Foundation

/// Typed wrapper around any cached value with provenance metadata.
struct CacheEntry<T: Codable & Sendable>: Codable, Sendable {
    let value: T
    let timestamp: Date
    let gitRef: String?

    init(value: T, timestamp: Date = Date(), gitRef: String? = nil) {
        self.value = value
        self.timestamp = timestamp
        self.gitRef = gitRef
    }

    var age: TimeInterval {
        Date().timeIntervalSince(timestamp)
    }
}
