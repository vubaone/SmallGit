import SwiftUI
import AppKit

// MARK: - Dynamic palette

/// The app's colours, as `NSColor`s that resolve themselves against
/// whichever appearance they are drawn in.
///
/// Every entry carries both a light and a dark value, so the ~500
/// `Color.bgPanel`-style call sites throughout the app never have to know
/// which theme is active — the same token draws correctly in both. That is
/// the whole reason these are `NSColor(name:dynamicProvider:)` rather than
/// values picked by a `ColorScheme` read at the call site: retro-fitting a
/// theme argument onto 500 call sites would have been a change with 500
/// chances to miss one.
///
/// `Color` mirrors of every entry live in the extension below; use those from
/// SwiftUI. Reach for `Palette` directly only where AppKit needs a real
/// `NSColor` (the compare panes' `NSTextView`), and pass the dynamic colour
/// rather than a resolved one so AppKit re-resolves it on an appearance flip.
enum Palette {
    // Surfaces. In dark the stack gets *lighter* as it comes forward
    // (app → panel → header); in light it gets *darker*, with panels white
    // so file lists and diffs read as paper.
    static let bgApp         = themed("bgApp",         light: 0xF2F2F4, dark: 0x1E1E1E)
    static let bgPanel       = themed("bgPanel",       light: 0xFFFFFF, dark: 0x252526)
    static let bgPanelHeader = themed("bgPanelHeader", light: 0xEDEDF0, dark: 0x2D2D30)
    static let bgInput       = themed("bgInput",       light: 0xF3F3F6, dark: 0x3C3C3C)
    /// Row selection. Saturated in both themes rather than a pale wash in
    /// light, because selected rows draw their text in white.
    static let bgSelected    = themed("bgSelected",    light: 0x0B62C4, dark: 0x094771)
    static let bgHover       = themed("bgHover",       light: 0xE8E8ED, dark: 0x2A2D2E)

    static let borderColor   = themed("borderColor",   light: 0xDCDCE1, dark: 0x3E3E42)
    /// Brighter rule for places where a divider needs to read as a
    /// real boundary — between resolver panes, between the chunk
    /// list and its detail column, etc. `borderColor` is too faint
    /// against `bgPanel` to register at a glance.
    static let strongBorder  = themed("strongBorder",  light: 0xB4B4BC, dark: 0x646468)

    static let textPrimary   = themed("textPrimary",   light: 0x1E1E20, dark: 0xCCCCCC)
    static let textSecondary = themed("textSecondary", light: 0x6A6A70, dark: 0x808080)
    static let textDisabled  = themed("textDisabled",  light: 0xA8A8AF, dark: 0x5A5A5A)

    /// Sidebar group headers ("Mobile Apps", "Other"). Deliberately a cool
    /// slate rather than a stronger grey: the header is set in bold, and
    /// bold plus contrast would make the *folders* louder than the
    /// repositories inside them. Keeping it at roughly `textSecondary`'s
    /// weight and separating it by hue instead lets the eye pick out the
    /// grouping without the group names winning the panel.
    static let textGroupHeader = themed("textGroupHeader", light: 0x4C5766, dark: 0x7B8598)

    static let accentBlue    = themed("accentBlue",    light: 0x0A66C2, dark: 0x007ACC)

    // Diff row washes and their text. Light keeps the wash pale so black
    // code stays readable on top; dark keeps it deep for the same reason
    // in reverse.
    static let diffAddBg     = themed("diffAddBg",     light: 0xE4F7E7, dark: 0x1E3A1E)
    static let diffDelBg     = themed("diffDelBg",     light: 0xFDE7E9, dark: 0x3A1E1E)
    static let diffAddText   = themed("diffAddText",   light: 0x1B7A32, dark: 0xB5F5A0)
    static let diffDelText   = themed("diffDelText",   light: 0xB3261E, dark: 0xF4A8A8)

    /// Backgrounds for the *characters* that changed within a line, as
    /// opposed to `diffAddBg` / `diffDelBg` which wash the whole row.
    ///
    /// Each theme pushes these away from its own text colour rather than
    /// toward it: dark patches under light text, light patches under dark
    /// text. The alternative — a patch close in luminance to the text —
    /// forces the foreground to a single flat colour to stay legible, and
    /// that kills syntax highlighting exactly where the reader is looking
    /// hardest.
    static let diffAddWordBg = themed("diffAddWordBg", light: 0xAEE6B8, dark: 0x295C32)
    static let diffDelWordBg = themed("diffDelWordBg", light: 0xF7B9BE, dark: 0x6F292E)

    /// The "no line on this side" filler in a side-by-side diff. A wash
    /// rather than an opaque colour so it reads as absence in both themes.
    static let diffEmptyBg   = themed("diffEmptyBg",   light: 0x000000, lightAlpha: 0.05,
                                                    dark:  0x000000, darkAlpha: 0.15)

    /// Stripes of the hatching drawn over `diffEmptyBg`. Strong enough to
    /// read as a deliberate pattern from across the screen, light enough
    /// that a hundred-line gap is not a wall of lines.
    static let diffAbsentHatch = themed("diffAbsentHatch",
                                        light: 0x9BA0A8, lightAlpha: 0.55,
                                        dark:  0xA8AEB8, darkAlpha: 0.28)

    /// Find-bar hits. Amber rather than a blue or green, because both of
    /// those already mean something here — blue is selection and the active
    /// repository, green is an addition — and a search hit has to be findable
    /// on top of a red or green diff row without being mistaken for one.
    /// Light in both themes: the text drawn on top of a hit is forced black.
    static let searchMatchBg   = themed("searchMatchBg",   light: 0xFFE9A3, dark: 0x7A5A10)
    static let searchCurrentBg = themed("searchCurrentBg", light: 0xFFC53D, dark: 0xD49C1B)

    /// Soft pink wash for conflict regions in the resolver's read-only
    /// panes. Two shades — dim for non-focused chunks, brighter for
    /// the one the user is currently working on — mirror Beyond
    /// Compare's "current vs. other conflicts" visual cue.
    static let conflictHighlight = themed("conflictHighlight",
                                       light: 0xF26673, lightAlpha: 0.20,
                                       dark:  0xF26673, darkAlpha: 0.18)
    static let conflictHighlightFocused = themed("conflictHighlightFocused",
                                              light: 0xF26673, lightAlpha: 0.42,
                                              dark:  0xF26673, darkAlpha: 0.38)

    /// Gutter accent for a compare line that has been retyped but not saved.
    /// Amber, like a search hit and for the same reason: red and green are
    /// spoken for by the diff, and this line's point is that it is *not* what
    /// the diff beside it describes.
    static let editedLineAccent = themed("editedLineAccent", light: 0xD08B00, dark: 0xE0A83C)

    /// Wash behind text a drag has selected in a compare pane. The system's
    /// own selection colour rather than one of ours: a selection that does
    /// not look like every other selection on the machine reads as a
    /// highlight, and the panes already use highlights to mean other things.
    static let textSelectionBg = NSColor.selectedTextBackgroundColor

    /// Revealed whitespace — the middle dots, tab arrows and pilcrows shown
    /// when "Show Whitespace" is on. Sits between `textDisabled` and
    /// `textSecondary`: findable when you go looking for a stray space,
    /// quiet enough that a whole indented file doesn't turn into dots.
    static let whitespaceGlyph = themed("whitespaceGlyph", light: 0x9AA2AE, dark: 0x5F6670)

    /// Ring drawn around a commit dot in the graph so it stays distinct from
    /// the lane line running under it — which means contrasting with the
    /// *lane colours*, not with the background, hence white on light.
    static let graphDotRing  = themed("graphDotRing",  light: 0xFFFFFF, lightAlpha: 0.9,
                                                    dark:  0x000000, darkAlpha: 0.7)

    /// Builds one two-valued colour. The name only shows up in AppKit
    /// debugging output, but a named colour is far easier to identify there
    /// than an anonymous one. Internal rather than private so views that own
    /// a specialised palette — the commit graph's lane colours — can declare
    /// theirs the same way.
    static func themed(
        _ name: String,
        light: UInt32,
        lightAlpha: CGFloat = 1,
        dark: UInt32,
        darkAlpha: CGFloat = 1
    ) -> NSColor {
        NSColor(name: NSColor.Name("sg.\(name)")) { appearance in
            appearance.isDark
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        }
    }

    /// Same thing from two colours already in hand, which is what a user's
    /// picked colour arrives as. Keeps a customised colour two-valued, so it
    /// still follows a Light/Dark switch like every other entry here.
    static func pair(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name("sg.\(name)")) { appearance in
            appearance.isDark ? dark : light
        }
    }
}

extension NSAppearance {
    /// Whether this appearance is one of the dark ones. `bestMatch` rather
    /// than comparing `name` directly so the vibrant and high-contrast
    /// variants — which a user can turn on in System Settings — are still
    /// recognised as dark.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension NSColor {
    /// 0xRRGGBB in sRGB. Every palette value is written as hex because
    /// that is the form they get compared against in a design tool.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >> 8)  & 0xFF) / 255,
            blue:    CGFloat( hex        & 0xFF) / 255,
            alpha:   alpha
        )
    }
}

/// SwiftUI mirrors of `Palette`. These keep the call-site spelling the app
/// has always used (`Color.textSecondary`), so switching the app from a
/// hard-coded dark theme to a themed one changed none of them.
extension Color {
    static let bgApp          = Color(nsColor: Palette.bgApp)
    static let bgPanel        = Color(nsColor: Palette.bgPanel)
    static let bgPanelHeader  = Color(nsColor: Palette.bgPanelHeader)
    static let bgInput        = Color(nsColor: Palette.bgInput)
    static let bgSelected     = Color(nsColor: Palette.bgSelected)
    static let bgHover        = Color(nsColor: Palette.bgHover)

    static let borderColor    = Color(nsColor: Palette.borderColor)
    static let strongBorder   = Color(nsColor: Palette.strongBorder)

    static let textPrimary    = Color(nsColor: Palette.textPrimary)
    static let textSecondary  = Color(nsColor: Palette.textSecondary)
    static let textDisabled   = Color(nsColor: Palette.textDisabled)
    static let textGroupHeader = Color(nsColor: Palette.textGroupHeader)

    static let accentBlue     = Color(nsColor: Palette.accentBlue)

    // The nine Settings › Colors can change. Computed rather than `static
    // let` so they are read at draw time from `DiffPalette`: a view body that
    // paints a diff row registers a dependency on that store, and a colour
    // picked in Settings repaints what is behind it rather than waiting for a
    // relaunch. Every other entry here is fixed at launch and stays a `let`.
    @MainActor static var diffAddBg: Color     { DiffPalette.shared.color(.addedLine) }
    @MainActor static var diffDelBg: Color     { DiffPalette.shared.color(.removedLine) }
    @MainActor static var diffAddText: Color   { DiffPalette.shared.color(.addedText) }
    @MainActor static var diffDelText: Color   { DiffPalette.shared.color(.removedText) }
    @MainActor static var diffAddWordBg: Color { DiffPalette.shared.color(.addedWord) }
    @MainActor static var diffDelWordBg: Color { DiffPalette.shared.color(.removedWord) }
    @MainActor static var diffEmptyBg: Color   { DiffPalette.shared.color(.missingLine) }
    static let diffAbsentHatch = Color(nsColor: Palette.diffAbsentHatch)

    static let searchMatchBg        = Color(nsColor: Palette.searchMatchBg)
    static let searchCurrentBg      = Color(nsColor: Palette.searchCurrentBg)

    @MainActor static var conflictHighlight: Color        { DiffPalette.shared.color(.conflict) }
    @MainActor static var conflictHighlightFocused: Color { DiffPalette.shared.color(.conflictFocused) }

    static let graphDotRing   = Color(nsColor: Palette.graphDotRing)
    static let textSelectionBg = Color(nsColor: Palette.textSelectionBg)
    static let whitespaceGlyph = Color(nsColor: Palette.whitespaceGlyph)
    static let editedLineAccent = Color(nsColor: Palette.editedLineAccent)
}

// MARK: - Appearance setting

extension AppearanceMode {
    /// What SwiftUI should force on a window's content. `nil` for `.system`,
    /// which is how SwiftUI spells "inherit whatever the OS is doing".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// Pushes the choice onto `NSApp`, which is what themes the parts of the
    /// app SwiftUI does not own: the titlebar, toolbar, menus, scrollers,
    /// open/save panels and every sheet. The `preferredColorScheme` on each
    /// window root covers the SwiftUI side; both are set so the two halves of
    /// a window can never disagree.
    @MainActor
    func applyToApp() {
        NSApp?.appearance = nsAppearance
    }
}

// MARK: - Syntax colours

extension SyntaxTokenKind {
    /// Foreground colour for a run of source text in the compare views.
    ///
    /// Tuned against the diff backgrounds rather than against a plain editor
    /// background, since every one of these is read on top of `diffAddBg`,
    /// `diffDelBg` or a word-level patch at some point. That rules out the
    /// extremes of a typical editor theme — a comment green that is
    /// comfortable on `#1e1e1e` disappears against a deleted line.
    ///
    /// Deliberately restrained overall: red and green already mean something
    /// specific here, so syntax colour has to give the eye structure without
    /// competing with the diff itself for attention.
    var nsColor: NSColor {
        switch self {
        case .keyword:   return Palette.synKeyword
        case .type:      return Palette.synType
        case .string:    return Palette.synString
        case .number:    return Palette.synNumber
        case .comment:   return Palette.synComment
        case .directive: return Palette.synDirective
        case .function:  return Palette.synFunction
        case .plain:     return Palette.textPrimary
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

extension Palette {
    // Light values follow the widely-recognised "Light+" editor scheme;
    // dark values are the app's original palette.
    static let synKeyword   = themed("synKeyword",   light: 0x0000CC, dark: 0x569CD6)
    static let synType      = themed("synType",      light: 0x267F99, dark: 0x4EC9B0)
    static let synString    = themed("synString",    light: 0xA31515, dark: 0xCE9178)
    static let synNumber    = themed("synNumber",    light: 0x0F7B3E, dark: 0xB5CEA8)
    static let synComment   = themed("synComment",   light: 0x2F6B2F, dark: 0x80AD6B)
    static let synDirective = themed("synDirective", light: 0x9B00C4, dark: 0xC586C0)
    static let synFunction  = themed("synFunction",  light: 0x795E26, dark: 0xDCDCAA)
}

extension Font {
    /// 12pt monospaced — used in diffs, file lists, output panel.
    /// For zoomable contexts prefer `Font.mono(size:)` with the size
    /// pulled from `@Environment(\.monoFontSize)`.
    static let codeMono = Font.system(size: 12, design: .monospaced)
    /// 11pt panel header label.
    static let panelHeader = Font.system(size: 11, weight: .medium)
    /// 11pt status-bar text.
    static let statusBar = Font.system(size: 11)

    /// Monospaced font at a runtime-controlled size. Use from views that
    /// read `@Environment(\.monoFontSize)`.
    static func mono(size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }
}

// MARK: - Zoomable font sizes

/// Environment-propagated monospace size in points. Drives the diff
/// view's line text + gutters. Default 12pt matches `Font.codeMono`.
private struct MonoFontSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 12
}

/// Environment-propagated UI scale multiplier. Bumped by ⌘= / ⌘- /
/// ⌘0 so every text element in the app grows in lockstep with the
/// diff font. Default 1.0 corresponds to monoFontSize == 12.
private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

/// Whether diff and compare views draw spaces, tabs and line ends as
/// glyphs. Environment-propagated for the same reason the zoom level is:
/// the rows that need it are three view layers below the window root, and
/// threading a Bool through every intermediate view would touch a dozen
/// initialisers to say one thing.
private struct ShowWhitespaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var monoFontSize: CGFloat {
        get { self[MonoFontSizeKey.self] }
        set { self[MonoFontSizeKey.self] = newValue }
    }
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
    var showWhitespace: Bool {
        get { self[ShowWhitespaceKey.self] }
        set { self[ShowWhitespaceKey.self] = newValue }
    }
}

/// Applies the app's current zoom level to a window's content.
///
/// A wrapper view rather than an `.environment(…)` call written at the call
/// site, and that distinction is the whole point. A modifier's argument is
/// evaluated once, where it is written; the compare windows build their root
/// view into an `NSHostingView` that is never rebuilt, so a value read there
/// is frozen at whatever the zoom was when the window opened. ⌘= would move
/// the main window and leave every compare window behind.
///
/// Reading `appState` inside a `body` registers an observation dependency
/// instead, so the environment follows the setting in every window that uses
/// this.
struct AppZoom<Content: View>: View {
    @Bindable var appState: AppState
    @ViewBuilder var content: Content

    var body: some View {
        content
            .environment(\.monoFontSize, appState.appConfig.monoFontSize)
            .environment(\.uiScale, appState.appConfig.monoFontSize / 12)
            .environment(\.showWhitespace, appState.appConfig.showWhitespace)
            .background {
                // ⌘+ as well as the menu's ⌘=. On a US layout ⌘+ is physically
                // ⇧⌘=, which a `⌘=` key equivalent does not match — so the
                // shortcut most people actually reach for did nothing at all.
                //
                // Only the `+` variant lives here: ⌘= / ⌘- / ⌘0 are already on
                // the View menu and fire app-wide, and a second handler for
                // them would apply each press twice.
                Button("") { appState.bumpMonoFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
    }
}

/// Line-height heuristic for a monospace row at `fontSize`. A 1.5×
/// multiplier keeps comfortable spacing across the supported zoom
/// range (8..28pt).
func monoRowHeight(for fontSize: CGFloat) -> CGFloat {
    ceil(fontSize * 1.5)
}

// MARK: - Scaled font modifier

/// Applies a system font sized at `baseSize * uiScale` from the
/// environment. Use anywhere `.font(.system(size: N, ...))` would
/// have gone — that way ⌘= / ⌘- / ⌘0 scales the whole app, not just
/// the diff text.
struct ScaledFont: ViewModifier {
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.uiScale) private var scale

    func body(content: Content) -> some View {
        content.font(.system(size: baseSize * scale, weight: weight, design: design))
    }
}

extension View {
    /// Drop-in for `.font(.system(size: N, weight: .x, design: .y))`
    /// that scales with the app's ⌘+/- zoom level.
    func scaledFont(
        _ baseSize: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(ScaledFont(baseSize: baseSize, weight: weight, design: design))
    }
}

extension GitFileState {
    /// Color coding for the state column / dot.
    var swatch: Color {
        switch self {
        case .modified:   return .blue
        case .added:      return .green
        case .deleted:    return .red
        case .renamed:    return .cyan
        case .copied:     return .cyan
        case .untracked:  return .gray
        case .ignored:    return .secondary
        case .conflict:   return .orange
        case .typeChange: return .purple
        case .unmodified: return .secondary
        }
    }
}

extension GitFileStatus {
    /// Swatch color for the State column / dot, factoring in stage
    /// state. Staged files render green (SmartGit convention) so the
    /// user can see at a glance what's already in the index; a file
    /// that has been staged *and* re-edited shows orange to flag that
    /// the index and worktree disagree.
    var displaySwatch: Color {
        if isConflict { return .orange }
        if state == .untracked { return state.swatch }
        // An assume-unchanged file gets its own colour rather than the
        // grey every other unchanged row wears: when the flag view is on
        // it is the only thing distinguishing these rows from the ones
        // the filter pulls in, and indigo is unused elsewhere here.
        if isAssumeUnchanged, state == .unmodified { return .indigo }
        switch (isStaged, isUnstaged) {
        case (true, true):  return .orange
        case (true, false): return .green
        default:            return state.swatch
        }
    }
}
