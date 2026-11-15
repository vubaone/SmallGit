import SwiftUI

/// The Changes panel's other half: a place to type a command.
///
/// Everything this app does is a git command, and an expert already knows
/// the one they want — this is for the times that saying it is faster than
/// finding it. It stands where the diff stands, and the switch that swaps
/// them sits beside the panel title in both.
struct TerminalPanel: View {
    @Bindable var appState: AppState
    @Bindable var viewModel: TerminalViewModel

    @FocusState private var inputFocused: Bool
    /// The same size the diff renders at, and the same ⌘+ / ⌘- that zooms
    /// it: this is monospaced content like any other in the app, and someone
    /// who sized the diff to be readable meant the terminal too.
    @Environment(\.monoFontSize) private var monoFontSize

    private static let bottomAnchor = "terminal-bottom"

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Terminal") {
                PanelModeSwitch(showsTerminal: true) { appState.showTerminal(false) }
            } trailing: {
                HStack(spacing: 10) {
                    if viewModel.isRunning {
                        Button("Stop") { viewModel.cancel() }
                            .buttonStyle(.plain)
                            .scaledFont(11)
                            .foregroundStyle(Color.diffDelText)
                            .keyboardShortcut(".", modifiers: .command)
                            .help("Stop the running command (⌘.)")
                    }
                    Button {
                        viewModel.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.textSecondary)
                    .help("Clear the transcript")
                    .disabled(viewModel.entries.isEmpty)
                }
            }

            transcript
            suggestionStrip
            inputRow
        }
        .background(Color.bgPanel)
        .onAppear { inputFocused = true }
        .onChange(of: viewModel.inputFocusRequest) { _, _ in inputFocused = true }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if viewModel.entries.isEmpty {
                        hint
                    }
                    ForEach(viewModel.entries) { entry in
                        entryView(entry)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.bgPanel)
            // Follow the output as it arrives. Keyed on the last entry's
            // line count as well as the entry count, since a single long
            // command grows without adding an entry.
            .onChange(of: viewModel.entries.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.entries.last?.lines.count ?? 0) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Type a command. It runs in the active repository.")
            Text("`cd` and `clear` are built in. Commands that need to ask "
                 + "something — an editor, a passphrase — have no terminal to "
                 + "ask on and will fail rather than wait.")
        }
        .scaledFont(11)
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func entryView(_ entry: TerminalEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(promptLabel(for: entry))
                    .font(.mono(size: monoFontSize).weight(.medium))
                    .foregroundStyle(Color.accentBlue)
                Text(entry.command)
                    .font(.mono(size: monoFontSize))
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
            }

            if !entry.lines.isEmpty {
                Text(entry.lines.joined(separator: "\n"))
                    .font(.mono(size: monoFontSize))
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let status = statusLabel(for: entry) {
                Text(status)
                    .font(.mono(size: max(9, monoFontSize - 2)))
                    .foregroundStyle(entry.failed || entry.wasCancelled
                                     ? Color.diffDelText
                                     : Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The prompt a command ran under, not the current one: a transcript
    /// that re-labels old commands with today's directory is a lie about
    /// where they ran.
    private func promptLabel(for entry: TerminalEntry) -> String {
        guard !entry.directory.isEmpty else { return "$" }
        return "\((entry.directory as NSString).lastPathComponent) $"
    }

    private func statusLabel(for entry: TerminalEntry) -> String? {
        if entry.wasCancelled { return "stopped" }
        if entry.isRunning { return "running…" }
        guard let code = entry.exitCode, code != 0 else { return nil }
        return "exit \(code)"
    }

    /// What Tab found when it could not finish on its own — a shell prints
    /// these under the prompt, and so does this, above the line they are
    /// about to complete.
    @ViewBuilder
    private var suggestionStrip: some View {
        if !viewModel.suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.suggestions, id: \.self) { candidate in
                        Text(candidate)
                            .font(.mono(size: max(9, monoFontSize - 1)))
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                            // Clicking one is faster than typing the rest of
                            // it, and costs nothing to offer.
                            .onTapGesture { viewModel.accept(candidate) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .background(Color.bgPanel)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.borderColor).frame(height: 0.5)
            }
        }
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(spacing: 6) {
            Text(viewModel.prompt)
                .font(.mono(size: monoFontSize).weight(.medium))
                .foregroundStyle(Color.accentBlue)

            TextField("", text: $viewModel.input)
                .accessibilityIdentifier("terminal.input")
                .textFieldStyle(.plain)
                .font(.mono(size: monoFontSize))
                .foregroundStyle(Color.textPrimary)
                .focused($inputFocused)
                .onSubmit { viewModel.submit() }
                // Shell muscle memory: the up arrow is how anyone who wants
                // this panel expects to reach the command they just ran.
                // Tab completes rather than moving focus: in a field that
                // takes shell commands, the shell's meaning wins.
                .onKeyPress(.tab) {
                    viewModel.completeInput()
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    viewModel.recallPrevious()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    viewModel.recallNext()
                    return .handled
                }

            if viewModel.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Where the typing happens, so it gets the room to look like it:
        // a line of text plus breathing space, growing with the font.
        .frame(minHeight: monoRowHeight(for: monoFontSize) + 16)
        .background(Color.bgInput)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.borderColor)
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { inputFocused = true }
    }
}

/// The switch that decides whether the panel shows the diff or the terminal.
///
/// Lives beside the panel title in both, so it reads as one control that
/// moved rather than two buttons that happen to look alike.
struct PanelModeSwitch: View {
    let showsTerminal: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: showsTerminal ? "doc.text" : "terminal")
                .scaledFont(11)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.textSecondary)
        .keyboardShortcut("t", modifiers: [.command, .control])
        .help(showsTerminal
              ? "Back to the diff (⌃⌘T)"
              : "Type git commands here instead (⌃⌘T)")
    }
}
