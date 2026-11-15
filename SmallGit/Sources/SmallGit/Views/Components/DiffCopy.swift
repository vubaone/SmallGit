import SwiftUI
import AppKit

extension DiffLineSelection {
    /// The three click gestures, resolved from the modifier keys held at
    /// click time: plain selects one row, ⌘ toggles, ⇧ extends from the
    /// anchor along `lines`.
    ///
    /// Read from `NSEvent` rather than taken as a parameter because
    /// SwiftUI's `onTapGesture` does not report which modifiers were held.
    mutating func click(_ line: DiffLine, within lines: [DiffLine]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            toggle(line)
        } else if flags.contains(.shift) {
            extend(to: line, within: lines)
        } else {
            selectOnly(line)
        }
    }
}

/// ⌘C for a diff-row selection, with nothing on screen to press.
///
/// Diff rows are one `Text` each, and SwiftUI scopes text selection to a
/// single one — so no drag can select *characters* across rows. Whole rows
/// are selected instead, and this, the toolbar button and the row menu are
/// the three ways they leave the view.
///
/// The keystroke is handed back whenever the window has a text field in
/// hand. A SwiftUI `keyboardShortcut` outranks the responder chain, so
/// without this, ⌘C in the file filter or the find bar would copy diff rows
/// out from under someone who was typing. Checked when the key is pressed
/// rather than on every render: first responder is AppKit state, and a view
/// body has no way to observe it changing.
struct DiffCopyShortcut: View {
    /// Whether there is a selection to copy at all.
    let isEnabled: Bool
    let copy: () -> Void

    var body: some View {
        Button("Copy Selection") {
            guard !forwardedToTextEditor() else { return }
            copy()
        }
        .keyboardShortcut("c", modifiers: .command)
        .disabled(!isEnabled)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .frame(width: 0, height: 0)
    }

    /// Passes ⌘C on to the field being typed in, if there is one. `true`
    /// when the keystroke belonged to somebody else.
    ///
    /// Editable responders only. A selectable — but not editable — text view
    /// answers `copy:` too, and forwarding to one would have handed the
    /// keystroke to a view with nothing selected and copied nothing at all,
    /// which is the opposite of what this guard is for.
    private func forwardedToTextEditor() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        let editing: Bool
        switch responder {
        case let text as NSTextView:  editing = text.isEditable
        case let field as NSTextField: editing = field.isEditable
        default:                       editing = false
        }
        guard editing else { return false }
        return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
    }
}

/// Copy actions for one row of a diff.
///
/// The whole menu for the read-only compare windows; the top of the main
/// Diff panel's menu, which carries the staging commands underneath.
struct DiffRowCopyMenu: View {
    let line: DiffLine?
    let selection: DiffLineSelection
    /// Every row of the diff in the order it is drawn — what a multi-row
    /// copy is cut from, and the order it comes out in.
    let lines: [DiffLine]
    let appState: AppState

    var body: some View {
        if selection.count > 1 {
            Button("Copy Selection (\(selection.count) lines)") {
                appState.copyToPasteboard(selection.text(of: lines))
            }
            Divider()
        }
        Button("Copy Line") {
            if let line { appState.copyToPasteboard(line.content) }
        }
        .disabled(line == nil || line?.type == .empty)
    }
}

/// Click-to-select plus the copy menu, for one row of a read-only diff.
///
/// The main Diff panel wires these itself — its rows also double-click to
/// stage and carry the staging menu. The compare windows have neither, so
/// selecting and copying is the whole of what a row does there.
struct DiffRowSelection: ViewModifier {
    let line: DiffLine
    @Binding var selection: DiffLineSelection
    let lines: [DiffLine]
    let appState: AppState

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { selection.click(line, within: lines) }
            .contextMenu {
                DiffRowCopyMenu(
                    line: line, selection: selection, lines: lines, appState: appState
                )
            }
    }
}

/// Drag across rows to select them.
///
/// Attached to the stack that lays the rows out, not to each row: a drag is
/// one gesture over the whole column, and a row only knows about itself.
/// Every diff row is pinned to the same height, which is what turns the
/// drag's Y offsets back into row indices without measuring anything.
struct DiffDragSelection: ViewModifier {
    @Binding var selection: DiffLineSelection
    let rowHeight: CGFloat
    /// The lines drawn across a range of row indices, in the column the drag
    /// began in — `startX` says which, for a side-by-side layout. One column
    /// at a time: a selection running across the divider would interleave
    /// the two sides line by line on the pasteboard.
    let lines: (ClosedRange<Int>, CGFloat) -> [DiffLine]

    func body(content: Content) -> some View {
        content.gesture(
            // Past a click, so a plain click still lands on the row under it
            // and selects that one row.
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    guard rowHeight > 0 else { return }
                    let a = max(0, Int(value.startLocation.y / rowHeight))
                    let b = max(0, Int(value.location.y / rowHeight))
                    selection.select(lines(min(a, b)...max(a, b), value.startLocation.x))
                }
        )
    }
}

/// Toolbar button for the rows a diff has highlighted. Shown only while
/// something is selected — it is the visible half of a command the row menu
/// and ⌘C also offer, and an always-present disabled button would say the
/// diff had a copy affordance that did nothing.
struct DiffCopyButton: View {
    let count: Int
    let copy: () -> Void

    var body: some View {
        if count > 0 {
            Divider().frame(height: 16)
            Button(action: copy) {
                HStack(spacing: 3) {
                    Image(systemName: "doc.on.doc")
                    Text("\(count)")
                        .scaledFont(10)
                }
            }
            .buttonStyle(.borderless)
            .help("Copy the \(count) selected line\(count == 1 ? "" : "s") (⌘C)")
        }
    }
}
