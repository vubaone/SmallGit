import SwiftUI

/// ⌘F search bar for the compare and conflict windows.
///
/// Sits under the header rather than floating over the text, so it never
/// covers the thing being searched for — the usual complaint about overlay
/// find bars in a two-column diff, where the hit can land behind the panel.
struct FindBar: View {
    @Bindable var state: TextFindState
    /// Owned by the host view so ⌘F can move focus here from anywhere in the
    /// window, including from a text field in another pane.
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)

            TextField("Find", text: $state.query)
                .textFieldStyle(.plain)
                .scaledFont(12)
                .focused($isFocused)
                // Return / Shift-Return step through hits without leaving the
                // field, which is how every find bar behaves.
                .onSubmit {
                    if NSEvent.modifierFlags.contains(.shift) {
                        state.previous()
                    } else {
                        state.next()
                    }
                }
                .frame(minWidth: 160, maxWidth: 320)

            if let summary = state.summary {
                Text(summary)
                    .scaledFont(11)
                    .foregroundStyle(state.matches.isEmpty ? Color.orange : Color.textSecondary)
                    .monospacedDigit()
                    // Fixed width so stepping from "9 of 12" to "10 of 12"
                    // doesn't shuffle the buttons beside it.
                    .frame(minWidth: 72, alignment: .leading)
            }

            Toggle("Aa", isOn: $state.caseSensitive)
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Match case")

            Button { state.previous() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(state.matches.isEmpty)
                .help("Previous match (⇧⌘G)")

            Button { state.next() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(state.matches.isEmpty)
                .help("Next match (⌘G)")

            Spacer(minLength: 0)

            Button("Done") { state.dismiss() }
                .controlSize(.small)
                .help("Close the find bar (Escape)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.bgPanelHeader)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.borderColor).frame(height: 0.5)
        }
    }
}

extension View {
    /// Wires ⌘F, ⌘G and ⇧⌘G for `state`.
    ///
    /// Hidden zero-size buttons rather than a key-event monitor: menu-style
    /// shortcuts route through the responder chain, so they keep working when
    /// focus is in a text field and stop working when the window is not key —
    /// both of which a global monitor gets wrong.
    /// `enabled: false` stands these down so the key equivalents fall
    /// through to whatever has focus — an editable text view brings its own
    /// find-and-replace bar, and it is the one that can act on what is being
    /// typed into it.
    func findBarShortcuts(
        _ state: TextFindState,
        focus: FocusState<Bool>.Binding,
        enabled: Bool = true
    ) -> some View {
        background {
            Group {
                Button("") {
                    state.isPresented = true
                    // Re-focusing on a second ⌘F is deliberate: it selects the
                    // existing query so typing replaces it, which is what the
                    // shortcut does everywhere else.
                    focus.wrappedValue = true
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("") { state.next() }
                    .keyboardShortcut("g", modifiers: .command)

                Button("") { state.previous() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .disabled(!enabled)
        }
    }
}
