import AppKit

/// AppKit sheet/window used for SwiftUI-hosted secondary views that need
/// Escape-to-close without relying on SwiftUI's key-equivalent routing.
final class EscapeClosingWindow: NSWindow {
    var shouldCloseOnEscape: () -> Bool = { false }
    /// Asked before Escape is read as "close this window".
    ///
    /// The content gets first refusal because this window takes Escape ahead
    /// of the responder chain — by monitor and by `sendEvent` — which is the
    /// only way to be sure SwiftUI hasn't swallowed it. That reach is also
    /// what made a view unable to keep the key for itself: a block open for
    /// typing, or a find bar, never saw the press that closed the window out
    /// from under it. A view that has something of its own to unwind answers
    /// true here, and the window stays where it is.
    var escapeHandledByContent: () -> Bool = { false }
    var closeOnEscape: (() -> Void)?
    nonisolated(unsafe) private var escapeMonitor: Any?

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        installEscapeMonitor()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, isEscape(event) {
            if escapeHandledByContent() { return }
            if shouldCloseOnEscape() {
                closeFromEscape()
                return
            }
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if isEscape(event) {
            if escapeHandledByContent() { return }
            if shouldCloseOnEscape() {
                closeFromEscape()
                return
            }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if escapeHandledByContent() { return }
        if shouldCloseOnEscape() {
            closeFromEscape()
            return
        }
        super.cancelOperation(sender)
    }

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated {
                self.handleEscapeEvent(event)
            }
            return handled ? nil : event
        }
    }

    private func handleEscapeEvent(_ event: NSEvent) -> Bool {
        guard isEscape(event), isFrontmostEscapeWindow else { return false }
        // Swallowed either way: the content took it, or it closed the window.
        // Letting a consumed press carry on to the responder chain would run
        // both steps on one keystroke.
        if escapeHandledByContent() { return true }
        guard shouldCloseOnEscape() else { return false }
        closeFromEscape()
        return true
    }

    private func closeFromEscape() {
        if let closeOnEscape {
            closeOnEscape()
        } else {
            performClose(nil)
        }
    }

    private func isEscape(_ event: NSEvent) -> Bool {
        event.isEscapeKey
    }

    private var isFrontmostEscapeWindow: Bool {
        for window in NSApp.orderedWindows {
            if window === self || window.attachedSheet === self {
                return true
            }
            if window is EscapeClosingWindow || window.attachedSheet is EscapeClosingWindow {
                return false
            }
        }
        return isKeyWindow || sheetParent?.isKeyWindow == true
    }

    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }
}

extension NSEvent {
    var isEscapeKey: Bool {
        let blockedModifiers = modifierFlags.intersection([.command, .control, .option])
        return blockedModifiers.isEmpty && (keyCode == 53 || charactersIgnoringModifiers == "\u{1B}")
    }
}
