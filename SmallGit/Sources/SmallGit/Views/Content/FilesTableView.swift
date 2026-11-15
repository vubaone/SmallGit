import SwiftUI
import AppKit

struct FilesTableView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var appState: AppState
    @Bindable var viewModel: FilesViewModel

    /// Closing the assume-unchanged tip holds for the session, not
    /// forever: the flag is rare enough that someone who last read this
    /// two months ago is glad to be told again, and someone who reads it
    /// twice in one sitting is not.
    @State private var assumeUnchangedTipDismissed = false

    private var conflictedFiles: [GitFileStatus] {
        viewModel.files.filter(\.isConflict)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Files") {
                HStack(spacing: 8) {
                    if appState.canUseActiveRepo {
                        // A capped list must say so: "500 shown" with
                        // nothing else looks like the whole answer.
                        if viewModel.truncatedMatchCount > 0 {
                            Text("+\(viewModel.truncatedMatchCount) more — refine the filter")
                                .scaledFont(10)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                                .help("The filter lists the first \(FilesViewModel.maxUnchangedMatches) unchanged matches. Everything that changed is always listed.")
                        } else if viewModel.hiddenCount > 0 {
                            Text("\(viewModel.hiddenCount) hidden")
                                .scaledFont(10)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        TextField("File Filter", text: $viewModel.filterText)
                            .accessibilityIdentifier("files.filter")
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 90, idealWidth: 140, maxWidth: 200)
                            .scaledFont(11)
                            // The filter searches unchanged files too, so
                            // the first keystroke needs the tracked-file
                            // list. Debounced: `ls-files` is one process
                            // and the typing settles in a moment.
                            .task(id: viewModel.filterText) {
                                guard !viewModel.filterText.isEmpty else { return }
                                try? await Task.sleep(for: .milliseconds(150))
                                guard !Task.isCancelled else { return }
                                await viewModel.loadTrackedPathsIfNeeded()
                            }
                        FileTypeFilterBar(viewModel: viewModel, appState: appState)
                    }
                }
            }

            if appState.activeRepo == nil {
                EmptyPanelState(
                    icon: "doc.on.doc",
                    title: "No repository open",
                    message: "Choose a repository in the sidebar to see its working-tree changes."
                )
            } else if let issue = appState.activeRepositoryIssue,
                      let repo = appState.activeRepo {
                EmptyPanelState(
                    icon: issue.emptyStateIcon,
                    title: issue.emptyStateTitle,
                    message: issue.emptyStateMessage(path: repo.path)
                )
            } else {
                filesContent
            }
        }
        .background(Color.bgPanel)
    }

    /// Pulled out so the top-level `body` can switch cleanly between
    /// "no repo" empty state and the live files content. Renders the
    /// banners + table that previously sat inline in `body`.
    @ViewBuilder
    private var filesContent: some View {
        // Both warnings sit together directly under the Files
        // header — the merge/rebase/cherry-pick state and the
        // conflicted-files count belong to the same situation,
        // so stacking them with a thin separator gives the user
        // one place to look instead of scattering attention.
        // Unmerged files with no marker still get a banner: a conflicted
        // `stash apply` leaves git nothing to record, and without this the
        // panel showed only a conflict count and no way out.
        if appState.inProgressOperation != nil || !conflictedFiles.isEmpty {
            InProgressOperationBanner(
                situation: appState.inProgressOperation.map { .operation($0) } ?? .unattributed,
                appState: appState
            )
            if !conflictedFiles.isEmpty {
                Rectangle()
                    .fill(Color.strongBorder)
                    .frame(height: 1)
            }
        }

        if !conflictedFiles.isEmpty {
            ConflictBanner(
                count: conflictedFiles.count,
                onResolveFirst: {
                    if let first = conflictedFiles.first {
                        appState.openCompareOrMerge(path: first.path, isConflict: true)
                    }
                }
            )
        }

        // Under the conflict banners, not above them: a tip explains, a
        // banner needs answering.
        if viewModel.showAssumeUnchanged, !assumeUnchangedTipDismissed {
            InlineTip(
                lead: "Assume unchanged",
                message: assumeUnchangedTipMessage,
                onDismiss: { assumeUnchangedTipDismissed = true }
            )
        }

        filesTable
    }

    /// What the tip says while the assume-unchanged view is on.
    ///
    /// The empty case earns its own wording: switching the view on and
    /// seeing the list not change is the one outcome that reads as a
    /// broken button, when it actually means the repository has no flagged
    /// file to show. It waits for the read to come back — an empty list we
    /// haven't filled yet is not the same claim.
    private var assumeUnchangedTipMessage: String {
        if viewModel.hasLoadedAssumeUnchanged, viewModel.assumeUnchangedPaths.isEmpty {
            return "nothing here carries the flag. Setting it tells git to stop "
                + "checking a file, so your edits to it stay out of status, diffs "
                + "and commits. Right-click a file to set it."
        }
        return "git has been told to stop checking these files, so edits to them "
            + "stay out of status, diffs and commits until the flag comes off. "
            + "Right-click a row to clear it."
    }

    /// The three sortable columns.
    ///
    /// A separate `@TableColumnBuilder` property rather than an inline
    /// `columns:` closure: the builder has to infer both the row type and
    /// the sort comparator across three columns at once, and inline that
    /// inference blows the type-checker's time budget. Naming both generic
    /// parameters here hands it the answer.
    @TableColumnBuilder<GitFileStatus, FileSortComparator>
    private var fileColumns: some TableColumnContent<GitFileStatus, FileSortComparator> {
        TableColumn("Name", sortUsing: FileSortComparator(field: .name)) { file in
            FileNameCell(file: file)
        }
        .width(min: 140, ideal: 220)

        TableColumn("State", sortUsing: FileSortComparator(field: .state)) { file in
            Text(file.stateDisplay)
                .scaledFont(11)
                .foregroundStyle(file.displaySwatch)
                .lineLimit(1)
        }
        .width(min: 80, ideal: 110, max: 160)

        TableColumn("Relative Directory", sortUsing: FileSortComparator(field: .directory)) { file in
            Text(file.relativeDirectory)
                .scaledFont(12, design: .monospaced)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @TableRowBuilder<GitFileStatus>
    private var fileRows: some TableRowContent<GitFileStatus> {
        ForEach(viewModel.filteredFiles) { file in
            TableRow(file)
                .contextMenu {
                    FileContextMenu(
                        files: contextFiles(focused: file),
                        appState: appState
                    )
                }
        }
    }

    /// The table itself, lifted out of `filesContent`.
    ///
    /// Not a style choice: with the sort comparators added to the three
    /// column headers, the whole thing written as one expression stopped
    /// type-checking inside the compiler's budget. Each cell is its own
    /// small view for the same reason.
    private var filesTable: some View {
        // `sortOrder` is what makes the headers clickable: click one to sort
        // by that column, click it again to reverse. SwiftUI writes the
        // chosen comparator back into the view model, and `filteredFiles`
        // applies it after the filters.
        Table(
            of: GitFileStatus.self,
            selection: $viewModel.selectedFileIDs,
            sortOrder: $viewModel.sortOrder
        ) {
            fileColumns
        } rows: {
            fileRows
        }
        .onChange(of: viewModel.selectedFileIDs) { _, new in
            // Only a single selection has a diff to preview. Any more and
            // there is no one file to show — `Set.first` would pick an
            // arbitrary one — and on a select-all over a filtered
            // repository it would mean a git call for a row nobody asked
            // about, on top of the selection itself.
            guard new.count == 1 else {
                appState.diffVM.clear()
                return
            }
            // Resolve against the displayed rows, not `files`: with a
            // filter active the table also lists unchanged files, and
            // those exist nowhere in the changed set. Their diff comes
            // back empty, which the diff pane reports as "No differences".
            guard let id = new.first,
                  let file = viewModel.filteredFiles.first(where: { $0.id == id }) else {
                return
            }
            // Selection only updates the inline CHANGES preview —
            // the full resolver / external tool is reserved for
            // double-click, Return, the Resolve banner, and the
            // context menu so navigating with arrows or single
            // clicks stays lightweight.
            Task { await appState.selectFile(file) }
        }
        .background {
            // Invisible button binding Return to "open the
            // selected file in compare" — matches Finder's
            // select-then-Return convention.
            Button("__open_selected") {
                openSelected()
            }
            .keyboardShortcut(.return, modifiers: [])
            .opacity(0)
            .allowsHitTesting(false)
            .frame(width: 0, height: 0)
        }
        .background {
            // Reaches into the underlying NSTableView and wires
            // its `doubleAction` so a double-click on any row
            // opens compare. We can't put a SwiftUI tap recognizer
            // on cells without eating NSTableView's selection
            // mouseDown, but `doubleAction` is fired by AppKit
            // *after* selection has already happened — so single
            // clicks still select cleanly.
            //
            // Row indices come from `filteredFiles`, the same sorted and
            // filtered array the rows were built from, so a double-click
            // still lands on the row under the pointer after a re-sort.
            TableDoubleClickBridge { rowIndex in
                let files = viewModel.filteredFiles
                guard rowIndex >= 0, rowIndex < files.count else { return }
                open(file: files[rowIndex])
            }
        }
    }

    /// If the right-clicked row is already in the selection, act on the
    /// full selection; otherwise act on just that row (standard macOS
    /// behaviour for Finder, Mail, etc.).
    private func contextFiles(focused: GitFileStatus) -> [GitFileStatus] {
        if viewModel.selectedFileIDs.contains(focused.id) {
            return viewModel.filteredFiles.filter { viewModel.selectedFileIDs.contains($0.id) }
        }
        return [focused]
    }

    /// Opens the selected file in the appropriate view: 3-pane
    /// resolver for conflicts, 2-pane Beyond-Compare-style for
    /// everything else. Invoked by the Return / ⌘O shortcuts and the
    /// "Compare…" context menu item.
    private func open(file: GitFileStatus) {
        // A submodule is a directory, not a file: `git show HEAD:<path>`
        // answers `fatal: bad object`, so a compare window would open with
        // nothing in it. What a moved pointer raises is "what changed in
        // there", and that is a log.
        if file.isSubmodule {
            // Its own window, with its own repository context: this must
            // not move the main window off the repository being worked in.
            Task {
                if await appState.openSubmoduleLog(path: file.path) {
                    openWindow(id: "submodule-log")
                }
            }
            return
        }
        appState.openCompareOrMerge(path: file.path, isConflict: file.isConflict)
    }

    /// Hidden-shortcut entry point — opens the currently-selected file
    /// (the first one if multi-select) in the compare view. No-op when
    /// nothing is selected.
    private func openSelected() {
        guard let id = viewModel.selectedFileIDs.first,
              let file = viewModel.filteredFiles.first(where: { $0.id == id }) else {
            return
        }
        open(file: file)
    }
}

// MARK: - Double-click bridge


/// Name column: status dot, filename, and the "← old name" trailer that
/// makes a rename read as one move.
private struct FileNameCell: View {
    let file: GitFileStatus

    var body: some View {
        HStack(spacing: 6) {
            FileStatusDot(file: file, color: file.displaySwatch)
            Text(file.name)
                .scaledFont(12)
                .foregroundStyle(Color.textPrimary)
            if let origin = file.renameOrigin {
                Text("← \(origin)")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        // No tap gesture here — SwiftUI tap recognizers on Table cells
        // silently swallow the mouseDown that NSTableView needs for
        // selection. The "open compare" action is surfaced via the hidden
        // Return / ⌘O shortcut button and the context menu instead.
    }
}

/// Locates the `NSTableView` backing SwiftUI's `Table` or `List` and
/// wires its `doubleAction` to a SwiftUI callback. This is the only
/// reliable way to get "double-click opens" without a SwiftUI tap
/// recognizer, which would eat the mouseDown NSTableView needs for
/// selection. Used by both the main-window Files table and the Log
/// window's per-commit Files list — file-internal `private` keeps
/// those two from sharing this, so it's left at module scope.
struct TableDoubleClickBridge: NSViewRepresentable {
    let onDoubleClick: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        // Defer the table lookup — at make-time we're not yet in the
        // window's view hierarchy, so the NSTableView won't be a
        // reachable cousin yet. Retry on a short cadence until found.
        scheduleAttach(from: v, coordinator: context.coordinator)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Keep the callback fresh — SwiftUI may rebuild the bridge
        // with a new closure capturing newer state.
        context.coordinator.callback = onDoubleClick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(callback: onDoubleClick)
    }

    /// Walks UP from the bridge view, searching for an NSTableView
    /// at each ancestor level. The nearest one will be the Files
    /// table — searching from the window root would pick up
    /// RepositoriesPanel or BranchesPanel first, which is why an
    /// earlier version of this code attached doubleAction to the
    /// wrong table and silently did nothing.
    private func scheduleAttach(from view: NSView, coordinator: Coordinator, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let table = findNearestTable(from: view) {
                table.target = coordinator
                table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
                coordinator.table = table
                return
            }
            if attempt < 40 {
                scheduleAttach(from: view, coordinator: coordinator, attempt: attempt + 1)
            }
        }
    }

    private func findNearestTable(from anchor: NSView) -> NSTableView? {
        // Walk up from the bridge, scanning each ancestor's subtree
        // for an NSTableView. First hit wins — it's the table
        // physically closest to the bridge in the view hierarchy.
        var node: NSView? = anchor.superview
        var seenIDs = Set<ObjectIdentifier>()
        while let cur = node {
            if let t = firstTable(in: cur, skipping: seenIDs) {
                return t
            }
            seenIDs.insert(ObjectIdentifier(cur))
            node = cur.superview
        }
        return nil
    }

    private func firstTable(in view: NSView, skipping seen: Set<ObjectIdentifier>) -> NSTableView? {
        // Skip subtrees we've already scanned to avoid re-checking
        // the bridge's siblings on every upward step.
        if seen.contains(ObjectIdentifier(view)) { return nil }
        if let t = view as? NSTableView { return t }
        for sub in view.subviews {
            if let t = firstTable(in: sub, skipping: seen) { return t }
        }
        return nil
    }

    final class Coordinator: NSObject {
        var callback: (Int) -> Void
        weak var table: NSTableView?

        init(callback: @escaping (Int) -> Void) {
            self.callback = callback
        }

        @MainActor
        @objc func handleDoubleClick(_ sender: Any) {
            guard let table else { return }
            let row = table.clickedRow
            // `clickedRow` is -1 when the double-click landed in the
            // table's empty area (below the last row); ignore it.
            guard row >= 0 else { return }
            // AppKit selects on mouse-down, so a legitimate double-click is
            // always on a selected row by the time this fires. A row that is
            // *not* selected is one the table refused to select — an outline
            // group header, say — and acting on it would run the action
            // against whatever happened to be selected beforehand.
            guard table.selectedRowIndexes.contains(row) else { return }
            callback(row)
        }
    }
}

/// Row of icon toggles in the Files panel header that filter which
/// file types are visible. Mirrors SmartGit's top-right icon strip
/// (show untracked / ignored / staged / unstaged). Each toggle has a
/// keyboard shortcut so the user can flip them without mousing.
///
/// Toggling "show ignored" triggers a refresh because `git status`
/// only emits ignored entries when explicitly asked (`--ignored`).
struct FileTypeFilterBar: View {
    @Bindable var viewModel: FilesViewModel
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 2) {
            iconToggle(
                isOn: $viewModel.showStaged,
                symbol: "checkmark.circle",
                help: "Show staged changes (⌘1)",
                shortcut: "1"
            )
            .accessibilityIdentifier("files.showStaged")
            iconToggle(
                isOn: $viewModel.showUnstaged,
                symbol: "pencil.circle",
                help: "Show unstaged modifications (⌘2)",
                shortcut: "2"
            )
            .accessibilityIdentifier("files.showUnstaged")
            iconToggle(
                isOn: $viewModel.showUntracked,
                symbol: "questionmark.circle",
                help: "Show untracked files (⌘3)",
                shortcut: "3"
            )
            .accessibilityIdentifier("files.showUntracked")
            iconToggle(
                isOn: $viewModel.showIgnored,
                symbol: "eye.slash.circle",
                help: "Show ignored files (⌘4)",
                shortcut: "4",
                onChange: {
                    // git status needs the --ignored flag to even
                    // emit these entries, so toggling refreshes.
                    Task { await viewModel.forceRefresh() }
                }
            )
            .accessibilityIdentifier("files.showIgnored")
            iconToggle(
                isOn: $viewModel.showAssumeUnchanged,
                symbol: "hand.raised.circle",
                help: "Show assume-unchanged files — git ignores your edits to these (⌘5)",
                shortcut: "5",
                onChange: {
                    // Not a filter over `git status` like the other four:
                    // the flag makes status skip the file entirely, so the
                    // list is a separate read of the index.
                    Task { await viewModel.loadAssumeUnchanged() }
                }
            )
            .accessibilityIdentifier("files.showAssumeUnchanged")
        }
        .padding(.horizontal, 4)
    }

    // The assume-unchanged toggle names a git flag most people have never
    // set, so its hover text says what the flag *does* rather than
    // restating the label — but at the same one-line size as the other
    // four. The full explanation is the `InlineTip` under the header,
    // which is on screen while the view is, no hovering required.

    @ViewBuilder
    private func iconToggle(
        isOn: Binding<Bool>,
        symbol: String,
        help: String,
        shortcut: KeyEquivalent,
        onChange: (() -> Void)? = nil
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            onChange?()
        } label: {
            Image(systemName: symbol)
                .scaledFont(13)
                .foregroundStyle(isOn.wrappedValue ? Color.accentBlue : Color.textDisabled)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn.wrappedValue
                              ? Color.accentBlue.opacity(0.18)
                              : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .help(help)
    }
}

/// Top-of-panel banner shown when the working tree has at least one
/// conflicted file. Gives a one-click path into the resolver — the
/// row context menu still works, this just makes the state obvious.
private struct ConflictBanner: View {
    let count: Int
    let onResolveFirst: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("\(count) conflicted file\(count == 1 ? "" : "s")")
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(Color.textPrimary)
            Text("— resolve before committing")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Button("Resolve…") { onResolveFirst() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.orange.opacity(0.5)).frame(height: 0.5)
        }
    }
}
