import SwiftUI

/// Bottom-right command journal. Each entry shows the action label, full
/// command, and live status dot. Selecting an entry reveals its detail
/// (stdout + stderr) in a disclosure below.
struct OutputView: View {
    @Bindable var output: OutputLog
    let openLink: (OutputLink) -> Void
    @State private var expandedIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Output") {
                Button {
                    output.clear()
                } label: {
                    Image(systemName: "trash")
                        .scaledFont(10)
                }
                .buttonStyle(.borderless)
                .help("Clear output")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(output.entries) { entry in
                            OutputRow(
                                entry: entry,
                                expanded: isExpanded(entry),
                                toggle: { toggle(entry.id) },
                                openLink: openLink
                            )
                            .id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: output.entries.count) { _, _ in
                    if let last = output.entries.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color.bgPanel)
    }

    private func toggle(_ id: UUID) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    /// Failed entries auto-expand so errors don't hide behind a row that
    /// the user would have to click. Manual toggle still wins — once
    /// expanded then collapsed by user, the explicit choice sticks.
    private func isExpanded(_ entry: OutputEntry) -> Bool {
        if expandedIDs.contains(entry.id) { return true }
        if entry.link != nil { return true }
        return entry.status == .failure
    }
}

private struct OutputRow: View {
    let entry: OutputEntry
    let expanded: Bool
    let toggle: () -> Void
    let openLink: (OutputLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(entry.status.color)
                        .frame(width: 6, height: 6)
                    // Fixed, not merely monospaced. The action label next to
                    // it has layout priority, so in a narrow panel SwiftUI
                    // took the width back out of the clock instead — and a
                    // timestamp has no spaces to wrap at, so `16:24:34` came
                    // apart into four stacked fragments and made the row four
                    // lines tall.
                    Text(timeString)
                        .foregroundStyle(Color.textDisabled)
                        .scaledFont(11, design: .monospaced)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    Text(entry.action)
                        .foregroundStyle(Color.textPrimary)
                        .scaledFont(11, weight: .medium)
                        // One line, and first claim on the width. A label
                        // holding a branch name is long enough to wrap, and
                        // SwiftUI breaks it at a hyphen — so a row about
                        // `assume-unchanged-view` split it across two lines
                        // and pushed everything after it down.
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Text(commandText)
                        .foregroundStyle(entry.command.isEmpty ? Color.textDisabled : Color.textSecondary)
                        .scaledFont(11, design: .monospaced)
                        .lineLimit(1)
                        .truncationMode(.head)
                        // The column that gives way when the panel is narrow:
                        // it is the one thing here that truncates without
                        // losing its meaning, and the tooltip has the rest.
                        .layoutPriority(-1)
                        .help(entry.command)
                    Spacer(minLength: 8)
                    // The finish mark. Without it a completed row looked
                    // identical to a running one apart from a 6pt dot, so a
                    // command that had already returned still read as pending.
                    if let duration = entry.duration {
                        Text(durationText(duration))
                            .foregroundStyle(Color.textDisabled)
                            .scaledFont(10, design: .monospaced)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    } else if entry.status == .running {
                        Text("running…")
                            .foregroundStyle(Color.textDisabled)
                            .scaledFont(10)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, !entry.detail.isEmpty || entry.link != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .scaledFont(11, design: .monospaced)
                            .foregroundStyle(Color.textSecondary)
                            .textSelection(.enabled)
                    }
                    if let link = entry.link {
                        Button {
                            openLink(link)
                        } label: {
                            Label(link.label, systemImage: "folder")
                                .scaledFont(11, weight: .medium)
                        }
                        .buttonStyle(.link)
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 4)
            }
        }
    }

    /// Truncation is `.head` above, which keeps the tail — the subcommand,
    /// its flags and what it names, the only part that differs between two
    /// rows of this panel.
    ///
    /// Every command here starts `git -C <repository>`, and that path is the
    /// longest thing in the line. Middle truncation spent the column on it
    /// and hid the operation: a push that deleted a branch read as
    /// `git -C /Users/lap…me-unchanged-view`, with `push origin --delete`
    /// cut out of the middle. The whole argv is on the tooltip, which is
    /// what copying one wants.
    private var commandText: String {
        if !entry.command.isEmpty { return entry.command }
        // While running there is nothing to show yet and the "running…" label
        // beside it already says so; a dash there would read as "no command",
        // which is a different thing. A finished entry with no command really
        // does have none — a guard that failed before anything ran — and the
        // dash keeps the column from collapsing.
        return entry.status == .running ? "" : "—"
    }

    /// Sub-second work is the common case and reporting it to the millisecond
    /// is noise; anything slow enough to notice gets a decimal.
    private func durationText(_ duration: TimeInterval) -> String {
        duration < 1
            ? String(format: "%.0f ms", duration * 1000)
            : String(format: "%.2f s", duration)
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: entry.timestamp)
    }
}
