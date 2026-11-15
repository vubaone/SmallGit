import SwiftUI

/// Lightweight presenter — owns the resolver's view model so it's
/// reset to fresh state every time the sheet opens. Loads the file's
/// three blob versions on appear, then renders the actual resolver.
struct ConflictResolverPresenter: View {
    @Bindable var appState: AppState
    let path: String
    @State private var viewModel: ConflictResolutionViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                ConflictResolutionView(appState: appState, viewModel: vm)
            } else {
                ProgressView().frame(width: 300, height: 200)
            }
        }
        .task(id: path) {
            let vm = ConflictResolutionViewModel(
                git: appState.git,
                coordinator: appState.coordinator
            )
            await vm.load(path: path)
            viewModel = vm
        }
    }
}

/// Beyond-Compare-style 4-pane resolver for a single conflicted file.
///
///   ┌────────┬────────┬────────┐
///   │ OURS   │ BASE   │ THEIRS │   read-only, synchronized
///   ├────────┴────────┴────────┤
///   │     CHUNK INSPECTOR      │   per-chunk Take buttons + nav
///   ├──────────────────────────┤
///   │         MERGED           │   editable result
///   └──────────────────────────┘
struct ConflictResolutionView: View {
    @Bindable var appState: AppState
    @Bindable var viewModel: ConflictResolutionViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showMarkerWarning = false
    @State private var showDiscardConfirmation = false
    @State private var showAncestorPrompt = false
    @State private var wrapLines = false
    @State private var collapseUnchanged = true
    @State private var showContext = true
    /// The chunk whose Base button opened the prompt, resolved automatically
    /// once the ancestor sections arrive. `nil` when the prompt came from
    /// Bulk Resolve, which applies to everything anyway.
    @State private var pendingBaseChunk: ConflictChunk?

    /// The aligned row the line inspector is describing, and the chunk it
    /// falls in. Held as the row itself rather than an index: the alignment
    /// lives inside `ConflictDiffPanes`, and an index would mean asking it
    /// for the row again on every redraw.
    @State private var selectedRow: ConflictLineRow?
    @State private var selectedRowChunkID: UUID?

    /// ⌘F across the three read-only panes.
    ///
    /// The MERGED pane is excluded on purpose: it is an `NSTextView`, and
    /// AppKit gives an editor its own find bar — with replace, which a
    /// read-only viewer has no use for and this bar does not offer. ⌘F inside
    /// that pane brings up the system one.
    @State private var find = TextFindState()
    @FocusState private var findFocused: Bool

    /// Reports the result's size in the pane header, so "nothing is showing"
    /// is always answerable without scrolling or selecting.
    private var mergedSubtitle: String {
        if viewModel.mergedText.isEmpty { return "editable result · empty" }
        let lines = viewModel.mergedText.components(separatedBy: "\n").count
        return "editable result · \(lines) line\(lines == 1 ? "" : "s")"
    }

    /// `nil` for a file the highlighter doesn't know, leaving every pane
    /// exactly as it rendered before.
    private var language: SyntaxLanguage? {
        viewModel.path.flatMap(SyntaxLanguage.init(path:))
    }

    /// Closes the window AND clears `appState.conflictTarget` so that
    /// re-opening the resolver for the same file path triggers the
    /// `onChange` watcher in MainWindow. Without the clear, picking
    /// the same conflicted file twice in a row no-ops because the
    /// observed value never changes.
    private func close() {
        appState.conflictTarget = nil
        dismiss()
    }

    /// What the two file-level buttons promise. On a modify/delete one of
    /// them deletes the file rather than checking a version out, and the
    /// label has to say which — "Take Ours" on a file our side deleted
    /// reads like the opposite of what it does.
    private func fileButtonLabel(isOurs: Bool) -> String {
        guard let kind = viewModel.conflictKind, kind.isDeleteConflict else {
            return isOurs ? "Take Ours (file)" : "Take Theirs (file)"
        }
        let keeps = isOurs ? kind.hasOurs : kind.hasTheirs
        return keeps ? "Keep File" : "Delete File"
    }

    private func fileButtonHelp(isOurs: Bool) -> String {
        guard let kind = viewModel.conflictKind, kind.isDeleteConflict else {
            return isOurs
                ? "Replace the whole file with our version and stage"
                : "Replace the whole file with the incoming version and stage"
        }
        let keeps = isOurs ? kind.hasOurs : kind.hasTheirs
        return keeps
            ? "Keep the file and stage it as the resolution"
            : "Remove the file and stage the deletion as the resolution"
    }

    /// A strip above the panes for a modify/delete, saying which side
    /// deleted the file and therefore which pane is empty on purpose.
    ///
    /// It sits *over* the three-way view rather than replacing it: the
    /// empty pane is the least informative thing on screen, and the two
    /// that are populated answer the question the user actually came
    /// with — what did the branch that kept this file change in it.
    private func deleteConflictBanner(_ kind: ConflictKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trash.slash")
                .foregroundStyle(.orange)
            Text(kind.label)
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(Color.textPrimary)
            Text(kind.hasOurs
                 ? "— the incoming branch deleted this file; OURS and BASE show what your side has. Keep it, or finish the delete."
                 : "— your branch deleted this file; BASE and THEIRS show what the incoming side changed. Take it, or keep the delete.")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.orange.opacity(0.5)).frame(height: 0.5)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            horizontalSeparator
            if find.isPresented {
                FindBar(state: find, isFocused: $findFocused)
            }
            if viewModel.isLoading {
                ProgressView("Loading conflict…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = viewModel.errorMessage {
                Text(err)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A modify/delete still gets the full three-way view. One
                // pane is empty, but the other two are the whole point:
                // BASE against the surviving side is what the branch that
                // kept the file actually did to it, and that is exactly
                // what you need to decide whether the delete still holds.
                if let kind = viewModel.conflictKind, kind.isDeleteConflict {
                    deleteConflictBanner(kind)
                }
                body4Pane
            }
            horizontalSeparator
            actionBar
        }
        // Min for usability, ideal that fits a typical 1440p window,
        // max=.infinity so the user can drag the sheet's edges to
        // fill the screen when they want more code on screen at once.
        .frame(
            minWidth: 900, idealWidth: 1200, maxWidth: .infinity,
            minHeight: 600, idealHeight: 760, maxHeight: .infinity
        )
        .background(Color.bgPanel)
        .alert(
            "Conflict markers remain",
            isPresented: $showMarkerWarning
        ) {
            Button("Save Anyway", role: .destructive) {
                Task { await save() }
            }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("The merged text still contains <<<<<<<, =======, or >>>>>>> markers. Committing this would leave conflict syntax in the file.")
        }
        .alert(
            "Add the common ancestor to this file?",
            isPresented: $showAncestorPrompt
        ) {
            Button("Add Ancestor Sections") {
                Task { await addAncestorSections() }
            }
            Button("Cancel", role: .cancel) { pendingBaseChunk = nil }
        } message: {
            Text("""
            git's default conflict markers record only ours and theirs, so \
            this file has no ancestor to take — even though the BASE pane \
            above can show it from the index.

            SmallGit can rewrite this file's markers to include it. The file \
            stays conflicted and unstaged; any resolutions in this window, and \
            any hand edits to the file, are replaced by fresh markers.

            To get this automatically from now on: \
            git config --global merge.conflictStyle zdiff3
            """)
        }
        .alert(
            "Discard your resolutions?",
            isPresented: $showDiscardConfirmation
        ) {
            Button("Discard", role: .destructive) {
                Log.app("conflict.discard", detail: viewModel.path ?? "")
                close()
            }
            Button("Keep Resolving", role: .cancel) { }
        } message: {
            // The file itself is untouched either way — nothing here writes to
            // disk before Save & Stage — so this is only about not throwing
            // away the decisions the user already made.
            Text("""
            The conflict stays exactly as it is and you can come back to it \
            later. Only the choices you have made in this window are lost.
            """)
        }
        .findBarShortcuts(find, focus: $findFocused)
        .task(id: viewModel.path) {
            guard let path = viewModel.path else { return }
            Log.app("conflict.open", detail: "\(path) · \(viewModel.chunks.count) chunks")
            // Three parallel documents sharing a line numbering, exactly like
            // the compare view's two panes.
            find.configure(columns: {
                [
                    viewModel.oursText.components(separatedBy: "\n"),
                    viewModel.baseText.components(separatedBy: "\n"),
                    viewModel.theirsText.components(separatedBy: "\n")
                ]
            })
            find.recompute()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Resolve Conflict")
                .scaledFont(13, weight: .semibold)
            if let p = viewModel.path {
                Text(p)
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Group {
                Toggle("Wrap", isOn: $wrapLines)
                    .help("Wrap long lines instead of scrolling horizontally")
                Toggle("Collapse", isOn: $collapseUnchanged)
                    .help("Hide unchanged parts of Ours, Base, and Theirs")
                Toggle("Context", isOn: $showContext)
                    .disabled(!collapseUnchanged)
                    .help(collapseUnchanged
                          ? "Keep 3 unchanged lines above and below each difference"
                          : "Only applies when Collapse is on")
                Toggle("Whitespace", isOn: whitespaceBinding)
                    .help("Show spaces as ·, tabs as → and line ends as ¶")
            }
            .toggleStyle(.checkbox)
            .scaledFont(10)

            // Compact "N of M resolved" badge mirrors Beyond Compare's
            // bottom-bar conflict count — visible at a glance so the
            // user knows whether saving will leave junk behind.
            if !viewModel.chunks.isEmpty {
                Text("\(viewModel.resolvedCount) / \(viewModel.chunks.count) resolved")
                    .scaledFont(11, weight: .medium)
                    .foregroundStyle(viewModel.allChunksResolved
                                     ? .green
                                     : Color.textSecondary)
            }
            // Same guard as the action bar's button, and Escape goes through
            // it too — otherwise the confirmation is just a door with a gap
            // beside it.
            Button("Close") {
                // Escape closes the find bar first, if it is open.
                if find.isPresented { find.dismiss() } else { requestClose() }
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bgPanelHeader)
    }

    /// Three side-by-side read-only panes on top of the chunk
    /// inspector + editable merged pane. VSplitView lets the user
    /// drag the divider to give either half more screen real estate.
    private var body4Pane: some View {
        VSplitView {
            topPanes
                .frame(minHeight: 200)

            VSplitView {
                ChunkInspector(
                    viewModel: viewModel,
                    syntax: language,
                    selectedRow: selectedRow,
                    selectedRowChunkID: selectedRowChunkID,
                    onTakeBase: takeBase
                )
                    .frame(minHeight: 140, idealHeight: 200)

                ComparePane(title: "MERGED", subtitle: mergedSubtitle, tint: .yellow) {
                    EditableTextPane(text: $viewModel.mergedText, syntax: language)
                        // An empty result is a legitimate outcome — taking
                        // "Neither" on a file that is nothing but one conflict
                        // leaves nothing behind — but an empty pane looks
                        // exactly like a broken one. Say which it is.
                        .overlay(alignment: .topLeading) {
                            if viewModel.mergedText.isEmpty {
                                Text("(empty — saving now would write a file with no content)")
                                    .font(.mono(size: appState.appConfig.monoFontSize))
                                    .foregroundStyle(Color.textDisabled)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                .frame(minHeight: 160)
            }
            .frame(minHeight: 320)
        }
    }

    /// Ours / Base / Theirs across the top. Base is shown even when
    /// the file is from an add/add conflict (no base) — it just
    /// renders with a "(no base)" placeholder so the layout stays
    /// stable and the user isn't surprised by missing columns.
    private var topPanes: some View {
        ConflictDiffPanes(
            oursText: viewModel.oursText,
            baseText: viewModel.baseText,
            theirsText: viewModel.theirsText,
            hasBase: viewModel.hasBase,
            deletedSides: viewModel.deletedSides,
            oursHighlights: viewModel.oursHighlights,
            baseHighlights: viewModel.baseHighlights,
            theirsHighlights: viewModel.theirsHighlights,
            focusedChunkID: viewModel.focusedChunkID,
            language: language,
            find: find,
            wrapLines: wrapLines,
            collapseUnchanged: collapseUnchanged,
            showContext: showContext,
            selectedRowID: selectedRow?.id,
            onSelectRow: { row, chunkID in
                selectedRow = row
                selectedRowChunkID = chunkID
                // Clicking a conflict line is also a way of saying which
                // chunk you are working on, and the buttons above act on the
                // focused one — so the two do not drift apart.
                if let chunkID { viewModel.focusedChunkID = chunkID }
            }
        )
        .id(viewModel.path)
    }

    private var whitespaceBinding: Binding<Bool> {
        Binding(
            get: { appState.appConfig.showWhitespace },
            set: { appState.setShowWhitespace($0) }
        )
    }

    /// Marks the boundaries between the header, the 4-pane body, and the
    /// action bar so they don't bleed into each other visually.
    private var horizontalSeparator: some View {
        Rectangle()
            .fill(Color.strongBorder)
            .frame(height: 1)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            // Deliberately *not* an "Abort merge" button.
            //
            // Aborting is a repository-level operation — it undoes the whole
            // merge across every conflicted file — and this is a per-file
            // editor. Having it here invited exactly the mistake it caused:
            // reaching for what looked like "cancel out of this dialog" and
            // getting the entire merge thrown away. It lives on the
            // "Merge in progress" banner in the main window instead, next to
            // Continue, which is the scope it actually belongs to.
            Button("Close Without Saving") {
                requestClose()
            }
            .help("Leave this file as it is and come back later — nothing is written")

            Divider().frame(height: 20)

            Button {
                viewModel.focusPrevious()
            } label: {
                Label("Previous", systemImage: "chevron.up")
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(viewModel.chunks.count < 2)
            .help("Jump to the previous conflict chunk (⌘[)")

            Button {
                viewModel.focusNext()
            } label: {
                Label("Next", systemImage: "chevron.down")
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(viewModel.chunks.count < 2)
            .help("Jump to the next conflict chunk (⌘])")

            Spacer()

            Menu {
                Button("Take All Ours") { viewModel.resolveAll(to: .ours) }
                Button("Take All Theirs") { viewModel.resolveAll(to: .theirs) }
                Button("Take All Base") {
                    if viewModel.hasPerChunkBase {
                        viewModel.resolveAll(to: .base)
                    } else {
                        pendingBaseChunk = nil
                        showAncestorPrompt = true
                    }
                }
                Divider()
                Button("Take All Ours then Theirs") { viewModel.resolveAll(to: .bothOursFirst) }
                Button("Take All Theirs then Ours") { viewModel.resolveAll(to: .bothTheirsFirst) }
            } label: {
                Label("Bulk Resolve", systemImage: "wand.and.stars")
            }
            .help("Apply one resolution choice to every chunk")

            Button(fileButtonLabel(isOurs: true)) {
                Task {
                    if await viewModel.acceptOurs() { close() }
                }
            }
            .help(fileButtonHelp(isOurs: true))

            Button(fileButtonLabel(isOurs: false)) {
                Task {
                    if await viewModel.acceptTheirs() { close() }
                }
            }
            .help(fileButtonHelp(isOurs: false))

            Button("Save & Stage") {
                if viewModel.mergedStillHasMarkers {
                    showMarkerWarning = true
                } else {
                    Task { await save() }
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .help("Write the merged pane to disk and mark resolved (⌘S)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bgPanelHeader)
    }

    private func save() async {
        Log.app("conflict.save", detail: viewModel.path ?? "")
        if await viewModel.saveAndMarkResolved() { close() }
    }

    /// Take the ancestor for one chunk, or offer to make it available.
    private func takeBase(_ chunk: ConflictChunk) {
        if chunk.baseText != nil {
            viewModel.resolve(chunk: chunk, to: .base)
        } else {
            pendingBaseChunk = chunk
            showAncestorPrompt = true
        }
    }

    /// Rewrites the markers, then applies the choice the user was reaching for
    /// when they hit the missing ancestor — so the prompt is a detour rather
    /// than a dead end they have to retrace.
    private func addAncestorSections() async {
        let chunkIndex = pendingBaseChunk?.index
        guard await viewModel.loadAncestorSections() else { return }
        if let chunkIndex, let reloaded = viewModel.chunks.first(where: { $0.index == chunkIndex }) {
            viewModel.resolve(chunk: reloaded, to: .base)
        } else if chunkIndex == nil {
            viewModel.resolveAll(to: .base)
        }
        pendingBaseChunk = nil
    }

    /// User asked to leave. Confirms only when there is something to lose.
    ///
    /// Closing is always safe for the repository — nothing in this window
    /// writes to disk before Save & Stage — so an unconditional prompt would
    /// be pure friction on the common "just let me out" case.
    private func requestClose() {
        if viewModel.hasUnsavedWork {
            showDiscardConfirmation = true
        } else {
            Log.app("conflict.close", detail: viewModel.path ?? "")
            close()
        }
    }
}

// MARK: - Chunk inspector

/// Per-chunk strip between the read-only panes and the editable
/// merged pane. Shows the currently-focused chunk's Ours/Theirs side
/// by side with one-click Take buttons. List on the left lets the
/// user jump between chunks; resolved chunks get a check mark.
private struct ChunkInspector: View {
    @Bindable var viewModel: ConflictResolutionViewModel
    var syntax: SyntaxLanguage? = nil
    /// The row clicked in the panes above, which is what the four lines
    /// below describe.
    var selectedRow: ConflictLineRow?
    var selectedRowChunkID: UUID?
    /// Called instead of resolving directly, so the parent can ask about
    /// rewriting the markers when the chunk has no ancestor to take.
    var onTakeBase: (ConflictChunk) -> Void = { _ in }
    @Environment(\.monoFontSize) private var monoSize

    var body: some View {
        if viewModel.chunks.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                chunkList
                    .frame(width: 180)
                Rectangle().fill(Color.strongBorder).frame(width: 1)
                if let focused = focusedChunk {
                    chunkBody(focused)
                } else {
                    placeholderBody
                }
            }
            .background(Color.bgInput)
        }
    }

    private var focusedChunk: ConflictChunk? {
        guard let id = viewModel.focusedChunkID else { return nil }
        return viewModel.chunks.first(where: { $0.id == id })
    }

    private var emptyState: some View {
        // Two different reasons land here and they call for opposite
        // things. A modify/delete has no markers because there is nothing
        // to merge line by line — the panes above still show the diff, and
        // the answer is one of the two file-level buttons. Everything else
        // means the markers are gone from a file that had them.
        let deleted = viewModel.conflictKind.map(\.isDeleteConflict) ?? false
        return VStack(spacing: 6) {
            Image(systemName: deleted ? "trash.slash" : "checkmark.seal")
                .scaledFont(22)
                .foregroundStyle(deleted ? .orange : .green)
            Text(deleted
                 ? "Nothing to merge line by line — one side deleted this file"
                 : "No conflict markers in the working tree")
                .scaledFont(12)
                .foregroundStyle(Color.textSecondary)
            Text(deleted
                 ? "Compare BASE with the pane that still has content to see what changed, then Keep File or Delete File."
                 : "Edit the merged pane below and press Save & Stage.")
                .scaledFont(10)
                .foregroundStyle(Color.textDisabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderBody: some View {
        Text("Select a chunk on the left.")
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chunkList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.chunks) { chunk in
                    chunkRow(chunk)
                }
            }
        }
        .background(Color.bgPanel)
    }

    private func chunkRow(_ chunk: ConflictChunk) -> some View {
        let resolution = viewModel.resolution(for: chunk)
        let isFocused = viewModel.focusedChunkID == chunk.id
        let isResolved = resolution != .unresolved
        return HStack(spacing: 6) {
            Image(systemName: isResolved ? "checkmark.circle.fill" : "circle")
                .scaledFont(11)
                .foregroundStyle(isResolved ? .green : Color.textDisabled)
            VStack(alignment: .leading, spacing: 2) {
                Text("Chunk \(chunk.index)")
                    .scaledFont(11, weight: .medium)
                    .foregroundStyle(Color.textPrimary)
                Text("line \(chunk.startLineInOriginal) · \(resolutionLabel(resolution))")
                    .scaledFont(9)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isFocused ? Color.accentBlue.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.focusedChunkID = chunk.id
        }
    }

    private func resolutionLabel(_ r: ConflictChunk.Resolution) -> String {
        switch r {
        case .unresolved:       return "unresolved"
        case .ours:             return "ours"
        case .base:             return "base"
        case .theirs:           return "theirs"
        case .bothOursFirst:    return "both (ours first)"
        case .bothTheirsFirst:  return "both (theirs first)"
        case .neither:          return "neither"
        }
    }

    private func chunkBody(_ chunk: ConflictChunk) -> some View {
        VStack(spacing: 0) {
            // Top strip with per-chunk Take buttons. Keeping them at
            // the top means the user's eyes go: list → action → preview,
            // matching the left-to-right reading flow.
            HStack(spacing: 8) {
                Text("Chunk \(chunk.index) of \(viewModel.chunks.count)")
                    .scaledFont(11, weight: .semibold)
                Spacer()
                Button("Ours")        { viewModel.resolve(chunk: chunk, to: .ours) }
                    .help("Replace this chunk with our version")
                Button("Theirs")      { viewModel.resolve(chunk: chunk, to: .theirs) }
                    .help("Replace this chunk with the incoming version")
                // Beyond Compare's "Take Center", KDiff3's "A": restore the
                // common ancestor, discarding both sides' changes.
                //
                // Never disabled. The BASE pane is right there on screen, so a
                // permanently greyed-out Base button reads as a broken feature
                // rather than as a missing input — when the file's markers
                // carry no ancestor, this offers to add them instead.
                Button("Base") { onTakeBase(chunk) }
                    .help(chunk.baseText == nil
                          ? "This file's conflict markers don't include the ancestor — choose this to add them"
                          : "Restore the common ancestor, discarding both sides' changes")
                Menu("Both") {
                    Button("Ours then Theirs") {
                        viewModel.resolve(chunk: chunk, to: .bothOursFirst)
                    }
                    Button("Theirs then Ours") {
                        viewModel.resolve(chunk: chunk, to: .bothTheirsFirst)
                    }
                }
                .help("Concatenate both sides")
                Button("Neither", role: .destructive) {
                    viewModel.resolve(chunk: chunk, to: .neither)
                }
                .help("Delete the conflicting lines entirely, leaving nothing behind — not the same as Base, which restores the original")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.bgPanelHeader)

            Rectangle().fill(Color.strongBorder).frame(height: 1)

            if let row = selectedRow {
                ConflictLineInspector(
                    row: row,
                    outcome: viewModel.outcome(forRow: row, chunkID: selectedRowChunkID),
                    monoSize: monoSize,
                    syntax: syntax
                )
            } else {
                Text("Click a line in the panes above to see what happens to it.")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.bgInput)
            }
        }
    }
}

/// One aligned line, four ways: what ours has, what the ancestor had, what
/// theirs has, and what the merged file will end up with.
///
/// This is the question a conflict is read line by line to answer — is
/// anything changing here, and to what — and it is the shape Beyond Compare's
/// merge strip uses. The three sides come from the alignment above, so a row
/// where a side simply has no line says so rather than showing a blank that
/// could be an empty line.
///
/// FINAL is the point of it: when the chunk has been resolved it shows the
/// line that will be written, and when it has not it says so instead of
/// showing something that is not true yet.
private struct ConflictLineInspector: View {
    let row: ConflictLineRow
    let outcome: ConflictRowOutcome
    let monoSize: CGFloat
    var syntax: SyntaxLanguage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sideRow(.ours)
            separator
            sideRow(.base)
            separator
            sideRow(.theirs)
            Rectangle().fill(Color.strongBorder).frame(height: 1)
            finalRow
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgInput)
    }

    private var separator: some View {
        Rectangle().fill(Color.borderColor.opacity(0.6)).frame(height: 1)
    }

    private func sideRow(_ side: ConflictLineSide) -> some View {
        let cell = row.cell(for: side)
        return line(
            label: Self.label(side),
            tint: Self.tint(side),
            number: cell.map(\.lineNumber),
            content: cell.map { .text($0.text) } ?? .note("no line on this side"),
            emphasised: false
        )
    }

    @ViewBuilder
    private var finalRow: some View {
        switch outcome {
        case .unchanged(let text):
            line(
                label: "FINAL", tint: .yellow, number: nil,
                content: .text(text), emphasised: true,
                trailing: "unchanged — not part of a conflict"
            )
        case .resolved(let lines) where lines.isEmpty:
            line(
                label: "FINAL", tint: .yellow, number: nil,
                content: .note("nothing — the side you took has no line here"),
                emphasised: true
            )
        case .resolved(let lines):
            line(
                label: "FINAL", tint: .yellow, number: nil,
                content: .text(lines.joined(separator: "\n")), emphasised: true
            )
        case .edited(let lines):
            line(
                label: "FINAL", tint: .yellow, number: nil,
                content: .text(lines.joined(separator: "\n")), emphasised: true,
                trailing: "edited in the merged pane"
            )
        case .unmappable:
            line(
                label: "FINAL", tint: .yellow, number: nil,
                content: .note("this row no longer lines up with the merged pane — read it below"),
                emphasised: true
            )
        case .removed:
            line(
                label: "FINAL", tint: .yellow, number: nil,
                content: .note("nothing — this chunk is being deleted"),
                emphasised: true
            )
        case .undecided:
            line(
                label: "FINAL", tint: .yellow, number: nil,
                content: .note("not resolved yet — the merged file still has this chunk's markers"),
                emphasised: true
            )
        }
    }

    private enum Content {
        case text(String)
        /// Something to say *about* the line rather than the line itself —
        /// drawn as prose so it can never be mistaken for file content.
        case note(String)
    }

    private func line(
        label: String,
        tint: Color,
        number: Int?,
        content: Content,
        emphasised: Bool,
        trailing: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6).padding(.top, 4)
            Text(label)
                .scaledFont(9, weight: .semibold)
                .foregroundStyle(Color.textSecondary)
                .frame(width: 46, alignment: .leading)
            Text(number.map(String.init) ?? "")
                .scaledFont(9, design: .monospaced)
                .foregroundStyle(Color.textDisabled)
                .frame(width: 26, alignment: .trailing)
            switch content {
            case .text(let text):
                ScrollView(.horizontal) {
                    Text(highlighted(text))
                        .font(.mono(size: monoSize))
                        .foregroundStyle(Color.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            case .note(let note):
                Text(note)
                    .scaledFont(10)
                    .italic()
                    .foregroundStyle(Color.textDisabled)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .scaledFont(9)
                    .foregroundStyle(Color.textDisabled)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(emphasised ? Color.bgPanelHeader.opacity(0.6) : Color.clear)
    }

    /// Highlighted a line at a time. A string or comment opened on an earlier
    /// line cannot be known from one line of it — the same trade the chunk
    /// preview made before this, and the commit compare makes with hunks.
    private func highlighted(_ text: String) -> AttributedString {
        guard let syntax, !text.isEmpty else { return AttributedString(text) }
        let perLine = SyntaxHighlighter.highlight(document: text, language: syntax)
        var out = AttributedString()
        for (index, lineText) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { out.append(AttributedString("\n")) }
            let tokens = index < perLine.count ? perLine[index] : []
            for run in CompareTextLayout.runs(
                spans: [DiffSpan(text: lineText, kind: .same)], syntax: tokens
            ) {
                var piece = AttributedString(run.text)
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = run.kind.color
                out.append(piece)
            }
        }
        return out
    }

    private static func label(_ side: ConflictLineSide) -> String {
        switch side {
        case .ours:   return "OURS"
        case .base:   return "BASE"
        case .theirs: return "THEIRS"
        }
    }

    private static func tint(_ side: ConflictLineSide) -> Color {
        switch side {
        case .ours:   return .blue
        case .base:   return .gray
        case .theirs: return .green
        }
    }
}
