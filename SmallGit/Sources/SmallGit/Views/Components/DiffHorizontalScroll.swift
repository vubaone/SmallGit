import SwiftUI
import AppKit
import CoreText

/// How far a diff's text has been scrolled sideways. `nil` — the default —
/// keeps the old behaviour of cutting a long line off with an ellipsis.
private struct DiffHorizontalOffsetKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var diffHorizontalOffset: CGFloat? {
        get { self[DiffHorizontalOffsetKey.self] }
        set { self[DiffHorizontalOffsetKey.self] = newValue }
    }
}

/// Sideways scrolling for a hunk diff, shared by every column it draws.
///
/// The rows live in one vertical `ScrollView` so the two sides of a
/// side-by-side diff stay lined up, which leaves no room for a per-column
/// horizontal one: each column would drift on its own, the same way the two
/// panes used to drift vertically. Instead there is one offset, every
/// `DiffLineView` underneath slides its text by it, and the line-number
/// gutter stays put — so both sides move as one, and the numbers never
/// scroll out of sight.
///
/// The offset is held here rather than by the caller so a scroll redraws
/// only the rows, not the whole window that hosts them.
struct DiffHorizontalScroll<Content: View>: View {
    /// Every line any column can draw — the widest decides how far to go.
    let lines: [String]
    /// Side by side is 2, unified 1. Columns split the width evenly with a
    /// one-point divider between them, as the callers lay them out.
    var columns: Int = 1
    @ViewBuilder let content: Content

    @Environment(\.monoFontSize) private var monoFontSize
    @Environment(\.showWhitespace) private var showWhitespace
    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0

    private struct MeasureKey: Equatable {
        let lines: [String]
        let fontSize: CGFloat
        let showWhitespace: Bool
    }

    var body: some View {
        GeometryReader { geo in
            let count = CGFloat(max(1, columns))
            let colWidth = (geo.size.width - (count - 1)) / count
            let leading = DiffLineView.leadingWidth(fontSize: monoFontSize)
            let viewport = max(0, colWidth - leading)
            let maxOffset = max(0, textWidth - viewport)
            let current = min(offset, maxOffset)

            VStack(spacing: 0) {
                content
                    .environment(\.diffHorizontalOffset, current)
                    .background {
                        // Read from `offset` rather than `current`: several
                        // events can land before the next redraw hands over
                        // a fresh closure.
                        HorizontalScrollCatcher { dx in
                            offset = min(max(min(offset, maxOffset) - dx, 0), maxOffset)
                        }
                    }
                if maxOffset > 0 {
                    scrollBars(
                        colWidth: colWidth, leading: leading,
                        viewport: viewport, maxOffset: maxOffset
                    )
                }
            }
        }
        .onChange(
            of: MeasureKey(lines: lines, fontSize: monoFontSize, showWhitespace: showWhitespace),
            initial: true
        ) { _, key in
            textWidth = DiffTextWidth.widest(
                of: key.lines, fontSize: key.fontSize, showWhitespace: key.showWhitespace
            )
        }
    }

    /// One bar under each column's text, all bound to the same offset, so
    /// dragging either moves both sides.
    private func scrollBars(
        colWidth: CGFloat, leading: CGFloat, viewport: CGFloat, maxOffset: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<max(1, columns), id: \.self) { column in
                if column > 0 {
                    Color.borderColor.frame(width: 1)
                }
                HStack(spacing: 0) {
                    Color.bgPanelHeader.frame(width: leading)
                    DiffHorizontalScrollBar(
                        offset: $offset, maxOffset: maxOffset, viewport: viewport
                    )
                    .padding(.horizontal, 4)
                }
                .frame(width: colWidth)
            }
        }
        .frame(height: 11)
        .background(Color.bgPanel)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.borderColor).frame(height: 0.5)
        }
    }
}

/// How wide a hunk diff's text runs, for `DiffHorizontalScroll`.
enum DiffTextWidth {
    /// The width of the widest line's text cell, padding included.
    ///
    /// Measured with CoreText, the engine `Text` draws with, so Vietnamese
    /// diacritics and CJK come out at the width they are drawn at. Not every
    /// line needs measuring: no UTF-16 unit draws wider than two cells, so
    /// once a line has been measured wider than that bound for the rest,
    /// none of them can beat it — and the lines are tried longest first.
    static func widest(of lines: [String], fontSize: CGFloat, showWhitespace: Bool) -> CGFloat {
        let tabExtra = WhitespaceGlyph.tabWidth - 1
        let candidates = lines
            .map { line in
                (line, line.utf16.count + line.utf16.reduce(0) { $0 + ($1 == 9 ? tabExtra : 0) })
            }
            .sorted { $0.1 > $1.1 }

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let cell = ("0" as NSString).size(withAttributes: [.font: font]).width
        var widest: CGFloat = 0
        for (line, units) in candidates {
            if CGFloat(units) * cell * 2 < widest { break }
            // Tabs expanded the way the whitespace overlay draws them.
            let text = CompareTextLayout.revealed(line).text
            let ctLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: font])
            )
            widest = max(widest, CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)))
        }
        guard widest > 0 else { return 0 }
        // The text cell's padding on both sides, and the pilcrow's cell past
        // the end when whitespace is shown.
        return ceil(widest) + 12 + (showWhitespace ? fontSize : 0)
    }
}

/// A thin scroller: drag the thumb, or click the track to jump there.
private struct DiffHorizontalScrollBar: View {
    @Binding var offset: CGFloat
    let maxOffset: CGFloat
    let viewport: CGFloat

    @State private var dragStart: CGFloat?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let track = geo.size.width
            let thumb = min(track, max(28, track * viewport / (viewport + maxOffset)))
            let travel = max(1, track - thumb)
            let current = min(offset, maxOffset)

            ZStack(alignment: .leading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { point in
                        offset = clamp((point.x - thumb / 2) / travel * maxOffset)
                    }
                Capsule()
                    .fill(Color.textSecondary.opacity(hovering || dragStart != nil ? 0.6 : 0.35))
                    .frame(width: thumb, height: 6)
                    .offset(x: travel * current / maxOffset)
                    // Global, because the thumb moves under the pointer: a
                    // local translation would be measured against a view
                    // that has already slid along.
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? current
                                dragStart = start
                                offset = clamp(start + value.translation.width / travel * maxOffset)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
            .frame(maxHeight: .infinity)
            .onHover { hovering = $0 }
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), maxOffset)
    }
}

/// Hands sideways scroll-wheel and trackpad movement over the diff to
/// `onScroll`.
///
/// The event still goes on to the vertical `ScrollView` underneath, so a
/// diagonal swipe moves both ways at once. A vertical-only scroll view does
/// nothing with the horizontal part, and a mouse wheel turned with shift
/// held arrives from AppKit already as horizontal movement.
private struct HorizontalScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> HorizontalScrollCatcherView {
        let view = HorizontalScrollCatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: HorizontalScrollCatcherView, context: Context) {
        nsView.onScroll = onScroll
    }
}

final class HorizontalScrollCatcherView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    nonisolated(unsafe) private var monitor: Any?

    /// A wheel reports whole lines rather than points; this is how far one
    /// notch goes.
    private static let lineStep: CGFloat = 12

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated { self.handle(event) }
            return event
        }
    }

    /// Decoration only: every click belongs to the rows above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func handle(_ event: NSEvent) {
        guard event.window === window, !isHiddenOrHasHiddenAncestor else { return }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        var dx = event.scrollingDeltaX
        if !event.hasPreciseScrollingDeltas { dx *= Self.lineStep }
        guard dx != 0 else { return }
        onScroll?(dx)
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
