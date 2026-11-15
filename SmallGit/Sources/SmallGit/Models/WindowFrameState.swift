import Foundation
import CoreGraphics

/// Where the main window was when it last closed, with enough about the
/// display it was on to put it back on *that* display next launch.
///
/// Frames are in AppKit's global screen coordinate space: origin at the
/// bottom-left of the primary display, y growing upwards. Secondary displays
/// therefore have negative or large offsets depending on their arrangement,
/// which is exactly what makes them distinguishable here.
struct WindowFrameState: Codable, Sendable, Equatable {
    var frame: CGRect
    /// `CGDirectDisplayID` of the screen the window was on, when known.
    /// Cheap and exact — but display IDs are not stable across reboots or
    /// re-plugging, so `screenFrame` backs it up.
    var displayID: UInt32?
    /// That screen's frame at save time. Identifies the same physical display
    /// geometrically when its ID has changed.
    var screenFrame: CGRect?

    init(frame: CGRect, displayID: UInt32? = nil, screenFrame: CGRect? = nil) {
        self.frame = frame
        self.displayID = displayID
        self.screenFrame = screenFrame
    }
}

/// A connected display reduced to what window placement needs. Exists so the
/// placement rules below are plain value-in/value-out and can be unit-tested
/// without real hardware or a running app.
struct ScreenInfo: Equatable, Sendable {
    let displayID: UInt32?
    /// Full bounds, including the menu bar and Dock.
    let frame: CGRect
    /// Bounds excluding the menu bar and Dock — what a window may occupy.
    let visibleFrame: CGRect

    init(displayID: UInt32?, frame: CGRect, visibleFrame: CGRect) {
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Decides where to reopen the main window. Split out from the AppKit glue so
/// the interesting cases — display unplugged, display rearranged, saved frame
/// larger than the screen it lands on — are testable.
enum WindowPlacement {

    /// Smallest window we will restore to. Matches `MainWindow`'s own
    /// `.frame(minWidth:minHeight:)`, so we never hand back a frame the view
    /// would immediately fight.
    static let minSize = CGSize(width: 1000, height: 640)

    /// Outcome of a placement attempt. The distinction matters to the caller:
    /// a `.fallback` means the display we wanted isn't there *yet* — external
    /// displays commonly register a few seconds after launch when waking or
    /// docking — so the caller keeps watching and corrects itself if it shows
    /// up, whereas `.restored` is final.
    enum Placement: Equatable {
        case restored(CGRect)
        case fallback(CGRect)

        var frame: CGRect {
            switch self {
            case .restored(let f), .fallback(let f): return f
            }
        }

        var isRestored: Bool {
            if case .restored = self { return true }
            return false
        }
    }

    /// Where to put the window, and whether that landed on the display it was
    /// saved on. `nil` when there is nothing sensible to place (no saved state,
    /// or no displays reported) — the caller then leaves SwiftUI's default
    /// placement alone and tries again later.
    ///
    /// `screens` is expected in `NSScreen.screens` order, i.e. primary first.
    static func plan(saved: WindowFrameState?, screens: [ScreenInfo]) -> Placement? {
        guard let saved, let primary = screens.first else { return nil }
        guard saved.frame.width > 0, saved.frame.height > 0 else { return nil }

        if let target = matchedScreen(for: saved, in: screens) {
            return .restored(clamp(saved.frame, to: target))
        }

        // The display we were on isn't here (laptop undocked, monitor asleep,
        // still enumerating at login). Restoring the saved origin would put the
        // window off-screen where the user can't reach it, so keep the *size*
        // they chose and centre it on the primary display for now.
        return .fallback(centered(size: saved.frame.size, on: primary))
    }

    /// The frame to apply, ignoring whether it reached the intended display.
    static func resolve(saved: WindowFrameState?, screens: [ScreenInfo]) -> CGRect? {
        plan(saved: saved, screens: screens)?.frame
    }

    /// Which connected display the saved frame belongs to, if any.
    ///
    /// Tried in order of confidence: exact display ID, then identical screen
    /// geometry (same display, new ID), then whichever screen the saved frame
    /// physically overlaps most (displays rearranged in System Settings).
    static func matchedScreen(
        for saved: WindowFrameState,
        in screens: [ScreenInfo]
    ) -> ScreenInfo? {
        if let id = saved.displayID,
           let hit = screens.first(where: { $0.displayID == id }) {
            return hit
        }
        if let savedScreen = saved.screenFrame,
           let hit = screens.first(where: { $0.frame == savedScreen }) {
            return hit
        }
        return screens
            .map { ($0, $0.frame.intersection(saved.frame)) }
            .filter { !$0.1.isNull && $0.1.width > 0 && $0.1.height > 0 }
            .max { areaOf($0.1) < areaOf($1.1) }
            .map(\.0)
    }

    /// Fit `frame` inside a screen's usable area: shrink it if it is wider or
    /// taller than the screen (a window saved on a 6K display reopening on a
    /// laptop), then slide it back inside if any edge hangs off.
    static func clamp(_ frame: CGRect, to screen: ScreenInfo) -> CGRect {
        let usable = screen.visibleFrame
        guard usable.width > 0, usable.height > 0 else { return frame }

        // Honour minSize, but never demand more than the screen can give.
        var size = frame.size
        size.width = min(max(size.width, min(minSize.width, usable.width)), usable.width)
        size.height = min(max(size.height, min(minSize.height, usable.height)), usable.height)

        var origin = frame.origin
        origin.x = min(max(origin.x, usable.minX), usable.maxX - size.width)
        origin.y = min(max(origin.y, usable.minY), usable.maxY - size.height)

        return CGRect(origin: origin, size: size)
    }

    /// `size` centred on a screen's usable area, clamped to fit.
    static func centered(size: CGSize, on screen: ScreenInfo) -> CGRect {
        let usable = screen.visibleFrame
        let fitted = clamp(
            CGRect(origin: usable.origin, size: size),
            to: screen
        ).size
        return CGRect(
            x: usable.midX - fitted.width / 2,
            y: usable.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private static func areaOf(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }
}
