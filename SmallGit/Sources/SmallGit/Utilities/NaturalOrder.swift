import Foundation

extension Character {
    fileprivate var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}

extension String {
    /// Orders strings the way a person reads them: runs of digits compare by
    /// value, everything else compares exactly as it did before.
    ///
    /// Plain string ordering puts "ZSOC-1056" ahead of "ZSOC-153", because it
    /// never gets past the second character. Branch names built around ticket
    /// numbers are the common case in this app, and a list where 153 sits
    /// between 1237 and 306 is one you have to search rather than scan.
    func naturallyPrecedes(_ other: String) -> Bool {
        naturalCompare(other) == .orderedAscending
    }

    func naturalCompare(_ other: String) -> ComparisonResult {
        var a = Substring(self)
        var b = Substring(other)

        while true {
            guard let ca = a.first else {
                return b.isEmpty ? .orderedSame : .orderedAscending
            }
            guard let cb = b.first else { return .orderedDescending }

            guard ca.isASCIIDigit && cb.isASCIIDigit else {
                if ca == cb {
                    a = a.dropFirst()
                    b = b.dropFirst()
                    continue
                }
                return ca < cb ? .orderedAscending : .orderedDescending
            }

            let runA = a.prefix(while: { $0.isASCIIDigit })
            let runB = b.prefix(while: { $0.isASCIIDigit })
            let digitsA = runA.drop(while: { $0 == "0" })
            let digitsB = runB.drop(while: { $0 == "0" })

            // Longer number wins once leading zeros are gone; same length
            // falls back to digit-by-digit, which is the same as by value.
            if digitsA.count != digitsB.count {
                return digitsA.count < digitsB.count ? .orderedAscending : .orderedDescending
            }
            if digitsA != digitsB {
                return digitsA.lexicographicallyPrecedes(digitsB) ? .orderedAscending : .orderedDescending
            }
            // Equal in value: "v01" and "v1" still need a stable order, so the
            // one with fewer leading zeros goes first.
            if runA.count != runB.count {
                return runA.count < runB.count ? .orderedAscending : .orderedDescending
            }

            a = a.dropFirst(runA.count)
            b = b.dropFirst(runB.count)
        }
    }
}
