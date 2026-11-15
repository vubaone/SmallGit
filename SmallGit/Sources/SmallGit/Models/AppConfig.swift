import Foundation
import CoreGraphics

/// Release metadata source. Run ./make_version.sh after changing either
/// constant. Runtime UI reads the built bundle's version, not these values.
enum AppVersion {
    static let clientVersionString = "26.11.01"
    static let clientVersionInt = 261101
}

/// Which application handles "Compare" (2-way diff for changed files) and
/// "Resolve" (3-way merge for conflicts). `.builtin` uses SmallGit's own
/// 2-pane diff view and 4-pane conflict resolver. Presets shell out to the
/// matching app via its bundled CLI helper; `.custom` lets the user point
/// at any app with their own argument template.
enum ExternalDiffTool: String, Codable, CaseIterable, Sendable {
    case builtin
    case beyondCompare
    case kaleidoscope
    case fileMerge
    case custom

    var displayName: String {
        switch self {
        case .builtin:       return "Built-in (4-pane)"
        case .beyondCompare: return "Beyond Compare"
        case .kaleidoscope:  return "Kaleidoscope"
        case .fileMerge:     return "FileMerge"
        case .custom:        return "Custom…"
        }
    }

    /// Candidate filesystem paths for the tool's blocking CLI helper. Probed
    /// in order; the first existing path wins. Empty for `.builtin`/`.custom`.
    var presetBinaryCandidates: [String] {
        switch self {
        case .beyondCompare:
            return [
                "/usr/local/bin/bcomp",
                "/opt/homebrew/bin/bcomp",
                "/Applications/Beyond Compare.app/Contents/MacOS/bcomp"
            ]
        case .kaleidoscope:
            return [
                "/usr/local/bin/ksdiff",
                "/opt/homebrew/bin/ksdiff"
            ]
        case .fileMerge:
            return ["/usr/bin/opendiff"]
        default:
            return []
        }
    }

    /// `Process` argv for 2-way diff. `${leftFile}` is HEAD content,
    /// `${rightFile}` is the working-tree path.
    var presetDiffArgsTemplate: String {
        switch self {
        case .beyondCompare, .kaleidoscope, .fileMerge:
            return "${leftFile} ${rightFile}"
        default:
            return ""
        }
    }

    /// `Process` argv for 3-way merge. Empty when the preset doesn't have
    /// a clean merge invocation (we fall back to the built-in resolver).
    var presetMergeArgsTemplate: String {
        switch self {
        case .beyondCompare:
            // bcomp <left> <right> <ancestor> <output>
            return "${leftFile} ${rightFile} ${baseFile} ${mergedFile}"
        case .fileMerge:
            return "${leftFile} ${rightFile} -ancestor ${baseFile} -merge ${mergedFile}"
        case .kaleidoscope, .builtin, .custom:
            return ""
        }
    }
}

/// Which appearance the app draws in. `.system` follows the OS setting
/// (including a scheduled or automatic Light/Dark switch); the other two
/// pin the app regardless of what the rest of the Mac is doing — which is
/// what people who keep one app light and everything else dark are after.
enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }
}

enum ExternalEditor: String, Codable, CaseIterable, Sendable {
    case system        // open with the OS default for the file/folder
    case zed
    case vscode
    case cursor
    case windsurf
    case sublime
    case nova
    case bbedit
    case textmate
    case intellij
    case androidStudio
    case xcode
    /// Any app the user picked — `AppConfig.customEditorPath`.
    case custom

    var displayName: String {
        switch self {
        case .system:        return "System Default"
        case .zed:           return "Zed"
        case .vscode:        return "Visual Studio Code"
        case .cursor:        return "Cursor"
        case .windsurf:      return "Windsurf"
        case .sublime:       return "Sublime Text"
        case .nova:          return "Nova"
        case .bbedit:        return "BBEdit"
        case .textmate:      return "TextMate"
        case .intellij:      return "IntelliJ IDEA"
        case .androidStudio: return "Android Studio"
        case .xcode:         return "Xcode"
        case .custom:        return "Other App…"
        }
    }

    /// Bundle identifiers to try when launching, in preference order. The
    /// first one currently installed on the user's machine wins.
    var bundleIDs: [String] {
        switch self {
        case .system, .custom: return []
        case .zed:           return ["dev.zed.Zed", "dev.zed.Zed-Preview"]
        case .vscode:        return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .cursor:        return ["com.todesktop.230313mzl4w4u92"]
        case .windsurf:      return ["com.exafunction.windsurf"]
        case .sublime:       return ["com.sublimetext.4", "com.sublimetext.3"]
        case .nova:          return ["com.panic.Nova"]
        case .bbedit:        return ["com.barebones.bbedit"]
        case .textmate:      return ["com.macromates.TextMate"]
        case .intellij:      return ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]
        case .androidStudio: return ["com.google.android.studio"]
        case .xcode:         return ["com.apple.dt.Xcode"]
        }
    }

    /// Editors that open a folder as a project, in the order System Default
    /// tries them for one. macOS's own default for a folder is Finder, which
    /// made "Open in Editor" on a repository do the same as Reveal in Finder.
    static let folderEditors: [ExternalEditor] = [
        .zed, .vscode, .cursor, .windsurf, .sublime, .nova, .bbedit, .textmate
    ]

    /// Bundle identifiers to try for `path`, before the OS default opener.
    /// Only System Default depends on what is being opened: a file goes to
    /// the app macOS assigns it, a folder to the first installed editor.
    func candidateBundleIDs(isDirectory: Bool) -> [String] {
        guard self == .system else { return bundleIDs }
        return isDirectory ? Self.folderEditors.flatMap(\.bundleIDs) : []
    }
}

struct AppConfig: Codable, Sendable {
    var fontSize: CGFloat
    var monoFontSize: CGFloat
    var diffMode: DiffMode
    /// Default for the diff panel's Compact toggle — hides unchanged
    /// context so only the differences show. Orthogonal to `diffMode`.
    var diffCompactMode: Bool
    var ignoreWhitespace: Bool
    var gitPath: String?
    var syncedFromSmartGit: Bool
    var smartGitConfigPath: String?
    var externalEditor: ExternalEditor
    /// Only consulted when `externalEditor == .custom`: the `.app` the
    /// user picked.
    var customEditorPath: String?
    var externalDiffTool: ExternalDiffTool
    /// Only consulted when `externalDiffTool == .custom`. Path to the
    /// binary or `.app` bundle the user picked.
    var customDiffToolPath: String?
    /// Custom argv template for 2-way diff. Placeholders: `${leftFile}`,
    /// `${rightFile}`.
    var customDiffArgs: String
    /// Custom argv template for 3-way merge. Placeholders: `${leftFile}`,
    /// `${rightFile}`, `${baseFile}`, `${mergedFile}`. Empty means
    /// "fall back to built-in resolver for conflicts".
    var customMergeArgs: String
    var lastOpenedRepoID: UUID?
    /// When true, toolbar buttons show their text label under the icon
    /// (SmartGit-style). When false, icon-only — the .help() tooltips
    /// still work on hover. Default: true.
    var toolbarShowsLabels: Bool
    /// Optional keyboard behavior for users who want Escape to close
    /// the active sheet/secondary window, while never closing MainWindow.
    var escapeClosesSubwindows: Bool
    /// When true, closing the main window's red button quits SmallGit rather
    /// than leaving it running window-less in the Dock. Default: true — for a
    /// single-window app the macOS convention mostly just confuses people.
    var quitsOnMainWindowClose: Bool
    /// When true, one click on a repository in the sidebar opens it. When
    /// false a click only selects, and opening takes a double-click — the way
    /// SmartGit behaves, and the safer reading of a click in a long list,
    /// where a mis-aimed one otherwise moves the whole app onto another
    /// repository. Default: true, which is how SmallGit has always behaved.
    var singleClickOpensRepo: Bool
    /// Full commit messages the user has committed through SmallGit,
    /// most-recent first, capped at 10. Powers the "Recent Messages"
    /// reuse menu in the commit dialog.
    var recentCommitMessages: [String]
    /// Draws the performance badge in the status bar: this process's CPU and
    /// memory, its disk I/O, and the machine's network I/O, refreshed once a
    /// second. Off by default — it is a debugging tool, and nothing samples
    /// anything while it is off.
    var perfBadgeEnabled: Bool
    /// Records git, network, disk and file-watcher activity to
    /// `~/Library/Logs/SmallGit/`, readable from Settings › Diagnostics.
    ///
    /// On by default. The cost is a buffered write roughly once a second, and
    /// a log that only starts recording after you have already hit the problem
    /// is a log that never catches the intermittent ones.
    var diagnosticsLoggingEnabled: Bool
    /// Draws spaces, tabs and line ends as glyphs in the diff and compare
    /// views, the way Beyond Compare's "Show Whitespace" does. Off by
    /// default — it answers a question you only sometimes have.
    var showWhitespace: Bool
    /// Light / dark / follow-the-system. Applied to `NSApp` at launch and
    /// whenever it changes, so AppKit chrome (titlebar, menus, panels) and
    /// the SwiftUI content stay in step.
    var appearance: AppearanceMode
    /// Which pull the toolbar's Pull button performs when clicked without
    /// opening its menu — the last one the user picked from that menu.
    /// Whether you rebase or merge on pull is a per-person habit, not a
    /// per-click decision, so asking every time is asking a question the
    /// user already answered.
    var pullUsesRebase: Bool
    /// Compare and conflict colours the user has picked for themselves, per
    /// appearance. Empty — the default — means every one of them comes from
    /// the theme, which is also what Restore Defaults puts back.
    var diffColors: DiffColorOverrides

    init(
        fontSize: CGFloat = 13,
        monoFontSize: CGFloat = 12,
        diffMode: DiffMode = .sideBySide,
        diffCompactMode: Bool = true,
        ignoreWhitespace: Bool = false,
        gitPath: String? = nil,
        syncedFromSmartGit: Bool = false,
        smartGitConfigPath: String? = nil,
        externalEditor: ExternalEditor = .system,
        customEditorPath: String? = nil,
        externalDiffTool: ExternalDiffTool = .builtin,
        customDiffToolPath: String? = nil,
        customDiffArgs: String = "${leftFile} ${rightFile}",
        customMergeArgs: String = "${leftFile} ${rightFile} ${baseFile} ${mergedFile}",
        lastOpenedRepoID: UUID? = nil,
        toolbarShowsLabels: Bool = true,
        escapeClosesSubwindows: Bool = true,
        quitsOnMainWindowClose: Bool = true,
        singleClickOpensRepo: Bool = true,
        recentCommitMessages: [String] = [],
        diagnosticsLoggingEnabled: Bool = true,
        perfBadgeEnabled: Bool = false,
        appearance: AppearanceMode = .system,
        showWhitespace: Bool = false,
        pullUsesRebase: Bool = false,
        diffColors: DiffColorOverrides = DiffColorOverrides()
    ) {
        self.fontSize = fontSize
        self.monoFontSize = monoFontSize
        self.diffMode = diffMode
        self.diffCompactMode = diffCompactMode
        self.ignoreWhitespace = ignoreWhitespace
        self.gitPath = gitPath
        self.syncedFromSmartGit = syncedFromSmartGit
        self.smartGitConfigPath = smartGitConfigPath
        self.externalEditor = externalEditor
        self.customEditorPath = customEditorPath
        self.externalDiffTool = externalDiffTool
        self.customDiffToolPath = customDiffToolPath
        self.customDiffArgs = customDiffArgs
        self.customMergeArgs = customMergeArgs
        self.lastOpenedRepoID = lastOpenedRepoID
        self.toolbarShowsLabels = toolbarShowsLabels
        self.escapeClosesSubwindows = escapeClosesSubwindows
        self.quitsOnMainWindowClose = quitsOnMainWindowClose
        self.singleClickOpensRepo = singleClickOpensRepo
        self.recentCommitMessages = recentCommitMessages
        self.diagnosticsLoggingEnabled = diagnosticsLoggingEnabled
        self.perfBadgeEnabled = perfBadgeEnabled
        self.appearance = appearance
        self.showWhitespace = showWhitespace
        self.pullUsesRebase = pullUsesRebase
        self.diffColors = diffColors
    }

    // Tolerant decode so config files written before we added new fields
    // still load. New fields fall back to their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.fontSize           = try c.decodeIfPresent(CGFloat.self,        forKey: .fontSize)           ?? 13
        self.monoFontSize       = try c.decodeIfPresent(CGFloat.self,        forKey: .monoFontSize)       ?? 12
        // `compact` used to be a third `DiffMode`; it's now the orthogonal
        // `diffCompactMode` flag. Read the raw string so an old config
        // value of "compact" migrates to unified-layout + compact-on
        // instead of throwing and resetting the whole config.
        let rawDiffMode = try? c.decode(String.self, forKey: .diffMode)
        if rawDiffMode == "compact" {
            self.diffMode        = .unified
            self.diffCompactMode = (try? c.decode(Bool.self, forKey: .diffCompactMode)) ?? true
        } else {
            self.diffMode        = rawDiffMode.flatMap(DiffMode.init(rawValue:)) ?? .sideBySide
            // Compact is the default short view; absent in older configs.
            self.diffCompactMode = (try? c.decode(Bool.self, forKey: .diffCompactMode)) ?? true
        }
        self.ignoreWhitespace   = try c.decodeIfPresent(Bool.self,           forKey: .ignoreWhitespace)   ?? false
        self.gitPath            = try c.decodeIfPresent(String.self,         forKey: .gitPath)
        self.syncedFromSmartGit = try c.decodeIfPresent(Bool.self,           forKey: .syncedFromSmartGit) ?? false
        self.smartGitConfigPath = try c.decodeIfPresent(String.self,         forKey: .smartGitConfigPath)
        self.externalEditor     = try c.decodeIfPresent(ExternalEditor.self,   forKey: .externalEditor)     ?? .system
        self.customEditorPath   = try c.decodeIfPresent(String.self,           forKey: .customEditorPath)
        self.externalDiffTool   = try c.decodeIfPresent(ExternalDiffTool.self, forKey: .externalDiffTool)   ?? .builtin
        self.customDiffToolPath = try c.decodeIfPresent(String.self,           forKey: .customDiffToolPath)
        self.customDiffArgs     = try c.decodeIfPresent(String.self,           forKey: .customDiffArgs)     ?? "${leftFile} ${rightFile}"
        self.customMergeArgs    = try c.decodeIfPresent(String.self,           forKey: .customMergeArgs)    ?? "${leftFile} ${rightFile} ${baseFile} ${mergedFile}"
        self.lastOpenedRepoID   = try c.decodeIfPresent(UUID.self,             forKey: .lastOpenedRepoID)
        self.toolbarShowsLabels = try c.decodeIfPresent(Bool.self,             forKey: .toolbarShowsLabels) ?? true
        self.escapeClosesSubwindows = try c.decodeIfPresent(Bool.self,          forKey: .escapeClosesSubwindows) ?? true
        self.quitsOnMainWindowClose = try c.decodeIfPresent(Bool.self,          forKey: .quitsOnMainWindowClose) ?? true
        self.singleClickOpensRepo   = try c.decodeIfPresent(Bool.self,          forKey: .singleClickOpensRepo) ?? true
        self.recentCommitMessages = try c.decodeIfPresent([String].self,        forKey: .recentCommitMessages) ?? []
        self.diagnosticsLoggingEnabled = try c.decodeIfPresent(Bool.self,       forKey: .diagnosticsLoggingEnabled) ?? true
        self.perfBadgeEnabled   = try c.decodeIfPresent(Bool.self,             forKey: .perfBadgeEnabled) ?? false
        self.appearance         = try c.decodeIfPresent(AppearanceMode.self,   forKey: .appearance) ?? .system
        self.showWhitespace     = try c.decodeIfPresent(Bool.self,             forKey: .showWhitespace) ?? false
        self.pullUsesRebase     = try c.decodeIfPresent(Bool.self,             forKey: .pullUsesRebase) ?? false
        self.diffColors         = try c.decodeIfPresent(DiffColorOverrides.self, forKey: .diffColors) ?? DiffColorOverrides()
    }
}

struct UIState: Codable, Sendable {
    var sidebarWidth: CGFloat
    var reposPanelRatio: CGFloat
    var topBottomRatio: CGFloat
    var journalOutputRatio: CGFloat
    /// When true, the Repositories + Branches sidebar is hidden so
    /// the user can focus on the active repo's Files / Diff /
    /// Journal. Toggled from the titlebar button next to the
    /// traffic lights; persisted so the choice survives restarts.
    var compactMode: Bool
    /// When true, the Changes panel shows the Terminal instead of the diff.
    /// Persisted because preferring a command line is a standing preference,
    /// not a per-session mood.
    var showsTerminal: Bool
    /// When true, the Journal + Output row is folded to a single bar, giving
    /// its height to the Changes / Terminal panel above.
    var bottomPanelsCollapsed: Bool
    /// Where the main window was when it last closed, so it reopens in the
    /// same place — and on the same display. `nil` until the first move or
    /// resize, which leaves SwiftUI's default placement in charge.
    var mainWindowFrame: WindowFrameState?

    init(
        sidebarWidth: CGFloat = 260,
        reposPanelRatio: CGFloat = 0.5,
        topBottomRatio: CGFloat = 0.55,
        journalOutputRatio: CGFloat = 0.6,
        compactMode: Bool = false,
        showsTerminal: Bool = false,
        bottomPanelsCollapsed: Bool = false,
        mainWindowFrame: WindowFrameState? = nil
    ) {
        self.sidebarWidth = sidebarWidth
        self.reposPanelRatio = reposPanelRatio
        self.topBottomRatio = topBottomRatio
        self.journalOutputRatio = journalOutputRatio
        self.compactMode = compactMode
        self.showsTerminal = showsTerminal
        self.bottomPanelsCollapsed = bottomPanelsCollapsed
        self.mainWindowFrame = mainWindowFrame
    }

    // Tolerant decode for users upgrading from a version without
    // `compactMode` in `ui-state.json` — defaults to off so they
    // see the same layout they had before.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sidebarWidth        = try c.decodeIfPresent(CGFloat.self, forKey: .sidebarWidth)        ?? 260
        self.reposPanelRatio     = try c.decodeIfPresent(CGFloat.self, forKey: .reposPanelRatio)     ?? 0.5
        self.topBottomRatio      = try c.decodeIfPresent(CGFloat.self, forKey: .topBottomRatio)      ?? 0.55
        self.journalOutputRatio  = try c.decodeIfPresent(CGFloat.self, forKey: .journalOutputRatio)  ?? 0.6
        self.compactMode         = try c.decodeIfPresent(Bool.self,    forKey: .compactMode)         ?? false
        self.showsTerminal       = try c.decodeIfPresent(Bool.self,    forKey: .showsTerminal)       ?? false
        self.bottomPanelsCollapsed = try c.decodeIfPresent(Bool.self,  forKey: .bottomPanelsCollapsed) ?? false
        self.mainWindowFrame     = try c.decodeIfPresent(WindowFrameState.self, forKey: .mainWindowFrame)
    }
}
