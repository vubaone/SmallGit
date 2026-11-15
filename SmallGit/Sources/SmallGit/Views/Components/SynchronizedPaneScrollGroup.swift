import SwiftUI
import AppKit

/// Keeps any number of aligned code panes on the same horizontal and vertical
/// offset. Compare uses two members; Resolve Conflict uses Ours/Base/Theirs.
///
/// SwiftUI does not expose scroll offsets on macOS 14, so the group follows
/// AppKit's synchronized-scrolling recipe: observe each clip view, mirror the
/// leading pane's bounds synchronously, clamp to every target's own content,
/// and reflect the target so its scrollers update too.
@MainActor
final class SynchronizedPaneScrollGroup<Key: Hashable & Sendable>: ObservableObject {
    private var panes: [Key: NSScrollView] = [:]
    nonisolated(unsafe) private var observers: [Key: any NSObjectProtocol] = [:]
    private var isMirroring = false

    func register(_ scrollView: NSScrollView, as key: Key) {
        guard panes[key] !== scrollView else { return }
        panes[key] = scrollView

        if let previous = observers[key] {
            NotificationCenter.default.removeObserver(previous)
        }
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        observers[key] = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.mirror(from: key) }
        }
    }

    private func mirror(from sourceKey: Key) {
        guard !isMirroring, let source = panes[sourceKey] else { return }

        isMirroring = true
        defer { isMirroring = false }

        for (key, target) in panes where key != sourceKey {
            let wanted = clamp(source.contentView.bounds.origin, to: target)
            let current = target.contentView.bounds.origin
            guard abs(current.x - wanted.x) > 0.5
                    || abs(current.y - wanted.y) > 0.5
            else { continue }

            target.contentView.scroll(to: wanted)
            target.reflectScrolledClipView(target.contentView)
        }
    }

    private func clamp(_ origin: CGPoint, to scrollView: NSScrollView) -> CGPoint {
        guard let document = scrollView.documentView else { return origin }
        let visible = scrollView.contentView.bounds.size
        return CGPoint(
            x: min(max(origin.x, 0), max(0, document.frame.width - visible.width)),
            y: min(max(origin.y, 0), max(0, document.frame.height - visible.height))
        )
    }

    deinit {
        for observer in observers.values {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

/// Reports the backing `NSScrollView` of a SwiftUI `ScrollView` without
/// contributing anything to layout.
struct EnclosingScrollViewFinder: NSViewRepresentable {
    let onFound: (NSScrollView) -> Void

    func makeNSView(context: Context) -> ScrollViewAccessorView {
        let view = ScrollViewAccessorView()
        view.onFound = onFound
        return view
    }

    func updateNSView(_ nsView: ScrollViewAccessorView, context: Context) {
        nsView.onFound = onFound
        nsView.reportIfFound()
    }
}

final class ScrollViewAccessorView: NSView {
    var onFound: ((NSScrollView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportIfFound()
    }

    func reportIfFound() {
        if let scrollView = enclosingScrollView {
            onFound?(scrollView)
        }
    }
}
