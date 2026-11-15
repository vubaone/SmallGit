import SwiftUI
import AppKit

/// The colours Settings › Colors lets the user change: the states a compare
/// view paints, plus the two conflict washes.
///
/// A closed list rather than "every colour in the app". These are the ones
/// people actually want to change — colour-blind readers who need the
/// add/remove pair to differ by more than red vs. green, and anyone matching
/// SmallGit to the editor sitting next to it — and each has a `Palette` entry
/// that is already the single place its colour comes from.
enum DiffColorRole: String, CaseIterable, Sendable {
    case addedLine
    case removedLine
    case addedWord
    case removedWord
    case addedText
    case removedText
    case missingLine
    case conflict
    case conflictFocused

    var title: String {
        switch self {
        case .addedLine:       return "Added line"
        case .removedLine:     return "Removed line"
        case .addedWord:       return "Added characters"
        case .removedWord:     return "Removed characters"
        case .addedText:       return "Added line text"
        case .removedText:     return "Removed line text"
        case .missingLine:     return "Missing line"
        case .conflict:        return "Conflict"
        case .conflictFocused: return "Conflict being resolved"
        }
    }

    var caption: String {
        switch self {
        case .addedLine, .removedLine:
            return "The wash behind a whole changed row."
        case .addedWord, .removedWord:
            return "The patch behind the characters that changed within a row."
        case .addedText, .removedText:
            return "Also used for the +/- counts and other added/removed labels."
        case .missingLine:
            return "The filler where a side-by-side compare has no line on this side."
        case .conflict:
            return "Conflict regions in the resolver's panes."
        case .conflictFocused:
            return "The one conflict you are currently working on."
        }
    }

    /// The theme's own value, which an unset role falls back to and which
    /// Restore Defaults returns to.
    var defaultColor: NSColor {
        switch self {
        case .addedLine:       return Palette.diffAddBg
        case .removedLine:     return Palette.diffDelBg
        case .addedWord:       return Palette.diffAddWordBg
        case .removedWord:     return Palette.diffDelWordBg
        case .addedText:       return Palette.diffAddText
        case .removedText:     return Palette.diffDelText
        case .missingLine:     return Palette.diffEmptyBg
        case .conflict:        return Palette.conflictHighlight
        case .conflictFocused: return Palette.conflictHighlightFocused
        }
    }
}

/// Where the overridable colours are read from.
///
/// `Observable`, and read through computed `Color` properties rather than the
/// `static let`s the rest of the palette uses, so that a SwiftUI body which
/// draws a diff row registers a dependency on this store: picking a colour in
/// Settings repaints the diff behind it instead of waiting for a relaunch.
@MainActor
@Observable
final class DiffPalette {
    static let shared = DiffPalette()

    /// Only the roles the user has actually changed. Everything else falls
    /// through to `role.defaultColor`, so the defaults stay in one place.
    private var overrides: [DiffColorRole: Color] = [:]

    func color(_ role: DiffColorRole) -> Color {
        overrides[role] ?? Color(nsColor: role.defaultColor)
    }

    /// The colour a role draws in one specific appearance, flattened to a
    /// plain value — what a colour well has to show, since it cannot display
    /// something that means two things at once.
    func resolvedColor(_ role: DiffColorRole, dark: Bool) -> Color {
        Color(nsColor: nsColor(role).resolved(in: .theme(dark: dark)))
    }

    private func nsColor(_ role: DiffColorRole) -> NSColor {
        guard let override = overrides[role] else { return role.defaultColor }
        return NSColor(override)
    }

    /// Rebuild every override from what was loaded or just edited.
    func apply(_ stored: DiffColorOverrides) {
        var next: [DiffColorRole: Color] = [:]
        for role in DiffColorRole.allCases {
            let light = stored.value(role.rawValue, dark: false).flatMap(NSColor.init(hexString:))
            let dark  = stored.value(role.rawValue, dark: true).flatMap(NSColor.init(hexString:))
            guard light != nil || dark != nil else { continue }
            // The half the user has not set keeps the theme's own value, so
            // customising dark leaves light exactly as it was.
            let fallback = role.defaultColor
            let lightValue = light ?? fallback.resolved(in: .theme(dark: false))
            let darkValue  = dark  ?? fallback.resolved(in: .theme(dark: true))
            next[role] = Color(nsColor: Palette.pair(
                "override.\(role.rawValue)", light: lightValue, dark: darkValue
            ))
        }
        overrides = next
    }
}

extension NSAppearance {
    /// The appearance of one theme, for resolving a two-valued colour against
    /// a theme other than the one currently drawing.
    static func theme(dark: Bool) -> NSAppearance {
        NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    }
}

extension NSColor {
    /// This colour as it draws in `appearance`: a plain value with no
    /// remaining light/dark behaviour.
    func resolved(in appearance: NSAppearance) -> NSColor {
        var out = self
        appearance.performAsCurrentDrawingAppearance {
            out = self.usingColorSpace(.sRGB) ?? self
        }
        return out
    }

    /// `#RRGGBBAA` in sRGB — how a picked colour is written to the config
    /// file, alpha included because several of these roles are washes and
    /// their transparency is the point.
    var hexStringRGBA: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        let byte = { (v: CGFloat) in UInt8(max(0, min(255, (v * 255).rounded()))) }
        return String(
            format: "#%02X%02X%02X%02X",
            byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent), byte(c.alphaComponent)
        )
    }

    /// Reads `#RRGGBB` and `#RRGGBBAA`, with or without the `#`. Anything
    /// else is nil, which the caller reads as "not overridden" — a hand-edited
    /// config file should not be able to make a colour undrawable.
    convenience init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8,
              let value = UInt32(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(hex: rgb, alpha: alpha)
    }
}
