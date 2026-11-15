import SwiftUI
import AppKit

/// Hosts a view as a *resizable* window-sheet.
///
/// SwiftUI's `.sheet` sizes itself to its content and then stays that size:
/// there is no edge to drag, so a list inside one is stuck with whatever
/// height the code guessed — which is never the right height for a
/// repository with ninety stashes in it. Attaching a real `NSWindow` to the
/// parent with `beginSheet` keeps the modal presentation and hands back
/// everything a window has: draggable edges and a minimum size it respects.
///
/// A window-modal sheet has no title bar, and therefore no close box, so the
/// hosted view is handed a `close` action to put on screen itself.
@MainActor
final class ModalWindowPresenter: NSObject, NSWindowDelegate {
    /// A parent window can only host one sheet at a time, so there is only
    /// ever one of these. Presenting again closes whatever is up first.
    private static var current: ModalWindowPresenter?

    private var window: NSWindow?
    private weak var parentWindow: NSWindow?
    private var onClose: (() -> Void)?

    static func present<Content: View>(
        title: String,
        size: CGSize,
        minSize: CGSize,
        appState: AppState,
        onClose: (() -> Void)? = nil,
        @ViewBuilder content: (@escaping () -> Void) -> Content
    ) {
        current?.close()
        let presenter = ModalWindowPresenter()
        presenter.onClose = onClose
        current = presenter
        presenter.open(
            title: title,
            size: size,
            minSize: minSize,
            appState: appState,
            content: content
        )
    }

    private func open<Content: View>(
        title: String,
        size: CGSize,
        minSize: CGSize,
        appState: AppState,
        @ViewBuilder content: (@escaping () -> Void) -> Content
    ) {
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let fitted = Self.fittedSize(
            requested: size,
            minimum: minSize,
            visible: (parent?.screen ?? NSScreen.main)?.visibleFrame.size
        )

        let window = EscapeClosingWindow(
            contentRect: NSRect(origin: .zero, size: fitted),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentMinSize = NSSize(width: minSize.width, height: minSize.height)
        window.shouldCloseOnEscape = { [appState] in
            appState.appConfig.escapeClosesSubwindows
        }
        window.closeOnEscape = { [weak self] in self?.close() }

        // Wrapped in AppZoom like every other window the app hosts: without
        // it this scene gets no zoom level and no whitespace setting, and
        // renders at 12pt however the rest of the app is set.
        let hosted = AppZoom(appState: appState) {
            content { [weak self] in self?.close() }
        }
        // Hosted inside a plain autoresizing container rather than straight
        // in as `contentView`: as the content view, NSHostingView's Auto
        // Layout constraints become the window's, and AppKit then derives the
        // minimum from SwiftUI's *ideal* size, discarding `contentMinSize`.
        // A table has no intrinsic height, so the window would be free to
        // collapse to a strip. See CompareWindowPresenter for the same note.
        let hosting = NSHostingView(rootView: hosted)
        let container = NSView(frame: NSRect(origin: .zero, size: fitted))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        window.delegate = self
        window.center()

        self.window = window
        self.parentWindow = parent

        if let parent {
            parent.beginSheet(window) { [weak self] _ in
                self?.finishClose()
            }
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The opening size, kept on the display. A dialog sized for a roomy
    /// screen has to yield on a small one rather than hang off the edge, and
    /// the minimum yields too when even that doesn't fit.
    nonisolated static func fittedSize(requested: CGSize, minimum: CGSize, visible: CGSize?) -> CGSize {
        guard let visible else { return requested }
        let width = min(max(min(requested.width, visible.width), min(minimum.width, visible.width)), visible.width)
        let height = min(max(min(requested.height, visible.height), min(minimum.height, visible.height)), visible.height)
        return CGSize(width: width, height: height)
    }

    private func close() {
        guard let window else { return }
        if let parent = window.sheetParent ?? parentWindow {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender.sheetParent != nil {
            close()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        finishClose()
    }

    private func finishClose() {
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        window.orderOut(nil)
        onClose?()
        onClose = nil
        if Self.current === self { Self.current = nil }
    }
}
