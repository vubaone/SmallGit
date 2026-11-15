import Foundation

extension String {
    /// Stable, short, filesystem-safe hash for cache key derivation.
    var stableHash: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in self.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    func trimmedLines() -> [String] {
        split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { String($0) }
    }

    /// Lowercase, sanitised representation suitable for filenames.
    /// Path separators, spaces, and reserved characters are replaced with "_".
    /// Truncated to 80 chars to keep paths sane.
    var safeFileName: String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._-"))
        let scalars = self.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(scalars)
        return String(cleaned.prefix(80))
    }
}
