import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Opens an NSOpenPanel scoped to `.patch` / `.diff` / plain-text
/// files, then routes the selection through `AppState.applyPatchFile`.
/// Lives at file scope so both menu items in the Apply Patch menu
/// share it without re-defining the picker logic.
/// Thin vertical hairline used to break the toolbar into the
/// logical groups SmartGit ships with (remote / index / stash /
/// branch / view). SwiftUI's `ToolbarItemGroup` packs items
/// together but renders no visible boundary on macOS's unified
/// toolbar, so we insert these between groups as plain
/// `ToolbarItem`s.
private struct ToolbarGroupSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 1, height: 22)
            // The titlebar pads each toolbar item with a fixed gap;
            // pulling 4pt of horizontal padding off keeps the rule
            // visually balanced against icon spacing rather than
            // floating in the middle of a wide gap.
            .padding(.horizontal, -4)
            .accessibilityHidden(true)
    }
}

/// Label for a toolbar split button — one that acts on click and only
/// opens its menu from the chevron.
///
/// The hairline after the icon is the thing that says so: without it the
/// chevron reads as decoration on a single button, and the two halves
/// look like one target. It sits inside the `Label`'s icon so the title
/// stays a plain `Text`, which is what AppKit shows when the toolbar is
/// in its icon-and-text display mode.
private struct SplitButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Rectangle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 1, height: 13)
                    .accessibilityHidden(true)
            }
        }
    }
}

@MainActor
private func pickAndApplyPatch(appState: AppState, threeWay: Bool) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Apply"
    panel.allowedContentTypes = [
        UTType(filenameExtension: "patch") ?? .data,
        UTType(filenameExtension: "diff") ?? .data,
        .plainText
    ]
    if let repo = appState.activeRepo {
        panel.directoryURL = URL(fileURLWithPath: repo.path).deletingLastPathComponent()
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await appState.applyPatchFile(at: url, threeWay: threeWay) }
}

/// Top toolbar — every button corresponds to a git CLI action and routes
/// through `AppState`. Groups follow the spec: refresh, remote ops, index
/// ops, stash, history/branch ops, then settings. Each group is bounded by
/// a hairline separator so the user can read the toolbar as "refresh /
/// remote / index / stash & patch / branch / settings" at a glance — same
/// visual rhythm SmartGit uses, with the two buttons that leave the
/// repository alone at either end.
struct ToolbarView: ToolbarContent {
    @Bindable var appState: AppState

    /// The Pull menu's two entries are one choice, so they're checkmarked
    /// toggles rather than two buttons that look unrelated. Picking one
    /// pulls *and* becomes what the button repeats; the already-selected
    /// one just pulls again.
    private func pullMode(rebase: Bool) -> Binding<Bool> {
        Binding(
            get: { appState.pullUsesRebase == rebase },
            set: { _ in Task { await appState.pullChoosingMode(rebase: rebase) } }
        )
    }

    /// Split into sections because `ToolbarContentBuilder` takes at most ten
    /// children and the row is longer than that — each section is one child,
    /// carrying the hairline that precedes it.
    var body: some ToolbarContent {
        leadingSection
        remoteSection
        indexSection
        stashSection
        branchSection
        settingsSection
    }

    /// The sidebar toggle and Refresh — the two that read rather than write.
    @ToolbarContentBuilder var leadingSection: some ToolbarContent {
        // Sidebar-toggle button anchored next to the traffic-light
        // controls. `.navigation` is macOS's leading slot, which
        // pushes us against the green button. The icon swaps to
        // match macOS's standard sidebar-show / sidebar-hide
        // glyphs so the affordance reads at a glance.
        ToolbarItem(placement: .navigation) {
            Button {
                appState.toggleCompactMode()
            } label: {
                Image(systemName: appState.uiState.compactMode
                      ? "sidebar.left"
                      : "sidebar.leading")
            }
            .keyboardShortcut("0", modifiers: [.command, .control])
            .accessibilityIdentifier("toolbar.sidebar")
            .help(appState.uiState.compactMode
                  ? "Show sidebar (^\u{2318}0)"
                  : "Hide sidebar — focus on the active repo (^\u{2318}0)")
        }

        // Refresh — visible counterpart to ⌘R (the shortcut itself is
        // bound in the Repository command menu; avoid binding it twice).
        // First in the row because it is the only button here that just
        // re-reads: everything after it changes the repository, and the
        // one that does not should not sit among them.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await appState.refreshAllForced() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(appState.activeRepo == nil)
            .accessibilityIdentifier("toolbar.refresh")
            .help("Force-refresh all panels (\u{2318}R)")
        }
    }

    /// Pull, Sync, Push.
    @ToolbarContentBuilder var remoteSection: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { ToolbarGroupSeparator() }

        ToolbarItemGroup(placement: .primaryAction) {
            // Split button: the icon repeats the pull you last chose, the
            // chevron reopens the choice. Merge-or-rebase is a habit, so
            // making every pull a two-step menu asks a question the user
            // has already answered — SmartGit's Pull works the same way.
            Menu {
                Toggle(isOn: pullMode(rebase: false)) { Text("Pull (Merge)") }
                Toggle(isOn: pullMode(rebase: true)) { Text("Pull (Rebase)") }
                Divider()
                Button("Fetch") { Task { await appState.fetch() } }
                    .accessibilityIdentifier("toolbar.fetch")
            } label: {
                SplitButtonLabel(
                    title: "Pull",
                    systemImage: "arrow.down.to.line"
                )
            } primaryAction: {
                Task { await appState.pullUsingRememberedMode() }
            }
            .accessibilityIdentifier("toolbar.pull")
            .help(appState.pullUsesRebase
                  ? "Pull (Rebase) — click the arrow to change"
                  : "Pull (Merge) — click the arrow to change")

            Button {
                Task { await appState.sync() }
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .keyboardShortcut("y", modifiers: .command)
            .accessibilityIdentifier("toolbar.sync")
            .help("Sync — pull then push (\u{2318}Y)")

            Menu {
                Button("Push") { Task { await appState.push() } }
                Button("Push Tags") { Task { await appState.push(tags: true) } }
                Divider()
                Button("Force Push (with lease)") { Task { await appState.push(force: true) } }
            } label: {
                Label("Push", systemImage: "arrow.up.to.line")
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .help("Push to remote (\u{21E7}\u{2318}K)")
        }
    }

    /// Commit, Stage, Unstage, Discard.
    @ToolbarContentBuilder var indexSection: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { ToolbarGroupSeparator() }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                appState.showCommitDialog = true
            } label: {
                Label("Commit", systemImage: "checkmark.circle")
            }
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityIdentifier("toolbar.commit")
            .disabled(!appState.canUseActiveRepo)
            .help("Commit staged changes, or the files selected in the Files panel (\u{2318}K)")

            Button {
                let paths = appState.filesVM.selectedPaths
                Task { await appState.stage(files: paths) }
            } label: {
                Label("Stage", systemImage: "plus.circle")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("toolbar.stage")
            .disabled(appState.filesVM.selectedFileIDs.isEmpty)
            .help("Stage selected files (\u{2318}\u{21A9})")

            Button {
                let paths = appState.filesVM.selectedUnstageablePaths
                Task { await appState.unstage(files: paths) }
            } label: {
                Label("Unstage", systemImage: "minus.circle")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .accessibilityIdentifier("toolbar.unstage")
            .disabled(appState.filesVM.selectedUnstageablePaths.isEmpty)
            .help(appState.filesVM.selectedUnstageablePaths.isEmpty
                  && !appState.filesVM.selectedFileIDs.isEmpty
                  ? "A conflict has nothing staged to take back — resolve or discard it instead"
                  : "Unstage selected files (\u{2318}\u{232B})")

            Button {
                appState.confirmDiscard = true
            } label: {
                Label("Discard", systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("toolbar.discard")
            .disabled(!appState.canUseActiveRepo)
            .help("Discard uncommitted changes")
        }
    }

    /// Save Stash, Apply Stash, Apply Patch.
    @ToolbarContentBuilder private var stashSection: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { ToolbarGroupSeparator() }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                // Every entry opens the dialog, pre-set: saving straight away
                // left the stash under git's "WIP on <branch>: <sha> …",
                // which says nothing about what was put aside.
                Button("Save Stash…") { appState.showStashSaveDialog = true }
                Button("Save Stash (incl. untracked)…") {
                    appState.openStashSaveDialog(.init(includeUntracked: true))
                }
                Divider()
                // Untracked files included: a snapshot removes nothing from
                // the working tree either way, and one that skipped new files
                // would be a poor thing to fall back on. The dialog's
                // checkbox is there for a tracked-only snapshot.
                Button("Save Snapshot (keeps your changes)…") {
                    appState.openStashSaveDialog(.init(includeUntracked: true, snapshot: true))
                }
            } label: {
                Label("Save Stash", systemImage: "tray.and.arrow.down")
            }
            .help("Save working changes to a stash")

            Menu {
                if appState.stashList.isEmpty {
                    Text("No stashes")
                } else {
                    ForEach(appState.stashList) { stash in
                        Button("Apply: \(stash.message)") {
                            Task { await appState.stashApply(index: stash.index) }
                        }
                    }
                    Divider()
                }
                Button("Pop Latest") { Task { await appState.stashPop() } }
                Divider()
                Button("Browse Stashes…") { appState.showStashesSheet = true }
            } label: {
                Label("Apply Stash", systemImage: "tray.and.arrow.up")
            }
            .help("Apply, pop, or browse stashes")

            Menu {
                Button("Apply Patch…") {
                    pickAndApplyPatch(appState: appState, threeWay: false)
                }
                Button("Apply Patch (3-way)…") {
                    pickAndApplyPatch(appState: appState, threeWay: true)
                }
                .help("Fall back to a 3-way merge when context doesn't match")
            } label: {
                Label("Apply Patch", systemImage: "bandage")
            }
            .disabled(!appState.canUseActiveRepo)
            .help("Apply a .patch file to the working tree")
        }
    }

    /// Merge and Rebase.
    @ToolbarContentBuilder var branchSection: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { ToolbarGroupSeparator() }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                appState.showMergePicker = true
            } label: {
                Label("Merge", systemImage: "arrow.triangle.merge")
            }
            .accessibilityIdentifier("toolbar.merge")
            .disabled(!appState.canUseActiveRepo)
            .help("Merge another branch into the current one")

            Button {
                appState.showRebasePicker = true
            } label: {
                Label("Rebase", systemImage: "arrow.triangle.swap")
            }
            .accessibilityIdentifier("toolbar.rebase")
            .disabled(!appState.canUseActiveRepo)
            .help("Rebase the current branch onto another")
        }
    }

    /// Settings — opens the same sheet as the app menu's "Settings…". The
    /// shortcut stays bound there alone, so ⌘, has one owner.
    @ToolbarContentBuilder var settingsSection: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { ToolbarGroupSeparator() }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                appState.showPreferences = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("toolbar.settings")
            .help("Settings (\u{2318},)")
        }
    }
}
