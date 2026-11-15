import SwiftUI

@main
struct SmallGitApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("SmallGit") {
            MainWindow(appState: appState)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") {
                    appState.presentOpenRepository()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button("Sync from SmartGit…") {
                    appState.showSyncFromSmartGitSheet = true
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appState.showPreferences = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    appState.bumpMonoFontSize(by: 1)
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Zoom Out") {
                    appState.bumpMonoFontSize(by: -1)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    appState.resetMonoFontSize()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandMenu("Repository") {
                Button("Refresh") {
                    Task { await appState.refreshAllForced() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.activeRepo == nil)

                LogMenuButton(appState: appState)

                Divider()

                // Reflog-based one-click undo. ⌥⌘Z so plain ⌘Z stays
                // text-editing undo in commit-message fields etc.
                Button("Undo Last Operation…") {
                    Task { await appState.undoLastOperation() }
                }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!appState.canUseActiveRepo)

                Divider()

                Button("New Branch…") {
                    appState.showNewBranchSheet = true
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!appState.canUseActiveRepo)

                Button("Merge…") {
                    appState.showMergePicker = true
                }
                .disabled(!appState.canUseActiveRepo)

                Button("Rebase…") {
                    appState.showRebasePicker = true
                }
                .disabled(!appState.canUseActiveRepo)

                Button("Browse Stashes…") {
                    appState.showStashesSheet = true
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!appState.canUseActiveRepo)

                Button("Browse Reflog…") {
                    appState.showReflogSheet = true
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!appState.canUseActiveRepo)

                Button("Worktrees…") {
                    appState.showWorktreesSheet = true
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!appState.canUseActiveRepo)

                Button("Submodules…") {
                    appState.showSubmodulesSheet = true
                }
                .disabled(!appState.canUseActiveRepo)

                Divider()

                Button("Close Repository") {
                    appState.closeActiveRepo()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(appState.activeRepo == nil)
            }

            CommandGroup(replacing: .help) {
                Button("Welcome to SmallGit") {
                    appState.isFirstLaunch = true
                }
                Button("Sync from SmartGit…") {
                    appState.showSyncFromSmartGitSheet = true
                }
            }
        }

        // Dedicated Log window — `Window(_:id:)` is singleton, so ⌘L
        // brings the existing window to the front rather than spawning
        // duplicates.
        // The submodule window has a repository context of its own, so it
        // can show B while the main window goes on working in A.
        Window("Submodule", id: "submodule-log") {
            SubmoduleLogWindow(appState: appState)
                .environment(\.monoFontSize, appState.appConfig.monoFontSize)
                .environment(\.uiScale, appState.appConfig.monoFontSize / 12)
        }

        Window("Log", id: "log") {
            AppZoom(appState: appState) {
                LogWindow(appState: appState)
            }
        }

        // Conflict resolver — real OS window (titlebar, drag, resize)
        // instead of a sheet. Singleton so re-resolving a different
        // file reuses the same window, mirroring how Beyond Compare
        // handles successive merge sessions.
        Window("Resolve Conflict", id: "conflict") {
            // Wrapped like every other window: this scene never applied the
            // zoom environment at all, so the resolver rendered at the default
            // 12pt however the rest of the app was set.
            AppZoom(appState: appState) {
            if let target = appState.conflictTarget {
                ConflictResolverPresenter(appState: appState, path: target.path)
            } else {
                // Empty fallback when the user re-opens the window
                // via Window menu without having clicked a file —
                // we don't want to crash the scene.
                Text("No conflicted file selected")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 600, minHeight: 400)
            }
            }
        }
        .defaultSize(width: 1200, height: 760)
    }
}

/// Quitting is driven by `MainWindowStateHandler`, which saves the window
/// frame *before* calling `NSApp.terminate` — so this delegate deliberately
/// declines AppKit's own "quit after the last window closed", which would
/// race that write and lose the final frame.
///
/// The secondary Log / Conflict windows aren't main windows: closing one
/// never quits, and closing the main window quits even while one is open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Themes the app before AppKit puts anything on screen. `AppState`
    /// applies the same value again once its config load finishes, but that
    /// is several awaits after the window exists — long enough for a
    /// light-themed launch to flash a dark titlebar.
    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.raiseDescriptorLimit()
        ConfigService.shared.appearanceBlocking().applyToApp()
    }

    /// launchd hands a double-clicked `.app` a soft limit of 256 open
    /// descriptors. SmallGit asks git about every repository in the sidebar
    /// at once, and each running command holds a pipe at each end, so a
    /// single refresh across a full sidebar spends a sizeable share of that
    /// on its own. Raise the soft limit to whatever the kernel allows per
    /// process; nothing here needs the descriptors to be scarce.
    private static func raiseDescriptorLimit() {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return }
        let wanted = rlim_t(OPEN_MAX)
        guard limits.rlim_cur < wanted else { return }
        limits.rlim_cur = min(wanted, limits.rlim_max)
        setrlimit(RLIMIT_NOFILE, &limits)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Diagnostic records are buffered and flushed about once a second, so
    /// without this the final second of a session is lost — and the final
    /// second is exactly what you want when the app misbehaved on the way out.
    func applicationWillTerminate(_ notification: Notification) {
        Log.app("app.terminate")
        Log.store.flushNow()
    }
}

/// Standalone button so the @Environment(\.openWindow) lookup is
/// scoped correctly — Commands can't host @Environment directly.
private struct LogMenuButton: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Log") {
            openWindow(id: "log")
        }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(!appState.canUseActiveRepo)
    }
}
