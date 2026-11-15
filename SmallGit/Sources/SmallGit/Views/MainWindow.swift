import SwiftUI
import AppKit

/// Root window. Composes the six resizable panels described in spec §3.1.
///
///   ┌───────┬───────────────────┐
///   │ Repos │ Files             │
///   │       ├───────────────────┤
///   │       │ Diff              │
///   ├───────┼─────────┬─────────┤
///   │ Brn   │ Journal │ Output  │
///   └───────┴─────────┴─────────┘
struct MainWindow: View {
    @Bindable var appState: AppState
    /// Samples this process for the performance badge. Owned here rather than
    /// by `AppState` because it is a property of this window being open, not
    /// of the app's state, and it has to stop when the badge does.
    @State private var perf = PerformanceSampler()

    var body: some View {
        // The status strip is stacked *below* the panels rather than
        // over them: as a ZStack layer it painted across the bottom of
        // whatever panel reached the window edge, hiding the last row of
        // the Branches list and the Journal. The toast still floats —
        // it's transient and shouldn't resize anything.
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                mainSplits

                if let toast = appState.toast {
                    BottomToast(text: toast.text)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }
            }

            StatusBar(
                statusText: appState.statusText,
                changedFileCount: appState.changedFileCount,
                cursorInfo: nil,
                isWorking: appState.isWorking,
                // The sampler itself, unread: reading its value here would put
                // this whole body — every panel in the window — on a
                // once-a-second rebuild for the sake of the badge.
                perfSampler: appState.appConfig.perfBadgeEnabled ? perf : nil
            )
            // Keyed on the setting, so switching the badge off cancels the
            // loop rather than leaving it sampling for a badge nobody is
            // looking at.
            .task(id: appState.appConfig.perfBadgeEnabled) {
                guard appState.appConfig.perfBadgeEnabled else { return }
                await perf.run()
            }
        }
        .animation(.easeOut(duration: 0.18), value: appState.toast)
        .toolbar { ToolbarView(appState: appState) }
        .background(
            ToolbarDisplayApplier(showLabels: appState.appConfig.toolbarShowsLabels)
        )
        .navigationTitle(appState.activeRepo?.name ?? "SmallGit")
        .frame(minWidth: 1000, minHeight: 640)
        .preferredColorScheme(appState.appConfig.appearance.colorScheme)
        .environment(\.monoFontSize, appState.appConfig.monoFontSize)
        .environment(\.uiScale, appState.appConfig.monoFontSize / 12)
        .environment(\.showWhitespace, appState.appConfig.showWhitespace)
        .task {
            await appState.bootstrap()
        }
        .alert(
            "Rebase result doesn't match the plan",
            isPresented: Binding(
                get: { appState.rebaseOutcomeMismatch != nil },
                set: { if !$0 { appState.rebaseOutcomeMismatch = nil } }
            ),
            presenting: appState.rebaseOutcomeMismatch
        ) { mismatch in
            Button("Keep Result", role: .cancel) { appState.rebaseOutcomeMismatch = nil }
            Button("Undo Rebase", role: .destructive) {
                appState.rebaseOutcomeMismatch = nil
                Task { await appState.undoMismatchedRebase(mismatch) }
            }
        } message: { mismatch in
            Text(mismatch.summary)
        }
        .alert("Discard changes?", isPresented: $appState.confirmDiscard) {
            Button("Cancel", role: .cancel) { }
            Button("Discard", role: .destructive) {
                let plan = appState.filesVM.selectedDiscardPlan
                Task { await appState.discard(plan: plan) }
            }
        } message: {
            // Named per kind of file: a selection can hold all three, and
            // deleting an untracked file is not the same promise as reverting
            // a tracked one.
            Text(appState.filesVM.selectedDiscardPlan.confirmationMessage)
        }
        .sheet(isPresented: $appState.showCommitDialog) {
            CommitDialog(appState: appState)
        }
        .sheet(isPresented: $appState.showStashSaveDialog) {
            StashMessageSheet(appState: appState)
        }
        .sheet(isPresented: $appState.showSubmodulesSheet) {
            SubmodulesView(appState: appState)
        }

        .sheet(isPresented: $appState.showWorktreesSheet) {
            WorktreesView(appState: appState)
        }
        .sheet(isPresented: $appState.showNewBranchSheet) {
            NewBranchSheet(appState: appState)
        }
        .sheet(item: $appState.branchPendingRename) { branch in
            RenameBranchSheet(branch: branch, appState: appState)
        }
        .sheet(item: $appState.stashPendingRename) { stash in
            RenameStashSheet(stash: stash, appState: appState)
        }
        .alert(
            StashDropConfirmation.title(appState.pendingStashDrop),
            isPresented: Binding(
                get: { !appState.pendingStashDrop.isEmpty },
                set: { if !$0 { appState.pendingStashDrop = [] } }
            )
        ) {
            Button("Cancel", role: .cancel) { appState.pendingStashDrop = [] }
            Button(StashDropConfirmation.buttonLabel(appState.pendingStashDrop), role: .destructive) {
                let indices = appState.pendingStashDrop
                appState.pendingStashDrop = []
                // The indices shift once anything drops; a selection kept
                // across that would point at other stashes.
                appState.branchesVM.selection = []
                Task { await appState.stashDrop(indices: indices) }
            }
        } message: {
            Text(StashDropConfirmation.message(appState.pendingStashDrop, stashes: appState.stashList))
        }
        .sheet(item: $appState.branchPendingNewFrom) { branch in
            NewBranchSheet(appState: appState, initialFrom: branch.name)
        }
        .sheet(item: $appState.branchPendingPushTo) { branch in
            PushToSheet(branch: branch, appState: appState)
        }
        .sheet(item: $appState.branchPendingSetUpstream) { branch in
            SetTrackedBranchSheet(branch: branch, appState: appState)
        }
        .sheet(item: $appState.branchPendingDelete) { target in
            DeleteBranchSheet(target: target, appState: appState)
        }
        .sheet(isPresented: $appState.showMergePicker) {
            BranchPickerSheet(
                title: "Merge into current branch",
                confirmLabel: "Merge",
                appState: appState
            ) { branch in
                Task { await appState.merge(branch: branch) }
            }
        }
        .sheet(isPresented: $appState.showRebasePicker) {
            BranchPickerSheet(
                title: "Rebase current branch onto…",
                confirmLabel: "Rebase",
                appState: appState
            ) { branch in
                Task { await appState.rebase(onto: branch) }
            }
        }
        .sheet(item: $appState.pendingInteractiveRebase) { target in
            InteractiveRebaseSheet(target: target, appState: appState)
        }
        .sheet(item: $appState.pendingSquash) { plan in
            SquashCommitsSheet(plan: plan, appState: appState)
        }
        .sheet(item: $appState.pendingReword) { plan in
            RewordCommitSheet(plan: plan, appState: appState)
        }
        .sheet(item: $appState.pendingTagTarget) { target in
            AddTagSheet(target: target, appState: appState)
        }
        .sheet(isPresented: $appState.showReflogSheet) {
            ReflogBrowserView(appState: appState)
        }
        .sheet(isPresented: $appState.showSyncFromSmartGitSheet) {
            SyncFromSmartGitView(appState: appState)
        }
        .sheet(isPresented: $appState.showPreferences) {
            PreferencesView(appState: appState)
        }
        .sheet(isPresented: $appState.showAddGroupSheet) {
            AddGroupSheet(appState: appState)
        }
        .sheet(item: $appState.credentialRequest) { request in
            CredentialsSheet(appState: appState, request: request)
        }
        .sheet(isPresented: $appState.showCloneSheet) {
            CloneRepositorySheet(appState: appState)
        }
        .sheet(isPresented: $appState.isFirstLaunch) {
            WelcomeView(appState: appState)
        }
        // Whenever the app comes back to the foreground (returning from
        // an external diff/merge tool, Finder, terminal, etc.) the
        // working tree may have changed under us — re-fetch status,
        // diff, branches so conflicts the user just resolved disappear
        // without a manual ⌘R.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard appState.activeRepo != nil else { return }
            Task { await appState.refreshAllForced() }
        }
        // The conflict resolver lives in its own OS window (defined in
        // SmallGitApp) so the user can move it freely, resize it,
        // and keep it alongside the main window while exploring the
        // rest of the repo. We just watch the trigger and open it.
        .background(ConflictWindowOpener(appState: appState))
        .background(FileHistoryWindowOpener(appState: appState))
        .background(StashesWindowOpener(appState: appState))
        .background(EscapeDismissHandler(appState: appState))
        // Restores the window's last frame (on its last display) and quits the
        // app when the close button is used — see MainWindowStateHandler.
        .background(MainWindowStateHandler(appState: appState))
        .background(CompareWindowOpener(appState: appState))
        .sheet(item: $appState.blameTarget) { target in
            BlameView(appState: appState, path: target.path)
        }
        .sheet(item: $appState.patchSource) { source in
            CreatePatchSheet(appState: appState, source: source)
        }
        .sheet(item: $appState.pendingInitTarget) { target in
            InitRepositorySheet(appState: appState, target: target)
        }
        .sheet(item: $appState.pendingAmbiguousTarget) { target in
            AmbiguousFolderSheet(appState: appState, target: target)
        }
        .sheet(item: $appState.pendingGroupRename) { target in
            RenameGroupSheet(appState: appState, originalName: target.name)
        }
        .sheet(item: $appState.pendingRepoRename) { target in
            RenameRepositorySheet(appState: appState, target: target)
        }
        .sheet(item: $appState.pendingRepoSettings) { repo in
            RepositorySettingsSheet(appState: appState, repo: repo)
        }
        .sheet(item: $appState.pendingRepositoryRemoval) { target in
            RepositoryRemovalSheet(appState: appState, target: target)
        }
        .alert(
            "Delete group \"\(appState.pendingGroupDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { appState.pendingGroupDelete != nil },
                set: { if !$0 { appState.pendingGroupDelete = nil } }
            ),
            presenting: appState.pendingGroupDelete
        ) { target in
            Button("Cancel", role: .cancel) {
                appState.pendingGroupDelete = nil
            }
            Button("Delete", role: .destructive) {
                let name = target.name
                appState.pendingGroupDelete = nil
                Task { await appState.deleteGroup(name: name) }
            }
        } message: { target in
            if target.repoCount == 0 {
                Text("This group has no repositories.")
            } else {
                Text("The \(target.repoCount) repositor\(target.repoCount == 1 ? "y" : "ies") in this group will move to \"Other\".")
            }
        }
    }

    /// The six-panel split layout, hoisted out of `body` so the
    /// optional in-progress banner can sit above it without breaking
    /// the VStack/ZStack composition.
    private var mainSplits: some View {
        HSplitView {
            // Left sidebar — repositories on top, branches on the
            // bottom. Hidden in compact mode so the user can focus
            // on the active repo's Files / Diff / Journal without
            // the sidebar competing for screen real estate.
            if !appState.uiState.compactMode {
                VSplitView {
                    RepositoriesPanel(appState: appState)
                        .frame(minHeight: 120)
                    BranchesPanel(appState: appState, viewModel: appState.branchesVM)
                        .frame(minHeight: 140)
                }
                .frame(
                    minWidth: 180,
                    idealWidth: appState.uiState.sidebarWidth,
                    maxWidth: 420
                )
            }

            // Right side — files & diff (top), journal & output (bottom).
            VSplitView {
                VSplitView {
                    FilesTableView(appState: appState, viewModel: appState.filesVM)
                        .frame(minHeight: 100)
                    // Same slot, two panels: the diff, or the terminal that
                    // replaces it. The switch lives in both headers.
                    Group {
                        if appState.uiState.showsTerminal {
                            TerminalPanel(appState: appState, viewModel: appState.terminalVM)
                        } else {
                            DiffView(appState: appState, viewModel: appState.diffVM)
                        }
                    }
                    .frame(minHeight: 160)
                }
                .frame(minHeight: 240)

                // Collapsed, the row is one bar naming what is folded away:
                // a fixed height, so the split divider above it cannot drag
                // it back open by accident.
                if appState.uiState.bottomPanelsCollapsed {
                    BottomPanelsBar {
                        appState.setBottomPanelsCollapsed(false)
                    }
                    .frame(height: BottomPanelsBar.height)
                } else {
                    HSplitView {
                        JournalView(appState: appState, viewModel: appState.journalVM)
                            .frame(minWidth: 240)
                        OutputView(output: appState.output) { link in
                            appState.revealInFinder(path: link.path)
                        }
                            .frame(minWidth: 240)
                    }
                    .frame(minHeight: 160)
                }
            }
        }
        .background(Color.bgApp)
    }
}

private struct BottomToast: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentBlue)
            Text(text)
                .scaledFont(12, weight: .medium)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Color.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.bgPanelHeader)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.borderColor, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        )
        .frame(maxWidth: 360)
    }
}

// MARK: - Conflict resolver window opener

/// Invisible bridge between `appState.conflictTarget` and the
/// `openWindow` environment action. The conflict resolver is hosted
/// in a separate OS window (so the user can drag/resize it freely),
/// but the trigger to open it lives in `AppState` — which can't
/// reach `@Environment(\.openWindow)` directly. Parking a zero-size
/// view in MainWindow's background gives us a place where both are
/// in scope.
private struct ConflictWindowOpener: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: appState.conflictTarget) { _, new in
                if new != nil { openWindow(id: "conflict") }
            }
    }
}

/// Bridges `appState.compareTarget` to a real compare window.
///
/// The target is treated as a *request* — cleared the moment the window is
/// opened — rather than as a record of what's on screen. Two reasons: with
/// several compares open at once there is no single target to hold, and
/// leaving it set would make reopening the same file a no-op once its window
/// had been closed (the value wouldn't change, so `onChange` wouldn't fire).
private struct CompareWindowOpener: View {
    @Bindable var appState: AppState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: appState.compareTarget) { _, new in
                guard let new else { return }
                appState.compareTarget = nil
                CompareWindowPresenter.presentFileCompares(
                    appState: appState,
                    paths: new.paths
                )
            }
    }
}

private struct FileHistoryWindowOpener: View {
    @Bindable var appState: AppState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: appState.fileHistoryTarget) { _, new in
                guard let new else { return }
                ModalWindowPresenter.present(
                    title: "File History",
                    size: CGSize(width: 980, height: 700),
                    minSize: CGSize(width: 760, height: 520),
                    appState: appState,
                    onClose: {
                        if appState.fileHistoryTarget?.path == new.path {
                            appState.fileHistoryTarget = nil
                        }
                    }
                ) { close in
                    FileHistoryView(appState: appState, path: new.path, onClose: close)
                }
            }
    }
}

/// Stashes get a window rather than a `.sheet` for the same reason File
/// History does: the list is as long as the repository makes it, so the
/// height has to be the user's to choose.
private struct StashesWindowOpener: View {
    @Bindable var appState: AppState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: appState.showStashesSheet) { _, shown in
                guard shown else { return }
                // Cleared as it opens: the flag is the request, not the
                // state, so asking a second time re-fires this.
                appState.showStashesSheet = false
                ModalWindowPresenter.present(
                    title: "Stashes",
                    size: CGSize(width: 900, height: 640),
                    minSize: CGSize(width: 560, height: 360),
                    appState: appState
                ) { close in
                    StashesView(appState: appState, onClose: close)
                }
            }
    }
}

private struct EscapeDismissHandler: NSViewRepresentable {
    let appState: AppState

    func makeNSView(context: Context) -> EscapeDismissCaptureView {
        let view = EscapeDismissCaptureView()
        view.onWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.mainWindow = window
        }
        context.coordinator.appState = appState
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: EscapeDismissCaptureView, context: Context) {
        context.coordinator.appState = appState
        if let window = nsView.window {
            context.coordinator.mainWindow = window
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var mainWindow: NSWindow?
        weak var appState: AppState?
        nonisolated(unsafe) private var monitor: Any?

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.isEscapeKey else { return event }

                let handled = MainActor.assumeIsolated {
                    self?.handleEscape() == true
                }
                return handled ? nil : event
            }
        }

        private func handleEscape() -> Bool {
            // Before anything closes: the key window's own view may be holding
            // Escape for a step of its own — a compare block open for typing.
            // This monitor reaches every window in the app, so without asking
            // it would close the window the user is typing in.
            if let key = NSApp.keyWindow,
               appState?.consumeEscape(in: ObjectIdentifier(key)) == true {
                return true
            }
            guard appState?.appConfig.escapeClosesSubwindows == true else {
                return false
            }

            let dismissedState = appState?.dismissTopSubviewFromEscape() == true
            let closedWindow = closeActiveWindowOrSheet()
            return dismissedState || closedWindow
        }

        private func closeActiveWindowOrSheet() -> Bool {
            if let keyWindow = NSApp.keyWindow,
               let sheet = keyWindow.attachedSheet, closable(sheet) {
                sheet.performClose(nil)
                return true
            }

            if let keyWindow = NSApp.keyWindow,
               keyWindow.sheetParent != nil, closable(keyWindow) {
                keyWindow.performClose(nil)
                return true
            }

            for window in NSApp.windows where window !== mainWindow {
                if let sheet = window.attachedSheet, closable(sheet) {
                    sheet.performClose(nil)
                    return true
                }
            }

            if let sheet = mainWindow?.attachedSheet, closable(sheet) {
                sheet.performClose(nil)
                return true
            }

            if let keyWindow = NSApp.keyWindow,
               keyWindow !== mainWindow {
                keyWindow.performClose(nil)
                return true
            }

            return false
        }

        /// A sheet whose view holds Escape stays put even when it isn't key.
        /// The commit dialog is one: with a compare window opened from it in
        /// front, the press belongs to the compare, and falling through to
        /// the sheet behind would throw away the message being written.
        private func closable(_ sheet: NSWindow) -> Bool {
            appState?.holdsEscape(ObjectIdentifier(sheet)) != true
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

private final class EscapeDismissCaptureView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindow?(window)
        }
    }
}

// MARK: - In-progress operation banner

/// Banner shown above the conflicted file list whenever a merge, rebase,
/// cherry-pick, or revert is mid-flight. Non-private because `FilesTableView`
/// mounts it directly under its panel header so both the in-progress state and
/// the conflict count read as one stack — SmartGit's "you're in merging-state"
/// layout.
///
/// Continue is disabled whenever git would refuse it, and says which of the
/// three reasons applies: files still conflicted, files still holding the
/// markers of a conflict git has lost track of, or — for the sequencer
/// operations — unstaged changes anywhere in the working tree. Clearing the
/// named one enables the button, at which point the user can finish the
/// operation without dropping to a terminal.
struct InProgressOperationBanner: View {
    /// What the repository is actually in the middle of.
    enum Situation: Equatable {
        /// A merge / rebase / cherry-pick / revert git is tracking, which it
        /// can therefore continue or abort on request.
        case operation(GitService.InProgressOperation)
        /// Unmerged files with no marker behind them. A conflicted `stash
        /// apply` lands here — git records nothing for it — and so does
        /// anything done in a terminal outside SmallGit. There is no
        /// sequencer to continue, which is the thing worth saying: without
        /// it the user waits for a Continue button that is never coming.
        case unattributed
    }

    let situation: Situation
    @Bindable var appState: AppState

    private var operation: GitService.InProgressOperation? {
        if case .operation(let op) = situation { return op }
        return nil
    }

    private var unresolvedCount: Int {
        Self.unresolvedCount(in: appState.filesVM.files)
    }

    /// Files that still hold conflict markers git has stopped calling a
    /// conflict. See `AppState.flattenedConflictPaths`.
    private var flattenedCount: Int {
        appState.flattenedConflictPaths.count
    }

    private var continueBlocker: String? {
        guard let operation else { return nil }
        return Self.continueBlocker(
            operation: operation,
            files: appState.filesVM.files,
            flattenedConflictCount: flattenedCount
        )
    }

    private var detail: String {
        Self.detail(
            operation: operation,
            files: appState.filesVM.files,
            flattenedConflictCount: flattenedCount
        )
    }

    // MARK: - The rules, stated as functions of what is on screen
    //
    // Static and given their inputs rather than reading `appState`, so the
    // three reasons Continue can be refused are testable without a view.

    static func unresolvedCount(in files: [GitFileStatus]) -> Int {
        files.filter(\.isConflict).count
    }

    /// Tracked files with unstaged content, which the sequencer operations
    /// refuse to continue over.
    ///
    /// Not a cosmetic check: `rebase`, `cherry-pick` and `revert` all put
    /// `--continue` through git's sequencer, which bails on *any* unstaged
    /// change — including one in a file the conflict never touched — and says
    /// "You must edit all merge conflicts and then mark them as resolved using
    /// git add" whether or not a conflict is what is actually in the way. So
    /// the button was offered in a state git would always refuse, under a
    /// message that sent the user looking for a conflict the Files panel was
    /// no longer showing. A merge continues with `git commit`, which has no
    /// such rule.
    static func unstagedBlockers(
        operation: GitService.InProgressOperation,
        files: [GitFileStatus]
    ) -> Int {
        guard operation != .merge else { return 0 }
        return files.filter { !$0.isConflict && !$0.hasNoIndexEntry && $0.isUnstaged }.count
    }

    /// Why Continue cannot run yet, or nil when it can.
    static func continueBlocker(
        operation: GitService.InProgressOperation,
        files: [GitFileStatus],
        flattenedConflictCount: Int
    ) -> String? {
        if unresolvedCount(in: files) > 0 { return "Resolve remaining conflicts first" }
        if flattenedConflictCount > 0 {
            return "These files still contain conflict markers. Restore the conflict, then resolve it."
        }
        if unstagedBlockers(operation: operation, files: files) > 0 {
            return "git refuses to continue with unstaged changes — stage or discard them first"
        }
        return nil
    }

    /// The subtitle after the operation name: the most specific true thing
    /// about why this banner is still on screen.
    static func detail(
        operation: GitService.InProgressOperation?,
        files: [GitFileStatus],
        flattenedConflictCount: Int
    ) -> String {
        let unresolved = unresolvedCount(in: files)
        if unresolved > 0 {
            return "· \(unresolved) file\(unresolved == 1 ? "" : "s") still conflicted"
        }
        if flattenedConflictCount > 0 {
            return flattenedConflictCount == 1
                ? "· 1 file still holds conflict markers"
                : "· \(flattenedConflictCount) files still hold conflict markers"
        }
        let unstaged = operation.map { unstagedBlockers(operation: $0, files: files) } ?? 0
        if unstaged > 0 {
            return "· \(unstaged) file\(unstaged == 1 ? "" : "s") with unstaged changes"
        }
        return "· all conflicts resolved"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(title)
                .scaledFont(12, weight: .semibold)
                .foregroundStyle(Color.textPrimary)
            Text(detail)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            if operation != nil {
                // Offered ahead of Abort: a flattened conflict is a state the
                // user cannot resolve, continue *or* recognise, and throwing
                // the whole rebase away is otherwise the only way out of it.
                if flattenedCount > 0 {
                    Button("Restore Conflicts") {
                        Task { await appState.restoreFlattenedConflicts() }
                    }
                    .help("Re-run the merge on these files so both sides come back and they can be resolved.")
                }
                Button("Abort", role: .destructive) {
                    Task { await appState.abortInProgressOperation() }
                }
                Button("Continue") {
                    Task { await appState.continueInProgressOperation() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(continueBlocker != nil)
                .help(continueBlocker ?? "git \(continueSubcommand)")
            } else if appState.stashApplyConflict != nil {
                // Only offered when we know which stash it was: the abort
                // restores that stash's files and nothing else, and we cannot
                // name them from a bare conflicted index.
                Button("Abort Stash Apply", role: .destructive) {
                    Task { await appState.abortStashApply() }
                }
                .help("Restore the files the stash touched. The stash itself is kept.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.14))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.orange.opacity(0.5)).frame(height: 0.5)
        }
    }

    private var title: String {
        if let operation { return "\(operation.displayName) in progress" }
        return appState.stashApplyConflict != nil
            ? "Stash apply stopped in conflict"
            : "Unresolved conflicts — not part of a merge or rebase"
    }

    private var continueSubcommand: String {
        switch operation {
        case .none: return ""
        case .merge:      return "commit --no-edit"
        case .rebase:     return "rebase --continue"
        case .cherryPick: return "cherry-pick --continue"
        case .revert:     return "revert --continue"
        }
    }
}
