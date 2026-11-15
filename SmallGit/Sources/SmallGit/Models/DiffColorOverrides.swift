import Foundation

/// The compare and conflict colours a user has picked for themselves, as
/// `#RRGGBBAA` strings keyed by role name.
///
/// Kept per appearance because the two themes need genuinely different values:
/// the pale green that keeps black code readable on white is invisible against
/// a dark editor, and a green picked for dark is a highlighter pen on white.
/// Storing one colour for both would mean customising one theme quietly
/// wrecked the other. An absent entry means "use the theme's own colour", so a
/// config from before this existed — and a reset — are the same thing.
///
/// Role names are stored as raw strings rather than an enum so that renaming
/// or dropping a role later reads as "not overridden" instead of failing the
/// whole config file to decode.
struct DiffColorOverrides: Codable, Sendable, Equatable {
    var light: [String: String] = [:]
    var dark: [String: String] = [:]

    var isEmpty: Bool { light.isEmpty && dark.isEmpty }

    func value(_ role: String, dark isDark: Bool) -> String? {
        isDark ? dark[role] : light[role]
    }

    /// A nil `hex` removes the override, which is how one row resets.
    mutating func set(_ hex: String?, for role: String, dark isDark: Bool) {
        if isDark {
            dark[role] = hex
        } else {
            light[role] = hex
        }
    }

    mutating func removeAll() {
        light.removeAll()
        dark.removeAll()
    }
}
