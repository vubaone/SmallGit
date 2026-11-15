import SwiftUI

struct CommitDialog: View {

    typealias Mode = CommitScope.Mode

    @Bindable var appState: AppState

    @State private var message: String = ""
    @State private var amend: Bool = false
    @State private var mode: Mode = .staged
    @State private var includedPaths: Set<String> = []
    /// The tab `includedPaths` was last ticked for. Compared against, rather
    /// than counting mode changes: `primeOpeningScope` can move the tab
    /// itself, and that must not read as the user flipping the radio and
    /// re-tick everything the opening scope deliberately left out.
    @State private var primedMode: Mode?
    @State private var directoryAscending: Bool = true
    /// Rows highlighted for review, apart from the checkboxes: which files
    /// go into the commit and which ones to look at are different questions.
    @State private var selectedPaths: Set<String> = []
    /// Where a ⇧-click range starts: the last row clicked without ⇧.
    @State private var selectionAnchor: String?
    /// The sheet's window, for the Escape claim.
    @State private var hostWindow: ObjectIdentifier?
    /// Full commit messages pulled from the repo log on appear, for the
    /// "Recent Commits" reuse menu.
    @State private var recentCommits: [String] = []

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            modeBar
            Divider()
            fileTable
            Divider()
            messageSection
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 540)
        .background(Color.bgPanel)
        .onAppear {
            primeOpeningScope()
            message = appState.commitMessageDraft
        }
        .onChange(of: message) { _, new in appState.commitMessageDraft = new }
        .onChange(of: mode) { _, newMode in
            guard primedMode != newMode else { return }
            primeSelection()
        }
        // Staged while the dialog is open — Stage & Close in a compare opened
        // from here is how a reviewed file says "this one goes in". Left
        // unticked, the commit would take it straight back out of the index.
        .onChange(of: stagedPaths) { old, new in
            includedPaths.formUnion(new.subtracting(old))
        }
        .task { recentCommits = await appState.recentCommitMessages(limit: 10) }
        // Escape never closes this dialog: one stray press would throw away a
        // message that may have taken a while to write. The claim swallows it
        // here, and keeps the app-wide handler from closing the sheet when a
        // compare window opened from it is the one in front.
        .background(WindowFinder { window in
            let id = ObjectIdentifier(window)
            guard hostWindow != id else { return }
            appState.claimEscape(for: id) { true }
            hostWindow = id
        })
        .onDisappear {
            if let hostWindow { appState.releaseEscapeClaim(for: hostWindow) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(amend ? "Amend Last Commit" : "Commit local or staged changes")
                    .scaledFont(15, weight: .semibold)
                // Always laid out (even when valid) so the header height
                // stays constant — toggling visibility via opacity avoids the
                // jump the dialog had when the row appeared/disappeared.
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text("Enter a commit message describing (the reason for) the commit.")
                        .scaledFont(11)
                        .foregroundStyle(Color.textPrimary)
                }
                .opacity(trimmedMessage.isEmpty ? 1 : 0)
                .accessibilityHidden(!trimmedMessage.isEmpty)
            }
            Spacer()
            Image(systemName: "doc.on.doc")
                .foregroundStyle(Color.textSecondary)
                .help("Commit dialog")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Mode bar

    private var modeBar: some View {
        HStack(spacing: 16) {
            Picker("", selection: $mode) {
                Text("Staged Changes").tag(Mode.staged)
                Text("Local Changes").tag(Mode.local)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()

            Spacer()

            Button(compareButtonTitle) { openCompare(selectedFiles) }
                .disabled(selectedFiles.isEmpty)
                .help("Compare the selected files before committing, one tab each. ⌘-click or ⇧-click to select several.")

            Text(fileCountSummary)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentBlue)
                .help(fileCountTooltip)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - File table

    private var fileTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Name")
                    .scaledFont(11, weight: .medium)
                    .frame(width: 220, alignment: .leading)
                    .padding(.leading, 28)
                Divider().frame(height: 16)
                HStack(spacing: 4) {
                    Text("Directory")
                        .scaledFont(11, weight: .medium)
                    Image(systemName: directoryAscending ? "chevron.up" : "chevron.down")
                        .scaledFont(9)
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(.leading, 8)
                .onTapGesture { directoryAscending.toggle() }
                Spacer()
            }
            .padding(.vertical, 6)
            .background(Color.bgPanelHeader)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayedFiles) { file in
                        fileRow(file)
                        Divider().opacity(0.4)
                    }
                    if displayedFiles.isEmpty {
                        Text(emptyListLabel)
                            .scaledFont(11)
                            .foregroundStyle(Color.textDisabled)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: 220)
        }
    }

    private func fileRow(_ file: GitFileStatus) -> some View {
        HStack(spacing: 0) {
            Toggle(isOn: Binding(
                get: { includedPaths.contains(file.path) },
                set: { isOn in
                    if isOn { includedPaths.insert(file.path) }
                    else { includedPaths.remove(file.path) }
                }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.leading, 8)
                .frame(width: 28)

            HStack(spacing: 4) {
                // The split dot + hover tooltip carry the rename signal
                // here; the inline "← Old Name" is left to the roomier
                // Files panel so this narrow column keeps the full name.
                FileStatusDot(file: file, color: file.state.swatch, size: 7)
                Text(file.name)
                    .scaledFont(12, design: .monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 220 - 28, alignment: .leading)

            Divider().frame(height: 14)

            Text(file.relativeDirectory)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 8)

            Spacer()
        }
        .padding(.vertical, 4)
        .background(selectedPaths.contains(file.path) ? Color.accentBlue.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openCompare([file]) }
        // Simultaneous, so a plain click selects at once rather than after
        // waiting out the double-click interval.
        .simultaneousGesture(TapGesture().onEnded { click(file) })
        .contextMenu {
            let files = contextFiles(file)
            Button(files.count > 1 ? "Compare \(files.count) Files" : "Compare") {
                openCompare(files)
            }
        }
        .help(rowHelp(file))
    }

    private func click(_ file: GitFileStatus) {
        let flags = NSEvent.modifierFlags
        (selectedPaths, selectionAnchor) = Self.selection(
            afterClicking: file.path,
            in: displayedFiles.map(\.path),
            current: selectedPaths,
            anchor: selectionAnchor,
            command: flags.contains(.command),
            shift: flags.contains(.shift)
        )
    }

    /// The rows a click leaves selected, Finder-style: ⌘ toggles the row,
    /// ⇧ selects the run from the anchor to it (added to the selection when
    /// ⌘ is held too), and a plain click selects the row alone.
    static func selection(
        afterClicking path: String,
        in order: [String],
        current: Set<String>,
        anchor: String?,
        command: Bool,
        shift: Bool
    ) -> (selected: Set<String>, anchor: String?) {
        if shift, let to = order.firstIndex(of: path) {
            let from = anchor.flatMap { order.firstIndex(of: $0) } ?? to
            let run = Set(order[min(from, to)...max(from, to)])
            return (command ? current.union(run) : run, anchor ?? path)
        }
        if command {
            var next = current
            if next.remove(path) == nil { next.insert(path) }
            return (next, path)
        }
        return ([path], path)
    }

    /// Right-clicking inside the selection acts on all of it; anywhere else,
    /// on the row alone.
    private func contextFiles(_ file: GitFileStatus) -> [GitFileStatus] {
        selectedPaths.contains(file.path) ? selectedFiles : [file]
    }

    private func rowHelp(_ file: GitFileStatus) -> String {
        if let original = file.originalPath, file.state == .renamed || file.state == .copied {
            let verb = file.state == .copied ? "Copied" : "Renamed"
            return "\(verb) from \(original) — double-click to compare this file before committing"
        }
        return "Double-click to compare this file before committing; ⌘-click or ⇧-click to select several"
    }

    /// Open `file` in a compare view (external diff tool if configured,
    /// otherwise the built-in view) showing what the commit will record.
    ///
    /// A staged file goes in as the index holds it — `performCommit` never
    /// re-stages it, in either tab — so a file with one of three hunks
    /// staged commits that hunk alone, and HEAD against the index is the
    /// only honest preview. A file with nothing staged is staged whole on
    /// commit, so for it the working tree is what gets recorded. Conflicts
    /// keep the working-tree compare: their index holds merge stages, not a
    /// blob to diff against.
    ///
    /// Several files open as one tab group. Each is its own window rather
    /// than a sheet stacked on this one: reviewing a file is exactly when you
    /// want the commit dialog — and its message field — still visible next
    /// to the diff.
    private func openCompare(_ files: [GitFileStatus]) {
        Task {
            var builtIn: [(path: String, staged: Bool)] = []
            for file in files {
                let staged = file.isStaged && !file.isConflict
                let launched = staged
                    ? await appState.openExternalStagedDiff(file: file)
                    : await appState.openExternalDiff(path: file.path)
                if !launched { builtIn.append((file.path, staged)) }
            }
            CompareWindowPresenter.presentCommitPreviews(appState: appState, files: builtIn)
        }
    }

    // MARK: - Commit message

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Commit Message:")
                    .scaledFont(11, weight: .medium)
                Spacer()

                Menu {
                    Menu("Recent Messages") {
                        if appState.appConfig.recentCommitMessages.isEmpty {
                            Text("No recent messages yet")
                        } else {
                            ForEach(Array(appState.appConfig.recentCommitMessages.enumerated()), id: \.offset) { _, msg in
                                Button(menuLabel(msg)) { message = msg }
                            }
                        }
                    }
                    Menu("Recent Commits") {
                        if recentCommits.isEmpty {
                            Text("No commits in this repo")
                        } else {
                            ForEach(Array(recentCommits.enumerated()), id: \.offset) { _, fullMessage in
                                Button(menuLabel(fullMessage)) { message = fullMessage }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("History").scaledFont(11)
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 90)
                .help("Reuse a recent message or a commit's full message")
            }

            TextEditor(text: $message)
                .scaledFont(12, design: .monospaced)
                .frame(minHeight: 120)
                .padding(4)
                .background(Color.bgInput)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.borderColor, lineWidth: 0.5)
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Amend last commit", isOn: $amend)
                .toggleStyle(.checkbox)
                .scaledFont(11)

            HStack {
                Spacer()
                // No `.cancelAction`: that would bind Escape, which this
                // dialog refuses on purpose — see the claim in `body`.
                Button("Cancel") { dismiss() }

                Button("Commit") {
                    Task { await performCommit(thenPush: false) }
                }
                .disabled(!canCommit)
                .keyboardShortcut(.defaultAction)

                Button("Commit & Push") {
                    Task { await performCommit(thenPush: true) }
                }
                .disabled(!canCommit)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Derived state

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The rows this tab lists. Filtered by `isCommittable`, the same test
    /// `CommitScope` ticks by, so the two can't disagree about a row —
    /// an ignored path shown here and left unticked would be "unstaged"
    /// from an index it was never in.
    private var visibleFiles: [GitFileStatus] {
        switch mode {
        case .staged:
            return appState.filesVM.files.filter { $0.isCommittable && $0.isStaged }
        case .local:
            return appState.filesVM.files.filter(\.isCommittable)
        }
    }

    private var stagedPaths: Set<String> {
        Set(appState.filesVM.files.filter { $0.isCommittable && $0.isStaged }.map(\.path))
    }

    private var displayedFiles: [GitFileStatus] {
        visibleFiles.sorted { lhs, rhs in
            let l = lhs.relativeDirectory
            let r = rhs.relativeDirectory
            if l == r { return lhs.name < rhs.name }
            return directoryAscending ? l < r : l > r
        }
    }

    /// The selected rows still listed, in display order. Filtered rather
    /// than kept in step: a refresh or a tab switch can drop a row out from
    /// under the selection.
    private var selectedFiles: [GitFileStatus] {
        displayedFiles.filter { selectedPaths.contains($0.path) }
    }

    private var compareButtonTitle: String {
        selectedFiles.count > 1 ? "Compare \(selectedFiles.count) Files" : "Compare"
    }

    private var fileCountSummary: String {
        let included = visibleFiles.filter { includedPaths.contains($0.path) }
        let total = visibleFiles.count
        if total == 0 { return "no files" }
        let suffix = total == 1 ? "" : "s"
        if included.count == total {
            return "\(total) file\(suffix)"
        }
        return "\(included.count) of \(total) file\(suffix)"
    }

    private var fileCountTooltip: String {
        mode == .staged
            ? "Files currently staged for commit"
            : "All local changes (staged + unstaged)"
    }

    private var emptyListLabel: String {
        mode == .staged
            ? "Nothing staged — switch to Local Changes or stage files first."
            : "Working tree is clean."
    }

    private var canCommit: Bool {
        guard !trimmedMessage.isEmpty else { return false }
        if amend { return true }
        return !includedPaths.isEmpty
    }

    // MARK: - Selection priming

    /// Open on what the user asked for: the Files-panel selection if there
    /// is one, the index otherwise. See `CommitScope` for the rule.
    private func primeOpeningScope() {
        let scope = CommitScope.opening(
            files: appState.filesVM.files,
            selectedPaths: appState.filesVM.selectedPaths
        )
        mode = scope.mode
        primedMode = scope.mode
        includedPaths = scope.includedPaths
    }

    /// The user flipped the radio: everything visible in the newly chosen
    /// mode gets ticked. In staged mode that's the staged set; in local
    /// mode that's all changed files.
    private func primeSelection() {
        primedMode = mode
        includedPaths = Set(visibleFiles.map(\.path))
    }

    // MARK: - Commit flow

    private func performCommit(thenPush: Bool) async {
        let visible = visibleFiles
        // `affectedPaths`, not `path`: a rename is a dropped path and an
        // added one, and moving half of it leaves the index holding a
        // deletion whose matching add went into someone else's commit.
        let toStage = visible
            .filter { includedPaths.contains($0.path) && !$0.isStaged }
            .flatMap(\.affectedPaths)
        // Conflicts are excluded rather than unstaged: git reports their
        // merge stages in the index column, so an unticked conflict looks
        // like something to take back out — and `git reset` on one destroys
        // the conflict instead. `AppState.unstage` drops them too; this keeps
        // the dialog from asking for a no-op in the first place.
        let toUnstage = visible
            .filter { !includedPaths.contains($0.path) && $0.isStaged && !$0.isConflict }
            .flatMap(\.affectedPaths)

        if !toStage.isEmpty { await appState.stage(files: toStage) }
        if !toUnstage.isEmpty { await appState.unstage(files: toUnstage) }

        let (subject, body) = splitMessage(trimmedMessage)
        if thenPush {
            await appState.commitAndPush(subject: subject, body: body, amend: amend)
        } else {
            await appState.commit(subject: subject, body: body, amend: amend)
        }
        dismiss()
    }

    /// Single-line, length-capped label for a stored message/subject so the
    /// menu rows stay readable (multi-line bodies collapse to their subject).
    private func menuLabel(_ raw: String) -> String {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }

    private func splitMessage(_ raw: String) -> (String, String?) {
        guard let nl = raw.firstIndex(of: "\n") else { return (raw, nil) }
        let subject = String(raw[..<nl]).trimmingCharacters(in: .whitespaces)
        let bodyPart = raw[raw.index(after: nl)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (subject, bodyPart.isEmpty ? nil : bodyPart)
    }
}
