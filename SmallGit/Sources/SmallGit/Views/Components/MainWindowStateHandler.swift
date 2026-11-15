import SwiftUI
import AppKit

/// Attaches window persistence to the main window:
///
/// - restores the frame it had when it last closed, on the display it was on
///   (see `WindowPlacement` for the multi-display rules),
/// - re-saves it as the user moves or resizes,
/// - quits the app when the window's close button is used, if
///   `AppConfig.quitsOnMainWindowClose` is set.
///
/// Implemented as a zero-size backing view rather than an `NSWindowDelegate`
/// so we never displace SwiftUI's own delegate — everything hangs off
/// notifications for the one window we're attached to.
struct MainWindowStateHandler: NSViewRepresentable {
    @Bindable var appState: AppState

    func makeNSView(context: Context) -> NSView {
        let view = MainWindowCaptureView()
        view.onWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.appState = appState
        if let window = nsView.window {
            context.coordinator.attach(window: window)
        } else {
            // Config loading can complete before the view is in a window;
            // re-check so the restore isn't dropped on the floor.
            context.coordinator.attemptRestore()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    /// AppKit persists the frame under this name in `UserDefaults`.
    static let frameAutosaveName = "SmallGitMainWindow"

    @MainActor
    final class Coordinator {
        var appState: AppState
        private weak var window: NSWindow?
        // `nonisolated(unsafe)` so `deinit` can unregister — same pattern as
        // EscapeDismissHandler's event monitor. Only ever touched on the main
        // actor plus the final deinit, which runs after the last use.
        nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
        private var saveTask: Task<Void, Never>?
        /// Restoration is best-effort and may need more than one attempt:
        /// `ui-state.json` loads asynchronously during `bootstrap()`, and
        /// external displays often register seconds after launch (waking from
        /// sleep, docking, logging in). We keep trying until the window is on
        /// the display it was saved on.
        private var restorePending = true
        /// Set as soon as the user moves or resizes the window themselves.
        /// Stops any further restore attempt — correcting the position after
        /// the user has taken charge of it would be worse than being wrong.
        private var userTookOver = false
        /// True while we are applying a restored frame, so the `didMove` it
        /// provokes isn't mistaken for the user moving the window.
        private var isApplyingFrame = false
        /// The frame we want the window to keep until the user takes over.
        /// Re-applied whenever something other than the user moves the window.
        private var restoreTarget: CGRect?
        /// How many more times we will put the window back before giving up.
        private var correctionsRemaining = 5
        /// Guards against `NSApp.terminate` being kicked off twice when the
        /// close notification arrives during an already-running quit.
        private var isQuitting = false
        /// Only a window the user actually saw counts as "the main window" for
        /// quit-on-close. SwiftUI can stand up and tear down a window during
        /// launch; treating that teardown as the user clicking the close button
        /// made the app quit by itself moments after starting.
        private var hasBecomeVisible = false

        init(appState: AppState) {
            self.appState = appState
        }

        func attach(window: NSWindow) {
            if self.window !== window {
                teardown()
                self.window = window
                // A different window object means the restore starts over.
                // SwiftUI can swap the window during startup; `teardown()`
                // cancels the hold that was defending the old one, and carrying
                // "already restored" state across left the replacement wherever
                // SwiftUI put it. That is what made restoring work only
                // sometimes.
                restorePending = true
                userTookOver = false
                restoreTarget = nil
                correctionsRemaining = 5
                // Frame autosave is set as a belt-and-braces measure only.
                // On its own it does not survive: SwiftUI's WindowGroup applies
                // its own default placement (centred on the primary display)
                // afterwards and wins every time — measured, not assumed. The
                // authoritative restore is our own, from ui-state.json,
                // defended by `windowFrameChanged`.
                window.setFrameAutosaveName(MainWindowStateHandler.frameAutosaveName)
                observe(window)
            }
            attemptRestore()
        }

        // MARK: - Restore

        /// Apply the saved frame if we can. Safe to call repeatedly — it does
        /// nothing once the window is on the display it was saved on, or once
        /// the user has moved it themselves.
        ///
        /// Called on attach, on every SwiftUI update (which covers
        /// `bootstrap()` finishing its config load), and whenever the display
        /// arrangement changes.
        func attemptRestore() {
            guard restorePending, !userTookOver, let window else { return }
            // No saved frame *yet* may just mean config hasn't loaded. Stay
            // pending so a later call can still place the window.
            guard let placement = WindowPlacement.plan(
                saved: appState.uiState.mainWindowFrame,
                screens: NSScreen.screens.map(ScreenInfo.init)
            ) else {
                // Nothing saved (first run). Still needs to settle, otherwise
                // the user's own moves would never be recorded.
                return
            }

            restoreTarget = placement.frame
            isApplyingFrame = true
            window.setFrame(placement.frame, display: true)
            isApplyingFrame = false

            // A `.fallback` leaves the request open, so we still correct
            // ourselves if the intended display shows up later.
            if placement.isRestored { restorePending = false }
        }

        // MARK: - Track

        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default

            // Dragging emits a stream of didMove; the debounce in
            // scheduleSave collapses it into a single write.
            observers.append(center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowFrameChanged() }
            })

            // A live resize only ever starts from the user dragging a window
            // edge — AppKit never enters resize tracking on its own — so this
            // is the one unambiguous "the user is taking charge" signal we get
            // for a resize, and it arrives *before* the frame changes.
            //
            // It needs its own notification because neither of the others can
            // stand in for it:
            //
            // - didMove is not posted for a frame change that also alters the
            //   size — AppKit collapses that into didResize alone, whatever the
            //   origin does. So no resize, from any edge, ever produced a
            //   didMove for `windowFrameChanged` to catch the mouse on.
            // - didEndLiveResize arrives only once the drag is over, so the
            //   button is already up by then and the `pressedMouseButtons` test
            //   in `windowFrameChanged` read every resize as SwiftUI's
            //   placement — putting the window straight back to its old size.
            observers.append(center.addObserver(
                forName: NSWindow.willStartLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.userTookOverWindow() }
            })

            // Resizing emits a stream of didResize; the debounce in
            // scheduleSave collapses it into a single write, exactly as it does
            // for didMove. Watching didResize rather than only didEndLiveResize
            // also covers the resizes that are never "live": the green zoom
            // button posts didResize on its own, so maximising the window used
            // to go unrecorded and reopen at the old, smaller size.
            observers.append(center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowFrameChanged() }
            })

            // Moving to another display is exactly the state most worth not
            // losing, and it happens rarely — so write it out at once instead
            // of waiting for the debounce. Without this, dragging to a second
            // monitor and immediately killing the app loses the new position
            // and it reopens on the old display.
            observers.append(center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveImmediately() }
            })

            // Becoming key is the first moment the window is genuinely on
            // screen and SwiftUI has stopped sizing it from its content.
            // Restoring before this races that sizing: our origin would stick
            // but the size and display got overwritten, landing the window back
            // on the previous screen.
            observers.append(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hasBecomeVisible = true
                    self?.attemptRestore()
                }
            })

            observers.append(center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowWillClose() }
            })

            // An external display arriving (or leaving) may finally let us put
            // the window where it was saved.
            observers.append(center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.attemptRestore() }
            })
        }

        /// The window's frame changed. Decide whether that was the user or
        /// something else, and act accordingly.
        ///
        /// This is event-driven rather than timed on purpose. SwiftUI's
        /// WindowGroup applies its own placement — centred on the primary
        /// display — at a moment nobody can predict: it follows the app
        /// finishing its launch work, which on a large repository can be twenty
        /// seconds in. Every timer-based attempt to "wait until SwiftUI is
        /// done" failed for whichever launch happened to be slower than the
        /// timeout.
        ///
        /// A held mouse button is the discriminator for *moves*: dragging a
        /// window by its titlebar always has one down, and SwiftUI's placement
        /// never does. It is not sufficient for resizes — those are handled by
        /// the `willStartLiveResize` observer above, for the reasons set out
        /// there. So we defend the restored frame indefinitely and step aside
        /// the moment the user physically grabs the window.
        private func windowFrameChanged() {
            guard !isApplyingFrame, let window else { return }
            if window.isVisible { hasBecomeVisible = true }

            let isUserDrag = NSEvent.pressedMouseButtons != 0
            if isUserDrag {
                userTookOverWindow()
            }

            // While still defending the restored frame, a move with no button
            // held is SwiftUI's placement. Put the window back — and don't save,
            // since the frame we just overrode was never the user's.
            //
            // Bounded so we can't fight forever: SwiftUI places the window once,
            // and giving up after a few corrections keeps us out of the way of
            // window managers like Rectangle or Magnet, which move windows from
            // a keyboard shortcut and so look identical to SwiftUI here.
            if !isUserDrag, let target = restoreTarget, window.frame != target {
                isApplyingFrame = true
                window.setFrame(target, display: true)
                isApplyingFrame = false
                correctionsRemaining -= 1
                if correctionsRemaining <= 0 { restoreTarget = nil }
                return
            }

            // Nothing may be recorded until the initial restore has resolved.
            // `ui-state.json` loads asynchronously, so early on there is no
            // target to compare against — and saving SwiftUI's startup placement
            // in that gap overwrites the very frame we are about to restore,
            // losing the display the user left the window on.
            guard userTookOver || !restorePending else { return }

            // Otherwise persist it. Note this does *not* depend on detecting the
            // mouse: once we are no longer defending a restored frame, any move
            // or resize is saved however it was made, so a keyboard-driven or
            // scripted move is recorded just the same.
            scheduleSave()
        }

        /// The user has taken charge of the window. Stop trying to restore it,
        /// stop defending the frame we restored, and record whatever they do
        /// from here on — putting the window back after this point would be
        /// worse than having placed it wrong in the first place.
        private func userTookOverWindow() {
            userTookOver = true
            restorePending = false
            restoreTarget = nil
        }

        /// Persist the current frame after a short quiet period. Debounced so a
        /// window drag costs one JSON write instead of hundreds. Kept short:
        /// anything still pending is lost if the process is killed rather than
        /// quit.
        private func scheduleSave() {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                guard let self, let state = self.currentFrameState() else { return }
                await self.appState.persistMainWindowFrame(state)
            }
        }

        /// Write the frame out synchronously, cancelling any pending debounce.
        /// Synchronous on purpose — see `AppState.persistMainWindowFrameNow`:
        /// an async write here is lost if the process is killed right after the
        /// window is dragged to another display, which is the case this whole
        /// path exists to handle.
        private func saveImmediately() {
            // Skip only while we're still defending a restored frame, since the
            // screen change would then be SwiftUI's placement rather than the
            // user's move. Deliberately does not require detecting the mouse: a
            // fast drag across a display boundary can deliver the screen-change
            // notification before the first `didMove`.
            guard !isApplyingFrame,
                  restoreTarget == nil || userTookOver,
                  userTookOver || !restorePending else { return }
            saveTask?.cancel()
            guard let state = currentFrameState() else { return }
            appState.persistMainWindowFrameNow(state)
        }

        private func currentFrameState() -> WindowFrameState? {
            guard let window else { return nil }

            // Two states whose frame must not be recorded, because neither is
            // a windowed frame we could sensibly restore:
            //
            // - miniaturized: the window sits off-screen in the Dock,
            // - full screen: the frame is the entire display, so restoring it
            //   as a normal window would cover the menu bar and look broken.
            //   macOS tracks full-screen state itself, so keeping the last
            //   windowed frame is both correct and what the user expects on
            //   leaving full screen.
            //
            // A *zoomed* (maximized) window is explicitly fine to save: it's a
            // deliberate size, and skipping it — as an earlier `isZoomed`
            // check did — silently dropped every save for anyone working
            // maximized, stranding them on whichever display they last used
            // at a smaller size.
            guard !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen) else { return nil }

            let screen = window.screen
            return WindowFrameState(
                frame: window.frame,
                displayID: screen?.displayID,
                screenFrame: screen?.frame
            )
        }

        // MARK: - Close

        private func windowWillClose() {
            saveTask?.cancel()
            let state = currentFrameState()
            // Quit only for a window the user actually had in front of them —
            // never for one SwiftUI discards while starting up.
            let shouldQuit = appState.appConfig.quitsOnMainWindowClose && hasBecomeVisible

            guard !isQuitting else { return }
            if shouldQuit { isQuitting = true }

            // Save before terminating, not alongside it: `NSApp.terminate`
            // can tear the process down before an in-flight actor write
            // lands, which would silently lose the final frame.
            Task { [appState] in
                if let state {
                    await appState.persistMainWindowFrame(state)
                }
                if shouldQuit {
                    NSApp.terminate(nil)
                }
            }
        }

        private func teardown() {
            saveTask?.cancel()
            saveTask = nil
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

/// Reports the hosting window once the view is in the hierarchy.
private final class MainWindowCaptureView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindow?(window)
        }
    }
}

extension ScreenInfo {
    init(_ screen: NSScreen) {
        self.init(
            displayID: screen.displayID,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }
}

extension NSScreen {
    /// The `CGDirectDisplayID` AppKit stashes in `deviceDescription`. Exact
    /// while the display stays plugged in, but not stable across reboots —
    /// `WindowPlacement` falls back to geometry when it stops matching.
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
}
