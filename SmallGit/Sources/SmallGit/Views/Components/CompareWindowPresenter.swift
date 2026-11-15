import SwiftUI
import AppKit

/// Shared handle between a compare window and the view inside it.
///
/// "Are there unsaved edits?" is a question only the view can answer, and
/// the window has to ask it at the one moment it is about to throw that
/// view away — synchronously, inside `windowShouldClose`. A binding cannot
/// carry that: the window is AppKit and the answer is needed as a return
/// value, not on the next render.
@MainActor
final class UnsavedEditsGuard {
    var hasUnsavedEdits = false
    /// Shown in the alert, so the prompt names the file being abandoned.
    var fileName = ""
    /// Writes the buffer to disk. Supplied by the view.
    var save: (() async -> Void)?
}

/// Hosts compare views in their own top-level windows.
///
/// Deliberately *not* a sheet. Comparing a file is a reading task that runs
/// alongside the repository rather than blocking it, so the window here is an
/// ordinary one: the main window stays usable underneath it, it can be pushed
/// onto a second display, and several files can be open at once. A sheet is
/// window-modal and singleton by construction, so it could do none of that.
///
/// Windows are keyed by `id`. Asking for a file that is already open raises
/// its existing window instead of stacking a second copy on top of it.
@MainActor
final class CompareWindowPresenter: NSObject, NSWindowDelegate {

    /// Every compare window currently on screen, keyed by the caller's id.
    /// This is also the ownership root — the presenter holds its window, this
    /// holds the presenter, and `windowWillClose` drops both.
    private static var open: [String: CompareWindowPresenter] = [:]

    /// Bumped per window opened so a second compare doesn't land exactly on
    /// top of the first, leaving no edge to grab. Wraps, so a long session
    /// can't walk windows off the bottom of the display.
    private static var cascade = 0
    private static let cascadeLimit = 6
    private static let cascadeStep: CGFloat = 28

    private let id: String
    private var window: NSWindow?
    private var unsavedEdits: UnsavedEditsGuard?

    private init(id: String) {
        self.id = id
    }

    /// Show `content` in its own window, or bring the window already open for
    /// `id` to the front.
    ///
    /// `content` is handed the action that closes its window: a top-level
    /// window is not a presentation, so SwiftUI has no `\.dismiss` to fill in
    /// and the view has to be given one explicitly.
    @discardableResult
    static func present<Content: View>(
        id: String,
        title: String,
        minSize: CGSize,
        escapeCloses: @escaping () -> Bool,
        unsavedEdits: UnsavedEditsGuard? = nil,
        @ViewBuilder content: (@escaping () -> Void) -> Content
    ) -> NSWindow {
        if let existing = open[id]?.window {
            existing.makeKeyAndOrderFront(nil)
            return existing
        }

        let presenter = CompareWindowPresenter(id: id)
        let contentRect = contentRectForNewWindow(minSize: minSize)
        let window = EscapeClosingWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // `open` keeps the window alive for as long as it is on screen.
        // Without this AppKit would *also* release it on close, leaving the
        // dictionary entry (dropped a moment later in windowWillClose)
        // pointing at a dead object.
        window.isReleasedWhenClosed = false
        // Keep compares out of the main window's tab bar. macOS would
        // otherwise merge them into it, which is precisely the "stuck on top
        // of the app" behaviour this window exists to avoid.
        window.tabbingMode = .disallowed
        window.title = title
        window.contentMinSize = minSize
        window.delegate = presenter
        window.shouldCloseOnEscape = escapeCloses
        window.closeOnEscape = { [weak window] in window?.performClose(nil) }
        // The hosting view goes inside a plain autoresizing container rather
        // than straight in as `contentView`.
        //
        // As the content view, NSHostingView's Auto Layout constraints become
        // the window's, and AppKit then derives the window's minimum from
        // SwiftUI's *ideal* size — silently discarding the `contentMinSize`
        // set just above. Measured: `window.minSize` came back as (0, 112)
        // instead of (700, 512). The compare's diff area is a `GeometryReader`
        // with no intrinsic height, so that ideal size is just the header plus
        // the action bar, and the window was free to collapse to a strip with
        // no diff in it at all. Routing through a container that translates
        // its autoresizing mask severs that constraint chain, and the minimum
        // is honoured again.
        let hosting = NSHostingView(
            rootView: content { [weak window] in window?.performClose(nil) }
        )
        let container = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container

        presenter.window = window
        presenter.unsavedEdits = unsavedEdits
        open[id] = presenter
        // No `NSApp.activate` alongside this: a compare is only ever opened
        // from a double-click or menu item inside the app, so the app is
        // already frontmost and the call is a no-op that merely makes the
        // presenter untestable (it hangs an xctest process, whose activation
        // policy is not an app's).
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Where to put a newly opened compare.
    ///
    /// A compare is a wall of monospaced text in two columns, so the useful
    /// size is "as much of the display as you can spare" rather than a polite
    /// dialog size — the old 1100x720 sheet truncated long lines on any real
    /// source file. Inset a little so it still reads as a window with a
    /// desktop behind it, and cascaded so consecutive opens stay separable.
    private static func contentRectForNewWindow(minSize: CGSize) -> NSRect {
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: minSize)
        }

        // Never demand more than the display can give: on a small screen the
        // minimum has to yield rather than push the window off the edge.
        let width = min(max(visible.width * 0.92, min(minSize.width, visible.width)), visible.width)
        let height = min(max(visible.height * 0.92, min(minSize.height, visible.height)), visible.height)

        let offset = CGFloat(cascade % cascadeLimit) * cascadeStep
        cascade += 1

        // Cascade down-and-right from centred, then clamp so the last window
        // of a run can't hang off the screen.
        let x = min(max(visible.midX - width / 2 + offset, visible.minX), visible.maxX - width)
        let y = min(max(visible.midY - height / 2 - offset, visible.minY), visible.maxY - height)

        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Every route out of a compare window goes through `performClose`
    /// — the in-view Close button, Escape, and the red traffic light — so
    /// this one hook covers all three.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let edits = unsavedEdits, edits.hasUnsavedEdits else { return true }

        let alert = NSAlert()
        alert.messageText = "Save changes to \(edits.fileName)?"
        alert.informativeText = "Your edits will be lost if you don't save them."
        // NSAlert stacks buttons right to left, so this reads
        // [Don't Save] [Cancel] [Save] with Save as the default — the order
        // every other document-based Mac app closes with.
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Saving is async, so the close cannot be answered with `true`
            // here. Let this attempt fail and close the window once the
            // write has finished — `close()` rather than `performClose`, so
            // it doesn't come back through this method.
            Task { @MainActor in
                await edits.save?()
                sender.close()
            }
            return false
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        Self.open[id] = nil
    }
}

// MARK: - The app's two compare windows

extension CompareWindowPresenter {

    /// Opens the HEAD ↔ working-tree compare for `path`.
    ///
    /// A function rather than something each caller assembles, because the
    /// window's id, title, minimum size and zoom wrapper all have to agree
    /// between the three places that open it — the Files panel, the commit
    /// dialog, and anywhere else that grows one later. A mismatched id in
    /// particular is invisible until it opens a second window for a file that
    /// was already on screen.
    /// Window identity for a file compare. Same file, same window — which is
    /// what makes a second open raise the existing one rather than stack a
    /// duplicate on top of it.
    /// Window identity for a file compare. Keyed on the repository as well
    /// as the path: `src/main.swift` in a submodule and in its parent are
    /// two different files, and both must be able to be open at once.
    static func fileCompareID(path: String, repoPath: String? = nil) -> String {
        "compare:\(repoPath ?? ""):\(path)"
    }

    /// Window identity for a commit compare. Keyed on the commit *and* the
    /// path: the same file at two revisions is two different comparisons and
    /// has to be able to sit on screen at once.
    static func commitCompareID(commitHash: String, path: String) -> String {
        "commit-compare:\(commitHash):\(path)"
    }

    /// Window identity for a HEAD-vs-index compare. Its own id rather than
    /// `fileCompareID`: the working-tree compare of the same file is a
    /// different comparison and can sit next to it.
    static func stagedCompareID(path: String, repoPath: String) -> String {
        "staged-compare:\(repoPath):\(path)"
    }

    @discardableResult
    static func presentFileCompare(
        appState: AppState,
        path: String,
        repoPath: String? = nil,
        onSaved: (() async -> Void)? = nil
    ) -> NSWindow {
        // Created out here rather than inside the view: the window needs it
        // at close time, which is exactly when the view is going away.
        let unsavedEdits = UnsavedEditsGuard()
        unsavedEdits.fileName = (path as NSString).lastPathComponent
        let scope = repoPath.map { " in \(($0 as NSString).lastPathComponent)" } ?? ""
        let window = present(
            id: fileCompareID(path: path, repoPath: repoPath),
            title: "Compare — \((path as NSString).lastPathComponent)\(scope)",
            minSize: CGSize(width: 700, height: 480),
            escapeCloses: { appState.appConfig.escapeClosesSubwindows },
            unsavedEdits: unsavedEdits
        ) { close in
            AppZoom(appState: appState) {
                FileCompareView(
                    appState: appState,
                    path: path,
                    unsavedEdits: unsavedEdits,
                    repoPathOverride: repoPath,
                    onSaved: onSaved,
                    onClose: close
                )
            }
            .preferredColorScheme(appState.appConfig.appearance.colorScheme)
        }
        // A compact filename reads much better across a row of tabs; the
        // full path remains available as the tab tooltip and in the compare
        // view's own header.
        window.tab.title = (path as NSString).lastPathComponent
        window.tab.toolTip = path
        return window
    }

    /// Opens all paths and explicitly joins their windows into one native
    /// macOS tab group. Each tab remains a real compare window, so its editor
    /// state and unsaved-changes prompt stay isolated to that file.
    static func presentFileCompares(
        appState: AppState,
        paths: [String],
        repoPath: String? = nil,
        onSaved: (() async -> Void)? = nil
    ) {
        var seen = Set<String>()
        let uniquePaths = paths.filter { seen.insert($0).inserted }
        groupAsTabs(uniquePaths.map { path in
            presentFileCompare(
                appState: appState,
                path: path,
                repoPath: repoPath,
                onSaved: onSaved
            )
        })
    }

    /// Opens what a commit would record for each file — HEAD against the
    /// index where `staged`, the working-tree compare otherwise — as one
    /// tab group, so a final review of several files is one window to page
    /// through rather than a pile of them.
    static func presentCommitPreviews(
        appState: AppState,
        files: [(path: String, staged: Bool)]
    ) {
        groupAsTabs(files.map { file in
            file.staged
                ? presentStagedCompare(appState: appState, path: file.path)
                : presentFileCompare(appState: appState, path: file.path)
        }.compactMap { $0 })
    }

    /// Opens each of `paths` as it stood at `commit` against its parent, as
    /// one tab group — the Log window's multi-selection counterpart of
    /// `presentFileCompares`.
    static func presentCommitCompares(
        appState: AppState,
        commit: GitCommit,
        paths: [String]
    ) {
        var seen = Set<String>()
        groupAsTabs(paths.filter { seen.insert($0).inserted }.map { path in
            presentCommitCompare(appState: appState, commit: commit, path: path)
        })
    }

    /// Joins `windows` into one native tab group, the first one selected.
    private static func groupAsTabs(_ windows: [NSWindow]) {
        guard let firstWindow = windows.first else { return }
        for window in windows.dropFirst() {
            guard window !== firstWindow else { continue }
            if let group = firstWindow.tabGroup {
                if !group.windows.contains(where: { $0 === window }) {
                    group.addWindow(window)
                }
            } else {
                // Automatic tabbing stays disabled so compare windows never
                // attach to the main app window; this explicit operation is
                // what creates a group for a multi-selection.
                firstWindow.addTabbedWindow(window, ordered: .above)
            }
        }

        firstWindow.tabGroup?.selectedWindow = firstWindow
        firstWindow.makeKeyAndOrderFront(nil)
    }

    /// Window identity for a stash. Keyed on the repository as well as the
    /// index, because `stash@{0}` means a different entry in every one.
    static func stashID(repoPath: String, index: Int) -> String {
        "stash:\(repoPath):\(index)"
    }

    /// Opens the files-and-diff view of one stash entry.
    ///
    /// A window rather than a sheet, for the reason the rest of this file
    /// gives: reading what is in a stash runs alongside the repository, and
    /// the main window stays usable underneath.
    static func presentStash(appState: AppState, stash: GitStash) {
        present(
            id: stashID(repoPath: appState.activeRepo?.path ?? "", index: stash.index),
            title: "Stash @{\(stash.index)} — \(stash.message)",
            minSize: CGSize(width: 900, height: 560),
            escapeCloses: { appState.appConfig.escapeClosesSubwindows }
        ) { close in
            AppZoom(appState: appState) {
                StashDiffView(appState: appState, stash: stash, onClose: close)
            }
            .preferredColorScheme(appState.appConfig.appearance.colorScheme)
        }
    }

    /// Opens the read-only compare of `path` in HEAD against the index —
    /// what a commit made now would record for it.
    ///
    /// A window already open for the file is closed and opened afresh
    /// rather than raised: it is a snapshot of the index, and the index is
    /// exactly what the user changes between two looks at it.
    @discardableResult
    static func presentStagedCompare(appState: AppState, path: String) -> NSWindow? {
        guard let repoPath = appState.activeRepo?.path else { return nil }
        let id = stagedCompareID(path: path, repoPath: repoPath)
        open[id]?.window?.close()
        let window = present(
            id: id,
            title: "Compare — \((path as NSString).lastPathComponent) (HEAD vs Index)",
            minSize: CGSize(width: 820, height: 560),
            escapeCloses: { appState.appConfig.escapeClosesSubwindows }
        ) { close in
            AppZoom(appState: appState) {
                CommitFileCompareView(
                    appState: appState,
                    source: .staged,
                    path: path,
                    onClose: close
                )
            }
            .preferredColorScheme(appState.appConfig.appearance.colorScheme)
        }
        window.tab.title = (path as NSString).lastPathComponent
        window.tab.toolTip = "\(path) (HEAD vs Index)"
        return window
    }

    /// Opens the read-only compare of `path` as it stood at `commit` against
    /// its parent.
    @discardableResult
    static func presentCommitCompare(
        appState: AppState,
        commit: GitCommit,
        path: String,
        repoPath: String? = nil
    ) -> NSWindow {
        present(
            id: commitCompareID(commitHash: commit.hash, path: path),
            title: "Compare — \((path as NSString).lastPathComponent) @ \(commit.shortHash)",
            minSize: CGSize(width: 820, height: 560),
            escapeCloses: { appState.appConfig.escapeClosesSubwindows }
        ) { close in
            AppZoom(appState: appState) {
                CommitFileCompareView(
                    appState: appState,
                    source: .commit(commit),
                    path: path,
                    repoPathOverride: repoPath,
                    onClose: close
                )
            }
            .preferredColorScheme(appState.appConfig.appearance.colorScheme)
        }
    }
}
