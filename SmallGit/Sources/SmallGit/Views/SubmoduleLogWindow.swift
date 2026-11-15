import SwiftUI
import AppKit

/// A submodule's log, in a window of its own.
///
/// Laid out like the Log window — history on the left, files in the middle,
/// diff below — but driven by a `SubmoduleSession` rather than by whatever
/// repository the main window has open. That separation is the point:
/// looking into B leaves A exactly as it was, and a commit made here is
/// made here, not in a dialog that appears over A.
struct SubmoduleLogWindow: View {
    @Bindable var appState: AppState
    @State private var session: SubmoduleSession?
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                EmptyPanelState(
                    icon: "shippingbox",
                    title: "No submodule open",
                    message: "Double-click a submodule in the Files panel to see its history here."
                )
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Color.bgApp)
        // Rebuild whenever a different submodule is asked for, and reload
        // when the same one is asked for again — the parent may have moved
        // its pointer since.
        .task(id: appState.submoduleLogTarget) {
            guard let target = appState.submoduleLogTarget else { return }
            if session?.id != target.id {
                session = SubmoduleSession(
                    parentPath: target.parentPath,
                    path: target.path,
                    git: appState.git,
                    output: appState.output
                )
            }
            await session?.load()
        }
    }

    private func content(_ session: SubmoduleSession) -> some View {
        // A plain stack, not `safeAreaInset`: the splits are NSSplitView
        // underneath, which lays out over an inset rather than under it —
        // the header ended up covering the top of the log.
        VStack(spacing: 0) {
            header(session)
            VSplitView {
                HSplitView {
                    nodeList(session)
                        .frame(minWidth: 280, idealWidth: 340)
                    filesPane(session)
                        .frame(minWidth: 300)
                }
                .frame(minHeight: 220)

                DiffView(
                    appState: appState,
                    viewModel: session.diffVM,
                    showsTerminalSwitch: false,
                    allowsStaging: false
                )
                .frame(minHeight: 200)
            }
            .frame(maxHeight: .infinity)
            footer(session)
        }
    }

    // MARK: - Header

    private func header(_ session: SubmoduleSession) -> some View {
        HStack(spacing: 8) {
            Text(session.name).font(.headline)
            if let branch = session.branch {
                pill(branch, color: .accentBlue)
            } else {
                // Usual for a submodule, and worth saying: a commit made
                // here lands on no branch unless one is checked out.
                pill("detached HEAD", color: .textSecondary)
            }
            Text(session.path)
                .scaledFont(11, design: .monospaced)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text("in \((session.parentPath as NSString).lastPathComponent)")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bgPanelHeader)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.borderColor).frame(height: 0.5)
        }
    }

    private func pill(_ label: String, color: Color) -> some View {
        Text(label)
            .scaledFont(9, weight: .medium)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.6), lineWidth: 0.5))
            .fixedSize()
    }

    // MARK: - History

    private func nodeList(_ session: SubmoduleSession) -> some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Journal") {
                Text("\(session.commits.count) commits")
                    .scaledFont(10)
                    .foregroundStyle(Color.textSecondary)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Same graph the main Journal draws — the session holds a
                    // `JournalViewModel` of its own, so the lanes, dots and
                    // the dashed working-tree connector all come from the
                    // components that draw them there rather than from a
                    // second, flatter idea of what a log looks like.
                    let lanes = session.journal.graphLayout.maxLanes
                    let graphWidth = CommitGraphCell.columnWidth(lanes: lanes)

                    if session.hasUncommittedWork {
                        row(selected: isUncommittedSelected(session)) {
                            WorkingTreeGraphCell(totalLanes: lanes)
                                .frame(width: graphWidth, alignment: .leading)
                            HStack(spacing: JournalRowLayout.contentSpacing) {
                                Text("Uncommitted changes")
                                    .scaledFont(12, weight: .medium)
                                Text("\(session.files.count) file\(session.files.count == 1 ? "" : "s")")
                                    .scaledFont(10)
                                    .foregroundStyle(Color.textSecondary)
                                Spacer(minLength: 0)
                            }
                        }
                        .onTapGesture { select(.uncommitted, in: session) }
                    }

                    ForEach(Array(session.commits.enumerated()), id: \.element.id) { idx, commit in
                        row(selected: isSelected(commit, in: session)) {
                            Group {
                                if let graphRow = session.journal.graphRow(for: commit) {
                                    CommitGraphCell(
                                        row: graphRow,
                                        totalLanes: lanes,
                                        dotOverride: nil,
                                        // The row the uncommitted node sits
                                        // on carries the other half of its
                                        // dashed connector.
                                        dashedIncoming: idx == 0 && session.hasUncommittedWork
                                    )
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: graphWidth, alignment: .leading)

                            HStack(spacing: JournalRowLayout.contentSpacing) {
                                marker(for: commit, in: session)
                                Text(commit.shortHash)
                                    .scaledFont(10, design: .monospaced)
                                    .foregroundStyle(Color.textSecondary)
                                Text(commit.subject)
                                    .scaledFont(12)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text(DateFormatters.relative(from: commit.date))
                                    .scaledFont(10)
                                    .foregroundStyle(Color.textSecondary)
                                    .fixedSize()
                            }
                        }
                        .onTapGesture { select(.commit(commit), in: session) }
                    }
                }
            }
        }
        .background(Color.bgPanel)
    }

    @ViewBuilder
    private func marker(for commit: GitCommit, in session: SubmoduleSession) -> some View {
        // Which commit the parent records is the one thing this log has to
        // say that the submodule's own history does not.
        if session.isRecorded(commit) {
            pill("recorded by parent", color: .textSecondary)
        } else if session.isAheadOfParent(commit) {
            Text("›")
                .scaledFont(12, weight: .bold, design: .monospaced)
                .foregroundStyle(Color.diffAddText)
        }
    }

    private func row<Content: View>(
        selected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: JournalRowLayout.columnSpacing) {
            content()
        }
            .padding(.horizontal, JournalRowLayout.horizontalPadding)
            .frame(height: CommitGraphCell.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.bgSelected : Color.clear)
            .foregroundStyle(selected ? Color.white : Color.textPrimary)
            .contentShape(Rectangle())
    }

    private func isUncommittedSelected(_ session: SubmoduleSession) -> Bool {
        if case .uncommitted = session.selection { return true }
        return false
    }

    private func isSelected(_ commit: GitCommit, in session: SubmoduleSession) -> Bool {
        if case .commit(let c) = session.selection { return c.hash == commit.hash }
        return false
    }

    private func select(_ node: SubmoduleSession.Node, in session: SubmoduleSession) {
        session.selection = node
        Task { await session.loadSelection() }
    }

    // MARK: - Files

    @ViewBuilder
    private func filesPane(_ session: SubmoduleSession) -> some View {
        VStack(spacing: 0) {
            PanelHeader(title: isUncommittedSelected(session) ? "Uncommitted Files" : "Files") {
                if isUncommittedSelected(session), session.hasUncommittedWork {
                    HStack(spacing: 8) {
                        Button("All") { session.setAllStaged(true) }.scaledFont(10)
                        Button("None") { session.setAllStaged(false) }.scaledFont(10)
                    }
                }
            }

            if isUncommittedSelected(session) {
                uncommittedFiles(session)
            } else {
                commitFiles(session)
            }
        }
        .background(Color.bgPanel)
    }

    private func uncommittedFiles(_ session: SubmoduleSession) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(session.files) { file in
                        fileRow(selected: session.shownFile == file.path) {
                            Toggle("", isOn: Binding(
                                get: { session.staged.contains(file.path) },
                                set: { _ in session.toggle(file) }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()

                            fileLabel(file)
                        }
                        // Single click previews in the pane below, double
                        // click opens the compare window — the same pair the
                        // Files panel offers, declared the same way so the
                        // single click does not wait on the double.
                        .onTapGesture { Task { await session.showDiff(for: file) } }
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded { openCompare(file, in: session) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            commitBox(session)
        }
    }

    private func commitFiles(_ session: SubmoduleSession) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(session.commitFiles) { file in
                    fileRow(selected: session.shownFile == file.path) {
                        fileLabel(file)
                    }
                    .onTapGesture { Task { await session.showDiff(for: file) } }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded { openCompare(file, in: session) }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Open the app's compare for a file in the submodule.
    ///
    /// Everything about a compare is repository-scoped — where the file is
    /// read from, where a save is written, which commit the other side comes
    /// from — so all of it is pointed at the submodule rather than at the
    /// repository the main window has open.
    private func openCompare(_ file: GitFileStatus, in session: SubmoduleSession) {
        switch session.selection {
        case .uncommitted:
            Task {
                // Honour a configured external diff tool, as the Files panel
                // does; the built-in compare is the fallback.
                if await appState.openExternalDiff(
                    path: file.path, repoPath: session.submodulePath
                ) { return }
                CompareWindowPresenter.presentFileCompare(
                    appState: appState,
                    path: file.path,
                    repoPath: session.submodulePath,
                    // Saving from the compare changes the submodule's
                    // working tree, so this window's file list and diff are
                    // what needs re-reading — not the main window's.
                    onSaved: { await session.load() }
                )
            }
        case .commit(let commit):
            CompareWindowPresenter.presentCommitCompare(
                appState: appState,
                commit: commit,
                path: file.path,
                repoPath: session.submodulePath
            )
        }
    }

    /// One row of the Files list, marked when its diff is the one showing
    /// below. Same colours as the journal rows to the left, because it is the
    /// same statement: this is the row the pane is answering.
    private func fileRow<Content: View>(
        selected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            content()
        }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 3).fill(Color.bgSelected)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.textPrimary)
            .contentShape(Rectangle())
    }

    private func fileLabel(_ file: GitFileStatus) -> some View {
        HStack(spacing: 6) {
            FileStatusDot(file: file, color: file.displaySwatch)
            Text(file.name).scaledFont(11).lineLimit(1)
            Text(file.relativeDirectory == "." ? "" : file.relativeDirectory)
                .scaledFont(10, design: .monospaced)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            Text(file.stateDisplay)
                .scaledFont(10)
                .foregroundStyle(file.displaySwatch)
                .fixedSize()
        }
    }

    /// The commit box, in this window, for this submodule. The whole reason
    /// the session exists: the main window's commit dialog belongs to the
    /// main window's repository, and using it here would commit to the
    /// wrong one — or appear over the wrong window, which is how this was
    /// found.
    private func commitBox(_ session: SubmoduleSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Binding(
                get: { session.message },
                set: { session.message = $0 }
            ))
            .font(.mono(size: 12))
            .frame(height: 64)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.borderColor, lineWidth: 0.5))

            HStack {
                Text("Commits in \(session.name). The parent records it separately.")
                    .scaledFont(10)
                    .foregroundStyle(Color.textDisabled)
                    .lineLimit(2)
                Spacer()
                Button("Commit \(session.staged.count) File\(session.staged.count == 1 ? "" : "s")") {
                    Task { await session.commit() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canCommit)
            }
        }
        .padding(10)
    }

    /// Hand the submodule over to the main window: make it the active
    /// repository, then get out of the way.
    ///
    /// Leaving this window open on top of the repository it just handed
    /// over would put two views of the same thing on screen, with the one
    /// that is no longer authoritative in front.
    private func switchToRepository(_ session: SubmoduleSession) async {
        await appState.openSubmoduleAsRepository(path: session.path)
        // Cleared so reopening the same submodule later still counts as a
        // change and re-triggers the window's load.
        appState.submoduleLogTarget = nil
        dismissWindow(id: "submodule-log")
        Self.focusMainWindow()
    }

    /// Bring the main window forward. Closing a window hands focus to
    /// whatever macOS picks next, which on a machine with a compare or a
    /// Log window open is not necessarily the one now showing the
    /// repository the user just asked for.
    private static func focusMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let main = NSApp.windows.first { window in
            window.isVisible && window.title == "SmallGit"
        }
        (main ?? NSApp.mainWindow)?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Footer

    private func footer(_ session: SubmoduleSession) -> some View {
        HStack(spacing: 8) {
            if let status = session.status {
                Text(status)
                    .scaledFont(10)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()

            if session.parentIsBehind {
                Button("Record in Parent") {
                    Task {
                        await session.recordInParent()
                        // The parent's own panels now show a moved pointer.
                        await appState.refreshPanels()
                    }
                }
                .help("git add \(session.path) — stages the new commit so the parent's next commit records it")
            }

            Button("Open as Repository") {
                Task { await switchToRepository(session) }
            }
            .help("Work in it in the main window — this window has done its job, so it closes")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.bgPanelHeader)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.borderColor).frame(height: 0.5)
        }
    }
}
