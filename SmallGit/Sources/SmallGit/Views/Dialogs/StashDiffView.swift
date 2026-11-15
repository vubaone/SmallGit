import SwiftUI
import AppKit

/// What a stash entry holds, laid out the way the Log window lays out a
/// commit: the files on the left, the diff of whichever one is picked on
/// the right.
///
/// The Branches panel's "Show Diff" used to drop every file of the stash
/// into the main Diff panel as one unbroken run of hunks, which is
/// unreadable past the second file and gives no way to ask "what did this
/// stash do to *this* file". Nothing is selected to begin with, so the
/// window still opens on the whole entry; picking a row narrows it, and
/// "All Files" goes back.
///
/// Read-only. Apply, Pop and Drop stay where they already are — the
/// Branches panel's context menu and the Stashes window — because this is
/// a window for looking, and the stash is still there when it closes.
struct StashDiffView: View {
    @Bindable var appState: AppState
    let stash: GitStash
    var onClose: (() -> Void)?

    @State private var files: [StashFile] = []
    @State private var selectedID: StashFile.ID?
    @State private var loading = true
    /// The diff pane's own view model rather than the main window's: this
    /// window is a second view of the repository, and hijacking the panel
    /// behind it would leave a stash on screen there long after the window
    /// had been closed.
    @State private var diffVM: DiffViewModel
    /// Opening width of the file list, fixed once the window has a size,
    /// and whatever the divider has been dragged to after that.
    @State private var filesWidth: CGFloat?
    /// Width the current divider drag began at. Nil when nothing is being
    /// dragged — a drag reports its total translation, not a delta.
    @State private var dragStartWidth: CGFloat?

    init(appState: AppState, stash: GitStash, onClose: (() -> Void)? = nil) {
        self.appState = appState
        self.stash = stash
        self.onClose = onClose
        let vm = DiffViewModel(coordinator: appState.coordinator, git: appState.git)
        vm.diffMode = appState.appConfig.diffMode
        vm.compactMode = appState.appConfig.diffCompactMode
        _diffVM = State(initialValue: vm)
    }

    private var selectedFile: StashFile? {
        files.first { $0.id == selectedID }
    }

    /// Share of the window the file list opens at. The rest goes to the
    /// diff, which halves it — so side-by-side opens as 20/40/40, the
    /// reading proportion for a list of short file names beside two columns
    /// of code.
    private static let filesShare: CGFloat = 0.2
    private static let filesMinWidth: CGFloat = 140
    private static let diffMinWidth: CGFloat = 380

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            panes
            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgPanel)
        .task {
            guard let repo = appState.activeRepo?.path else {
                loading = false
                return
            }
            files = (try? await appState.git.stashFiles(repoPath: repo, index: stash.index)) ?? []
            // Before the diff, not after: the list is the quicker of the two
            // and there is no reason to hold it back behind the patch.
            loading = false
            await diffVM.loadStashDiff(index: stash.index)
        }
        // Row picked, or cleared by "All Files" — either way the diff pane
        // follows, since that is the whole point of the list.
        .onChange(of: selectedID) { _, _ in
            Task { await diffVM.loadStashDiff(index: stash.index, path: selectedFile?.path) }
        }
        .onExitCommand {
            guard appState.appConfig.escapeClosesSubwindows else { return }
            close()
        }
    }

    /// File list and diff, split at `filesShare` to begin with.
    ///
    /// An explicit width and a divider of our own rather than `HSplitView`,
    /// because `HSplitView` has no way to open at a proportion. Measured: it
    /// ignores `idealWidth` on its children and hands each of them half of
    /// whatever is left over, so a file list asked to open at a fifth of the
    /// window opened at a half of it however the frames were written.
    private var panes: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let width = filesWidth ?? total * Self.filesShare
            HStack(spacing: 0) {
                filesPane
                    .frame(width: clamped(width, total: total))
                paneDivider(total: total)
                DiffView(
                    appState: appState,
                    viewModel: diffVM,
                    showsTerminalSwitch: false,
                    allowsStaging: false
                )
                .frame(maxWidth: .infinity)
            }
            .frame(width: total, height: geo.size.height)
            // Latched on the first layout rather than recomputed: as a live
            // proportion, resizing the window would shove the divider back
            // to a fifth and undo wherever it had been dragged to.
            .onAppear {
                if filesWidth == nil, total > 0 { filesWidth = total * Self.filesShare }
            }
        }
    }

    /// Keeps the list wide enough to read a file name in and the diff wide
    /// enough to be a diff, whatever the window is doing.
    private func clamped(_ width: CGFloat, total: CGFloat) -> CGFloat {
        let upper = max(Self.filesMinWidth, total - Self.diffMinWidth)
        return min(max(width, Self.filesMinWidth), upper)
    }

    private func paneDivider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.borderColor)
            .frame(width: 1)
            // The grab area is wider than the line: a 1pt target is one the
            // pointer has to be aimed at rather than moved to.
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let start = dragStartWidth ?? filesWidth ?? total * Self.filesShare
                                if dragStartWidth == nil { dragStartWidth = start }
                                filesWidth = clamped(start + value.translation.width, total: total)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .foregroundStyle(Color.accentBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text(stash.message)
                    .scaledFont(13, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("stash@{\(stash.index)}")
                        .scaledFont(11, design: .monospaced)
                        .foregroundStyle(Color.accentBlue)
                    if let branch = stash.branch {
                        Text(branch)
                            .scaledFont(11)
                            .foregroundStyle(Color.textSecondary)
                    }
                    if let date = stash.date {
                        Text(DateFormatters.absolute.string(from: date))
                            .scaledFont(11)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bgPanelHeader)
    }

    // MARK: - Files

    private var filesPane: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Files") {
                HStack(spacing: 8) {
                    if !files.isEmpty {
                        Text("\(files.count)")
                            .scaledFont(10)
                            .foregroundStyle(Color.textSecondary)
                    }
                    Button("All Files") { selectedID = nil }
                        .buttonStyle(.link)
                        .scaledFont(10)
                        .disabled(selectedID == nil)
                        .help("Show every file in the stash as one diff")
                }
            }
            if loading {
                placeholder("Loading…")
            } else if files.isEmpty {
                placeholder("This stash is empty")
            } else {
                Table(of: StashFile.self, selection: $selectedID) {
                    TableColumn("Name") { file in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(file.status.state.swatch)
                                .frame(width: 8, height: 8)
                            Text(file.name)
                                .scaledFont(12)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .help(helpText(for: file))
                    }
                    TableColumn("State") { file in
                        Text(file.status.state.rawValue)
                            .scaledFont(10)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .width(44)
                } rows: {
                    ForEach(files) { file in
                        TableRow(file)
                            .contextMenu { fileMenu(file) }
                    }
                }
                .background {
                    TableDoubleClickBridge { rowIndex in
                        guard rowIndex >= 0, rowIndex < files.count else { return }
                        openCompare(files[rowIndex])
                    }
                }
            }
        }
        .background(Color.bgPanel)
    }

    private func helpText(for file: StashFile) -> String {
        file.wasUntracked
            ? "\(file.path)\nUntracked when the stash was made"
            : file.path
    }

    @ViewBuilder
    private func fileMenu(_ file: StashFile) -> some View {
        Button("Compare…") { openCompare(file) }
        Divider()
        Button("Copy Name") { appState.copyToPasteboard(file.name) }
        Button("Copy Relative Path") { appState.copyToPasteboard(file.path) }
    }

    /// The stashed version of one file against what it was stashed on top
    /// of — the configured external diff tool where there is one, the
    /// built-in compare window otherwise, which is the rule the Log
    /// window's Files pane follows.
    private func openCompare(_ file: StashFile) {
        selectedID = file.id
        Task {
            guard let repo = appState.activeRepo?.path else { return }
            // The revision differs per row: a file that was untracked when
            // the stash was made lives in the entry's third parent, not in
            // the entry. Resolved to a SHA so the compare keeps pointing at
            // this stash even if another one is dropped meanwhile.
            guard let hash = await appState.git.resolveRevision(
                repoPath: repo, revision: file.revision
            ) else { return }
            let commit = GitCommit(
                hash: hash,
                shortHash: String(hash.prefix(7)),
                subject: "stash@{\(stash.index)}: \(stash.message)",
                authorName: "",
                authorEmail: "",
                date: stash.date ?? Date(),
                refs: ""
            )
            if await appState.openExternalCommitDiff(commit: commit, path: file.path) { return }
            CompareWindowPresenter.presentCommitCompare(
                appState: appState, commit: commit, path: file.path
            )
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.plaintext")
                .scaledFont(22, weight: .light)
                .foregroundStyle(Color.textDisabled)
            Text(text)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(selectedFile.map { "Showing \($0.path)" } ?? "Showing every file in the stash")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Close") { close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bgPanelHeader)
    }

    private func close() {
        onClose?()
    }
}
