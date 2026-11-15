import SwiftUI
import AppKit

/// Side-by-side compare for a single (non-conflicted) file.
///
/// A line-numbered, colour-coded diff between HEAD and the working tree.
/// Adjacent remove + add pairs get intra-line word-level highlighting so you
/// can see *which* characters changed. Clicking a row opens a bottom
/// inspector with both full lines wrapped.
///
/// Editing happens **inside the diff**, in the block being looked at: click a
/// WORKING line and that whole block opens for typing where it sits, caret on
/// the line clicked. There is no mode to turn on — the WORKING column is
/// always open, HEAD never is (it is a committed revision, and there is
/// nothing there to write to).
///
/// A block, rather than a line, because a block is what this window is
/// already showing — the run of rows the aligner grouped as one change — and
/// because it is the smallest unit in which *adding and removing lines* is
/// ordinary typing. Inside its own text, Return and Backspace mean what they
/// mean in any editor; the only thing that changes height is the block, and
/// the pane across the divider is padded by the difference so the two columns
/// stay row-for-row.
///
/// Typing re-colours nothing and moves nothing outside the block. Drafts are
/// held against the diff on screen, drawn plain, and the alignment around
/// them is left exactly as it was. **Save** applies every draft at once and
/// re-runs the compare: that is when line numbers move and colour comes back.
///
/// A working file that is missing or isn't UTF-8 text locks editing
/// entirely — see `workingIsEditable`.
struct FileCompareView: View {
    @Bindable var appState: AppState
    let path: String
    /// Lets the window ask about unsaved edits before it closes. See
    /// `UnsavedEditsGuard`.
    var unsavedEdits: UnsavedEditsGuard? = nil
    /// Repository the file belongs to, when it is not the active one — a
    /// submodule's file, opened from the Submodule window.
    var repoPathOverride: String? = nil
    /// Called after a save when `repoPathOverride` is set, so the window
    /// that opened this compare can reload what it is showing.
    var onSaved: (() async -> Void)? = nil
    /// Closes the window hosting this view. Passed in rather than taken from
    /// `\.dismiss` because the host is a top-level window (see
    /// `CompareWindowPresenter`), not a sheet — SwiftUI has no dismiss action
    /// to offer there.
    let onClose: () -> Void

    @State private var headText: String = ""
    @State private var workingText: String = ""
    @State private var originalWorkingText: String = ""
    @State private var headExists: Bool = true
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?

    /// Where the background compare stands — see `recomputeDiff`.
    @State private var comparePhase: ComparePhase = .idle
    @State private var diffTask: Task<Void, Never>?
    /// The texts the running compare was started for, so a second request
    /// for the same pair joins it instead of starting over.
    @State private var compareInputs: CompareInputs?
    /// Line counts of the two sides, for the progress and stopped states.
    @State private var compareSize: (head: Int, working: Int) = (0, 0)
    /// Set while a compare that should reset folds and the change cursor has
    /// yet to land. A run that replaces it — or a Compare Anyway after it
    /// was stopped — inherits the reset.
    @State private var pendingReset = false
    /// Bumped on every run, so a late timer or result can tell it has been
    /// superseded.
    @State private var compareGeneration = 0

    @State private var rows: [CompareRow] = []
    @State private var resolved: [ResolvedLine] = []
    /// The working buffer split once, so building a section's text is linear
    /// in the section rather than in the file. The hover arrow asks for one
    /// on every row the pointer crosses.
    @State private var workingLines: [String] = []
    /// Row spans the view groups changes into — a run of changes plus the
    /// context kept either side, merged where two runs' context touches.
    ///
    /// The unit this window edits and copies in. It is what the collapsed
    /// view already draws between two folds, which is the whole point: the
    /// thing you can act on is the thing you can see.
    @State private var sections: [ClosedRange<Int>] = []
    @State private var anchors: [Int] = []
    @State private var currentAnchor: Int = -1

    /// Syntax runs for each side, one entry per line of that side's text.
    ///
    /// Computed per *document* rather than per row, which is what makes a
    /// block comment or a docstring colour correctly across every line it
    /// spans — from inside one line there is nothing to see. Both sides are
    /// scanned because they are different documents: a comment opened in HEAD
    /// may be closed in WORKING, or not exist there at all.
    ///
    /// Empty for a file whose language isn't one the highlighter knows, in
    /// which case the panes render exactly as they did before.
    @State private var headSyntax: [[SyntaxToken]] = []
    @State private var workingSyntax: [[SyntaxToken]] = []

    /// The text each side's tokens were produced from, so a rescan is skipped
    /// when that side hasn't changed. Typing in the inspector edits only
    /// WORKING, and it recomputes on every keystroke — there is no reason to
    /// rescan HEAD, which cannot have moved since the file loaded.
    @State private var headSyntaxSource: String = ""
    @State private var workingSyntaxSource: String = ""

    @State private var wrapLines: Bool = false
    /// True when Wrap was turned on by the compare itself because the diff
    /// was too big for the split panes — see `splitPaneRowLimit`.
    @State private var wrapForcedBySize = false
    @State private var collapseUnchanged: Bool = true
    /// Whether a collapsed diff keeps a few unchanged lines around each
    /// change. On by default: a change with nothing around it is hard to
    /// place in the file it came from. Off shows the changed lines alone,
    /// which is what you want when counting or reviewing them.
    @State private var showContext: Bool = true
    /// False for a working file that is missing or isn't UTF-8 text. It still
    /// reads; it may not be written to.
    @State private var workingIsEditable: Bool = true

    /// Blocks the user has retyped, waiting for Save, keyed by the row the
    /// block starts at.
    ///
    /// Drafts rather than writes into `workingText` for one reason: the
    /// buffer is what the diff is computed from, so writing a keystroke
    /// through it would re-align the file under the caret — the block being
    /// typed in can stop matching, or start matching, and move out from under
    /// the cursor mid-word. Held aside, they change nothing outside the block
    /// they belong to. `save()` applies them all at once, and *that* is when
    /// the alignment is allowed to move.
    ///
    /// Keyed by row index, which is stable precisely because nothing
    /// re-aligns while drafts are pending.
    @State private var blockEdits: [Int: BlockEdit] = [:]
    /// The one block with the editor open in it, by the same key.
    @State private var editingBlockRow: Int? = nil
    /// The window this view is in, so its Escape claim can be withdrawn when
    /// the window goes away.
    @State private var hostWindow: ObjectIdentifier? = nil
    /// Where to put the caret when that editor opens: the clicked line's
    /// offset from the top of its block.
    @State private var editingCaretOffset: Int = 0
    /// Whether that caret goes to the end of the line rather than its start.
    /// True when arriving from below — Backspace out of an emptied block puts
    /// the caret where the text ends, which is where typing continues.
    @State private var editingCaretAtLineEnd: Bool = false
    /// Rows pulled out of a fold by the expand arrows, by index.
    ///
    /// Indices rather than "this fold is open": a fold of four hundred
    /// lines opens ten at a time, so what has to be remembered is which
    /// lines are showing, not which markers were clicked.
    @State private var revealedLines: Set<Int> = []

    /// Lines the user has set side by side with Align With, sorted. They
    /// outlive a save or a quiet reload for as long as both lines still say
    /// what they said when pinned; a different file starts with none.
    @State private var pins: [ManualPin] = []
    /// Rows a pin put together, for the marker in the gutter. Rebuilt with
    /// the diff.
    @State private var pinnedRows: Set<Int> = []
    /// The line Align With was chosen on, waiting for a click on the other
    /// side to say where it goes.
    @State private var alignSource: AlignEnd? = nil
    /// The pin just placed, so the compare it causes can select its row.
    @State private var pinToSelect: LineAlignment? = nil

    /// Row index the user clicked to inspect in the bottom detail
    /// panel. Beyond Compare-style: click any line and see its full
    /// HEAD and WORKING text wrapped at the bottom, so long lines no
    /// longer require horizontal scrolling to read.
    @State private var selectedRowIdx: Int? = nil

    /// Set when the file on disk, or HEAD, has moved under edits the user has
    /// not saved — the one case the window cannot quietly catch up with.
    @State private var diskChanged: Bool = false

    /// A Stage & Close in flight, so a second click can't stage twice.
    @State private var isStaging: Bool = false

    /// HEAD row the pointer is over, which decides where the copy arrow sits
    /// and which block it offers. Tracked as a row rather than a block so
    /// moving between two rows of the same block cannot make it flicker —
    /// whichever of the enter/leave pair arrives second still names a row.
    @State private var hoveredHeadRow: Int? = nil

    /// Text the user has dragged across in one of the panes, waiting to be
    /// copied.
    ///
    /// The view's own, rather than SwiftUI's: `.textSelection(.enabled)` is
    /// scoped to a single `Text`, so a drag down a pane stopped dead at the
    /// end of the line it started on. The panes are built out of one `Text`
    /// per row — they have to be, that is what carries the per-row wash, the
    /// gutter and the hatching — so nothing short of running the selection
    /// ourselves lets a drag cross rows.
    @State private var textSelection: CompareSelection? = nil

    /// ⌘F search across both panes.
    @State private var find = TextFindState()
    @FocusState private var findFocused: Bool
    /// Row text per side, indexed like `resolved`, rebuilt with the diff.
    /// Held rather than derived on demand because the find bar re-searches on
    /// every keystroke and re-joining every row's spans each time would make
    /// typing in a large file crawl.
    @State private var searchColumns: [[String]] = [[], []]

    /// Guards the host window's size once it appears. `CompareWindowPresenter`
    /// picks the size the window opens at, so this only has to hold onto it:
    /// it captures user resizes and snaps back anything else, which is how
    /// SwiftUI's auto-fit-to-content is kept from shrinking the window when
    /// Wrap or Collapse changes the content's natural height.
    @StateObject private var windowSize = CompareWindowSizeController(
        minSize: CGSize(width: 700, height: 480)
    )

    /// Locks the two split panes' scroll positions together. Only used in
    /// wrap-off mode — wrap-on already renders both sides inside one scroll
    /// view, so it is aligned by construction.
    @StateObject private var scrollSync = ComparePaneScrollSync()

    @Environment(\.monoFontSize) private var monoSize
    /// Whether tabs are rendered expanded to their column stops, which is
    /// what the drag selection counts its columns in.
    @Environment(\.showWhitespace) private var showWhitespace
    /// App zoom, which the fold markers' label is set at — see
    /// `foldRowHeight`.
    @Environment(\.uiScale) private var uiScale

    /// Unchanged lines kept either side of a change when Context is on.
    /// Three is what `git diff` shows and what the eye needs to recognise
    /// where in a file it is looking.
    private static let contextLineCount = 3

    /// What the collapsed view is currently built with. Both the display and
    /// `revealRow` have to agree on this: fold identity is derived from it,
    /// and a mismatch means the fold being expanded is not the fold on
    /// screen.
    private var contextLines: Int { showContext ? Self.contextLineCount : 0 }

    /// Work that would be lost by closing the window: block drafts no save
    /// has applied yet, plus a buffer a save has not caught up with.
    private var hasUnsavedChanges: Bool {
        workingText != originalWorkingText || !changedBlocks.isEmpty
    }

    /// The drafts that actually say something different from the block they
    /// were opened on. Clicking into a block and back out again is not an
    /// edit, and nor is typing a character and taking it back.
    private var changedBlocks: [BlockEdit] {
        blockEdits.values.filter { $0.removed || $0.text != $0.original }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if find.isPresented {
                FindBar(state: find, isFocused: $findFocused)
            }
            if diskChanged {
                DiskChangedBanner(reload: { Task { await reload() } })
            }
            if let alignSource {
                AlignPromptBanner(source: alignSource, cancel: { self.alignSource = nil })
            }
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .running(showsProgress: true) = comparePhase {
                comparingState
            } else if case .stopped = comparePhase {
                stoppedState
            } else if let err = errorMessage {
                Text(err).foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasNoDifferences {
                identicalState
            } else {
                diffPanes
            }
            Divider()
            actionBar
        }
        // Only `.infinity` here so SwiftUI never folds a content
        // height/width into the window's preferred size — toggling
        // Wrap changes the inner content's natural height, and any
        // `minHeight:` on this frame would let SwiftUI snap the
        // window back to that value. The real minimum lives on the
        // NSWindow via `contentMinSize`.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgPanel)
        .background(copySelectionShortcut)
        .background(WindowFinder { window in
            windowSize.configure(window: window) { handleEscape() }
            // Three separate interceptors take Escape before this view could
            // ever see it: this window's monitor, its `sendEvent`, and the
            // main window's app-wide monitor. Each asks the claim below, which
            // is the only thing all three can agree on — the order they run in
            // is not defined, so it cannot be any one of them that decides.
            (window as? EscapeClosingWindow)?.escapeHandledByContent = {
                unwindEscape()
            }
            appState.claimEscape(for: ObjectIdentifier(window)) { unwindEscape() }
            hostWindow = ObjectIdentifier(window)
        })
        .onDisappear {
            if let hostWindow { appState.releaseEscapeClaim(for: hostWindow) }
            diffTask?.cancel()
        }
        .findBarShortcuts(find, focus: $findFocused)
        // Coming back to the window is when a compare is read again, so it is
        // when it gets to be true. Both notifications: the window can come
        // forward without the app having been away, and the app can come back
        // to a window that was already key.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification
        )) { note in
            guard let window = note.object as? NSWindow,
                  ObjectIdentifier(window) == hostWindow else { return }
            Task { await checkDisk() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            guard let hostWindow,
                  NSApp.keyWindow.map(ObjectIdentifier.init) == hostWindow else { return }
            Task { await checkDisk() }
        }
        .task(id: path) {
            // Pins are lines of the file that was open; the window is reused
            // for the next one.
            pins = []
            alignSource = nil
            await load()
        }
        .onChange(of: headText)    { _, _ in recomputeDiff(resetView: true) }
        // The buffer only moves when a save applies the drafts, or a revert
        // throws them away — never on a keystroke — so this is exactly the
        // "the user asked to see the result" moment, and the only place the
        // alignment re-runs and the colours come back.
        .onChange(of: workingText) { _, _ in recomputeDiff() }
        // Tracked off the derived value rather than off `workingText`: a save
        // leaves the buffer untouched and only moves the baseline, and the
        // window would otherwise go on believing there was work to lose.
        // Wrap mode is a different set of rows in a different pane; a
        // selection made in the split one no longer describes what is drawn.
        .onChange(of: wrapLines) { _, _ in
            textSelection = nil
            if !wrapLines { wrapForcedBySize = false }
        }
        // Context decides how far a section reaches past its changes, so the
        // spans have to be redrawn with it — and any draft held against the
        // old ones let go.
        // Unfolding a large diff hands the split panes every row at once.
        .onChange(of: collapseUnchanged) { _, _ in wrapIfTooLarge() }
        .onChange(of: showContext) { _, _ in
            discardPendingEdits()
            recomputeSections()
        }
        .onChange(of: hasUnsavedChanges) { _, dirty in
            unsavedEdits?.hasUnsavedEdits = dirty
        }

        .task {
            // Re-armed per file: the window is reused for successive compares.
            unsavedEdits?.save = { await save() }
            unsavedEdits?.hasUnsavedEdits = hasUnsavedChanges
        }
        .onExitCommand { handleEscape() }
    }

    /// Both sides say the same thing.
    ///
    /// Only while Collapse is on, which is the switch that already means "do
    /// not draw me the parts that match". Off, the user has asked to read the
    /// file and gets to.
    private var hasNoDifferences: Bool {
        // The find bar is the other way of saying "I want to look inside".
        // Opening it brings the file back, the same as unticking Collapse —
        // a search that reports hits on rows nobody is drawing is worse than
        // the redraw it saves.
        collapseUnchanged && !find.isPresented && !rows.contains(where: \.isChange)
    }

    /// What a compare with nothing to compare shows.
    ///
    /// Not the file. With no changes there is nothing to fold, so the panes
    /// would lay out every line of it — and the split panes draw their rows
    /// eagerly, so a large file spends that on a screen whose only message is
    /// "nothing here". This is the last frame of editing a file back into
    /// agreement with HEAD, and it should be the cheapest one.
    private var identicalState: some View {
        EmptyPanelState(
            icon: "equal.circle",
            title: headExists ? "No differences" : "Nothing to compare",
            message: identicalMessage
        )
    }

    /// Shown while a compare runs, so a file too big to line up quickly
    /// leaves a window that answers — and one that can be told to stop.
    private var comparingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Comparing \(sizeDescription)…")
                .scaledFont(12)
                .foregroundStyle(Color.textSecondary)
            Button("Cancel") { stopCompare() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// After Cancel: the texts are loaded but not lined up.
    private var stoppedState: some View {
        VStack(spacing: 14) {
            EmptyPanelState(
                icon: "stop.circle",
                title: "Compare stopped",
                message: "HEAD has \(sizeDescription). Lining up a change this size can take a while."
            )
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Compare Anyway") { recomputeDiff(resetView: pendingReset) }
                if let repoPath {
                    Button("Open in Editor") {
                        appState.openInEditor(
                            path: URL(fileURLWithPath: repoPath).appendingPathComponent(path).path
                        )
                    }
                }
                Button("Close") { onClose() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sizeDescription: String {
        func lines(_ n: Int) -> String {
            "\(n.formatted()) line\(n == 1 ? "" : "s")"
        }
        return "\(lines(compareSize.head)) and the working file \(lines(compareSize.working))"
    }

    private var identicalMessage: String {
        guard headExists else {
            return "This file is not in HEAD, and there is nothing in it yet."
        }
        let count = max(workingLines.count, 1)
        let lines = "\(count) line\(count == 1 ? "" : "s")"
        return """
        The working file matches HEAD, line for line — all \(lines) of it.
        Untick Collapse to read it here.
        """
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x1")
                .foregroundStyle(Color.accentBlue)
            Text("Compare")
                .scaledFont(13, weight: .semibold)
            Text(path)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if wrapForcedBySize && wrapLines {
                Text("Large diff — wrapped")
                    .scaledFont(10)
                    .foregroundStyle(Color.orange)
                    .help("Too many rows for the side-by-side panes, which lay out every row at once.")
            }

            diffOptions

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(diskChanged ? Color.orange : Color.textSecondary)
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(diskChanged
                  ? "Both sides have moved on disk — read them again (\u{2318}R)"
                  : "Read both sides again from disk (\u{2318}R)")

            // Only for the active repository's own files: staging goes
            // through the main window's index, and a submodule's file is not
            // in it.
            if repoPathOverride == nil {
                Button("Stage & Close") {
                    Task { await stageAndClose() }
                }
                .disabled(!canStage)
                .help(stageHelp)
            }

            Button("Close") { onClose() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bgPanelHeader)
    }

    // MARK: - Stage & Close

    /// The file as the Files panel lists it — what Stage acts on. Nil for a
    /// file with no changes, which a filtered Files panel lists and can open.
    private var changedFile: GitFileStatus? {
        appState.filesVM.files.first { $0.path == path }
    }

    private var canStage: Bool {
        guard let file = changedFile, file.isUnstaged, !file.isSubmodule else { return false }
        return !isLoading && !isStaging && !hasUnsavedChanges
    }

    private var stageHelp: String {
        guard let file = changedFile, file.isUnstaged else {
            return "Nothing here left to stage"
        }
        // Staging takes the file from disk, and unsaved edits are not on it.
        if hasUnsavedChanges { return "Save or revert your edits first" }
        return "Stage this file and close it — with several open, the next tab comes forward"
    }

    /// The review loop for a run of files: read one, stage it, move on.
    ///
    /// Stays open when nothing was staged — a cancelled conflict-marker
    /// warning, a git error — so the file is still there to deal with.
    private func stageAndClose() async {
        guard let file = changedFile, let repo = repoPath else { return }
        isStaging = true
        defer { isStaging = false }
        // `git add` takes the file as it is on disk, so that has to be the
        // file that was reviewed. An editor's autosave or a formatter since
        // would put lines in the index that nobody looked at.
        let sides = await readSides(repo: repo)
        if sides.working != originalWorkingText {
            guard appState.platform.confirmWarning(
                title: "Stage the changed file?",
                message: """
                \(path) has changed on disk since this compare was read.

                Staging takes the file as it is now, including lines you \
                haven't seen here.
                """,
                primaryButton: "Stage Anyway"
            ) else {
                // Show what is there now, so it can be reviewed.
                apply(sides)
                return
            }
        }
        if await appState.stage(files: file.affectedPaths) { onClose() }
    }

    @ViewBuilder
    private var diffOptions: some View {
        Toggle("Wrap", isOn: $wrapLines)
            .toggleStyle(.checkbox)
            .scaledFont(10)
            .help(wrapForcedBySize
                  ? "Turned on because this diff is too large for the side-by-side panes, which lay out every row at once. Unticking it may make the window unresponsive."
                  : "Wrap long lines instead of truncating with …")

        Toggle("Collapse", isOn: $collapseUnchanged)
            .toggleStyle(.checkbox)
            .scaledFont(10)
            .help("Hide the unchanged parts of the file")

        Toggle("Context", isOn: $showContext)
            .toggleStyle(.checkbox)
            .scaledFont(10)
            .disabled(!collapseUnchanged)
            .help(collapseUnchanged
                  ? "Keep \(Self.contextLineCount) unchanged lines above and below each change. Off shows the changed lines only."
                  : "Only applies when Collapse is on")

        Toggle("Whitespace", isOn: whitespaceBinding)
            .toggleStyle(.checkbox)
            .scaledFont(10)
            .help("Show spaces as \u{00B7}, tabs as \u{2192} and line ends as \u{00B6}")

        // The way back from Align With, where it can be seen: a pin moves
        // lines around for as long as it stands.
        if !pins.isEmpty {
            Button {
                removePins(pins.map(\.alignment))
            } label: {
                Label("\(pins.count) aligned", systemImage: "pin.slash")
                    .scaledFont(10)
            }
            .disabled(!canAlign)
            .help(canAlign
                  ? "Remove the \(pins.count == 1 ? "line alignment" : "\(pins.count) line alignments") set with Align With"
                  : alignBlockedHelp)
        }

        let changeCount = anchors.count
        Text("\(changeCount) change\(changeCount == 1 ? "" : "s")")
            .scaledFont(10)
            .foregroundStyle(Color.textSecondary)

        Button {
            jump(by: -1)
        } label: {
            Image(systemName: "chevron.up")
        }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(changeCount == 0)
        .help("Previous change (⌘K)")

        Button {
            jump(by: 1)
        } label: {
            Image(systemName: "chevron.down")
        }
        .keyboardShortcut("j", modifiers: .command)
        .disabled(changeCount == 0)
        .help("Next change (⌘J)")

        // The copy the hover arrow offers, for the times the pointer is not
        // the thing in hand: a block picked with ⌘J / ⌘K, or a run of them
        // dragged across. Same command, same rule about what it acts on.
        Button {
            copyBlocksFromHead()
        } label: {
            Image(systemName: "arrow.right.to.line")
        }
        .keyboardShortcut(.rightArrow, modifiers: .option)
        .disabled(editingBlockRow != nil || !hasBlocksToCopy)
        .help(copyCommandHelp)
    }

    /// What the toolbar copy would do right now, named so the button is not
    /// a mystery arrow. Counts blocks rather than building them.
    private var copyCommandHelp: String {
        guard workingIsEditable else { return "This file cannot be written to" }
        guard editingBlockRow == nil else { return "Close the section editor first" }
        guard hasBlocksToCopy else {
            return "Select a change, or point at one with ⌘J / ⌘K, to copy its section from HEAD"
        }
        let count = blocksToCopy().count
        return count > 1
            ? "Copy \(count) sections from HEAD over WORKING (\u{2325}\u{2192})"
            : "Copy this section from HEAD over WORKING (\u{2325}\u{2192})"
    }

    /// Written through `AppState` rather than straight at the config field,
    /// so ticking the box in any of the three places that offer it persists
    /// and reaches every other diff view.
    private var whitespaceBinding: Binding<Bool> {
        Binding(
            get: { appState.appConfig.showWhitespace },
            set: { appState.setShowWhitespace($0) }
        )
    }

    /// Escape, one step at a time, innermost first: leave the block editor,
    /// then dismiss the find bar, then close the window. Pressing it once
    /// while typing should not also send the window away — it used to do
    /// exactly that, because this window takes Escape before anything inside
    /// it can.
    @discardableResult
    private func handleEscape() -> Bool {
        if unwindEscape() { return true }
        return closeFromEscape()
    }

    /// The steps that belong to the view. Returns true when one of them
    /// consumed the key, which is what stops the same press from closing the
    /// window as well.
    private func unwindEscape() -> Bool {
        if alignSource != nil {
            alignSource = nil
            return true
        }
        if editingBlockRow != nil {
            // Leaves the editor and keeps what was typed. The draft is
            // unsaved work either way, and a key that both exits and destroys
            // is a key people stop pressing; "Discard Block Edit" on the row
            // menu is how a block is actually thrown away.
            closeEditor()
            return true
        }
        if textSelection != nil {
            textSelection = nil
            return true
        }
        if find.isPresented {
            find.dismiss()
            return true
        }
        return false
    }

    @discardableResult
    private func closeFromEscape() -> Bool {
        guard appState.appConfig.escapeClosesSubwindows else { return false }
        onClose()
        return true
    }

    // MARK: - In-place block editing

    /// Opens the block `idx` sits in for typing, right where it is in the
    /// diff.
    ///
    /// A block, not a line, because a block is what the window is already
    /// showing: the run of rows the aligner grouped together as one change.
    /// It is also the smallest unit in which adding and removing lines means
    /// anything — inside its own text they are ordinary editing, and only the
    /// block's own height changes.
    private func beginEditing(row idx: Int) {
        guard workingIsEditable, let block = blockEdit(containing: idx) else {
            return selectRow(idx)
        }
        selectedRowIdx = idx
        // The caret goes to the line that was clicked, counted from the top
        // of the block — the offset survives a draft that has already had
        // lines added above the click, which a line number would not.
        editingCaretOffset = max(0, workingLineNumber(at: idx).map {
            $0 - block.workingStart
        } ?? 0)
        editingCaretAtLineEnd = false
        blockEdits[block.rowStart] = blockEdits[block.rowStart] ?? block
        editingBlockRow = block.rowStart
    }

    /// Clicking outside the open editor: it closes and keeps what is in it.
    private func selectRow(_ idx: Int) {
        closeEditor()
        selectedRowIdx = idx
    }

    /// Backspace in a block with nothing left in it: the block goes, and
    /// typing carries on at the end of the block above.
    ///
    /// The same move a text editor makes when Backspace runs out of line, and
    /// the only way to take a block out entirely — the draft stays, empty,
    /// and an empty draft removes the lines rather than blanking them (see
    /// `TextBufferEdits.replacing`).
    private func mergeIntoBlockAbove(from rowStart: Int) {
        editingBlockRow = nil
        blockEdits[rowStart]?.removed = true
        guard let above = previousWorkingRow(before: rowStart),
              let block = blockEdit(containing: above)
        else { return }
        // The block above may be folded away — Collapse hides unchanged runs,
        // and an editor on a row with no view to draw it in would look like
        // Backspace did nothing.
        revealRow(above)
        blockEdits[block.rowStart] = blockEdits[block.rowStart] ?? block
        editingCaretOffset = max(0, TextBufferEdits.lines(of: block.text).count - 1)
        editingCaretAtLineEnd = true
        editingBlockRow = block.rowStart
        selectedRowIdx = above
    }

    /// Nearest row above `rowStart` with a working line to edit, skipping the
    /// placeholder half of a remove+add pair.
    private func previousWorkingRow(before rowStart: Int) -> Int? {
        for i in stride(from: rowStart - 1, through: 0, by: -1) where i < resolved.count {
            if !resolved[i].hidden, resolved[i].rightLine != nil { return i }
        }
        return nil
    }

    /// Leaves the editor, keeping the draft — unless nothing was typed into
    /// it. A block that was clicked into and left alone is not an edit, and
    /// holding its draft would keep the row drawn plain, out of the coloured
    /// diff it still belongs to.
    private func closeEditor() {
        guard let row = editingBlockRow else { return }
        editingBlockRow = nil
        if let edit = blockEdits[row], !edit.removed, edit.text == edit.original {
            blockEdits[row] = nil
        }
    }

    /// The block whose draft covers `idx`, open or not — the row renderers
    /// ask this to know whether to draw their own text or stand aside for the
    /// block's.
    private func draftedBlock(at idx: Int) -> BlockEdit? {
        blockEdits.values.first { $0.contains(row: idx) }
    }

    /// The draft for the block containing `idx`, creating it from the file if
    /// this is the first click into that block.
    private func blockEdit(containing idx: Int) -> BlockEdit? {
        if let existing = draftedBlock(at: idx) { return existing }
        guard idx < rows.count else { return nil }

        // The section the row belongs to — the run of changes around it plus
        // the context the view keeps either side, which is exactly what is
        // drawn between two folds. A row outside every section is an
        // unchanged line somebody expanded to read, and is a line of its own.
        let span = section(containing: idx) ?? idx...idx
        let first = span.lowerBound
        let last = min(span.upperBound, rows.count - 1)
        guard first <= last else { return nil }

        let working = (first...last).compactMap { rows[$0].rightLine }
        // A section with nothing on the working side is a pure deletion:
        // there is no text to edit, but there is a place to type — right
        // after the last working line above it, which is where those lines
        // were.
        let start = working.first ?? ((lastWorkingLine(atOrAbove: first) ?? 0) + 1)
        let text = working.isEmpty ? "" : working.map(line(_:)).joined(separator: "\n")
        // Rows the HEAD pane will actually draw, which is not the span: a
        // remove+add pair is two rows of the alignment rendered as one, with
        // the second kept only so `resolved` stays index-aligned. Counting the
        // span instead would pad the block by a phantom row per pair.
        let drawn = (first...last).filter { $0 < resolved.count && !resolved[$0].hidden }
        return BlockEdit(
            rowStart: first,
            rowEnd: last,
            headRows: drawn.count,
            headLastRow: drawn.last ?? last,
            workingStart: start,
            workingCount: working.count,
            original: text,
            text: text,
            gaps: gapRows(first: first, last: last),
            lineRows: drawn.map { r in
                BlockEdit.LineRow(
                    row: r,
                    head: resolved[r].leftLine == nil ? nil : rows[r].leftText,
                    working: resolved[r].rightLine.map(line(_:))
                )
            }
        )
    }

    private func line(_ number: Int) -> String {
        workingLines.indices.contains(number - 1) ? workingLines[number - 1] : ""
    }

    /// Where a section's working side has nothing to show, in rows.
    ///
    /// A section can hold lines HEAD has and the working file does not, and
    /// they sit *between* working lines rather than after them. Entry `k` is
    /// how many blank rows belong before working line `k`, with a trailing
    /// entry for the ones past the last.
    ///
    /// Rows rather than characters. The alternative — filler lines in the
    /// editor's own text — puts characters in front of the user that are not
    /// in the file, and every rule for taking them out again on save can be
    /// made to eat a real line that happens to look like one.
    private func gapRows(first: Int, last: Int) -> [Int] {
        LineDiff.gapRows(
            hasWorkingLine: (first...last)
                .filter { $0 < resolved.count && !resolved[$0].hidden }
                .map { resolved[$0].rightLine != nil }
        )
    }

    // MARK: - Copy a block from HEAD

    /// HEAD's lines for a block, in order. Empty for a block that exists only
    /// on the working side — lines the user added, which HEAD has nothing to
    /// say about and copying therefore takes away.
    private func headLines(of block: BlockEdit) -> [String] {
        let last = min(block.rowEnd, rows.count - 1)
        guard block.rowStart <= last else { return [] }
        return (block.rowStart...last).compactMap { rows[$0].leftText }
    }

    /// Overwrite the working side of `block` with what HEAD has there —
    /// Beyond Compare's "Copy to Right", in the only direction this window
    /// has one: HEAD is a committed revision and cannot be written to.
    ///
    /// Three shapes, one operation. A block both sides have becomes HEAD's
    /// text; a block only HEAD has is put back; a block only the working file
    /// has goes away. All three are already expressible as a draft, which is
    /// what makes this a small change and what keeps it consistent with
    /// typing: nothing touches the file until Save, Revert Edits takes it
    /// back, and the row menu's "Discard Block Edit" takes back just this one.
    private func copyFromHead(_ block: BlockEdit) {
        guard workingIsEditable else { return }
        let existing = blockEdits[block.rowStart] ?? block
        blockEdits[block.rowStart] = existing.takingFromHead(rows: Set(existing.lineRows.map(\.row)))
    }

    /// The same copy, one row of the block wide: that row's working line
    /// becomes HEAD's, comes back from HEAD, or goes — and the rest of the
    /// block stays as the file has it.
    ///
    /// The quick way to take out one line the user added, say a comment,
    /// which otherwise means opening the block and selecting the line away.
    private func copyLineFromHead(row: Int) {
        guard workingIsEditable else { return }
        // First, so an editor opened on this block and left untouched lets go
        // of its draft rather than holding the stale one.
        closeEditor()
        textSelection = nil
        guard let block = blockEdit(containing: row), block.canTakeLineFromHead(row: row)
        else { return }
        blockEdits[block.rowStart] = block.takingFromHead(rows: [row])
    }

    /// The blocks a copy command acts on: the ones a drag selection touches,
    /// or the single block the view is otherwise pointed at.
    ///
    /// Beyond Compare's rule is "selected lines or current section". Rounded
    /// out to whole blocks here, because a block is the unit the alignment
    /// guarantees a position for — half of one has no unambiguous place to
    /// land on the other side when the two sides hold different numbers of
    /// lines.
    private func blocksToCopy() -> [BlockEdit] {
        if let selection = textSelection, !selection.isEmpty {
            var found: [BlockEdit] = []
            var row = selection.start.row
            // Stepping past each section rather than through it: building one
            // reads the working buffer, and asking per row would make a wide
            // selection quadratic.
            while row <= selection.end.row, row < rows.count {
                guard sectionHasChange(at: row), let block = blockEdit(containing: row) else {
                    row += 1
                    continue
                }
                found.append(block)
                row = max(block.rowEnd + 1, row + 1)
            }
            if !found.isEmpty { return found }
        }
        guard let row = copyTargetRow, sectionHasChange(at: row),
              let block = blockEdit(containing: row)
        else { return [] }
        return [block]
    }

    /// Whether the section `idx` falls in holds a change.
    ///
    /// The only kind worth copying: a section's context lines are the same on
    /// both sides by construction, so copying them writes back what is
    /// already there. It is also why the copy follows the section rather than
    /// the changed run inside it — over the context the two are the same
    /// operation, and one unit for editing and copying alike is one thing to
    /// explain.
    private func sectionHasChange(at idx: Int) -> Bool {
        guard let span = section(containing: idx) else { return false }
        return span.contains { rows.indices.contains($0) && rows[$0].kind != .same }
    }

    /// Whether a copy command has anything to act on.
    ///
    /// Asked on every render, by the toolbar button's enabled state and the
    /// shortcut's — so it answers from the row kinds alone. `blocksToCopy`
    /// builds drafts, and building one reads the working buffer.
    private var hasBlocksToCopy: Bool {
        guard workingIsEditable else { return false }
        if let selection = textSelection, !selection.isEmpty {
            let last = min(selection.end.row, rows.count - 1)
            guard selection.start.row <= last else { return false }
            return (selection.start.row...last).contains { rows[$0].kind != .same }
        }
        guard let row = copyTargetRow else { return false }
        return sectionHasChange(at: row)
    }

    /// The row a copy falls on when nothing is selected: the row last clicked,
    /// else wherever ⌘J / ⌘K has left the change cursor.
    private var copyTargetRow: Int? {
        if let selectedRowIdx, rows.indices.contains(selectedRowIdx) { return selectedRowIdx }
        return anchorRowID
    }

    private func copyBlocksFromHead() {
        let blocks = blocksToCopy()
        guard !blocks.isEmpty else { return }
        for block in blocks { copyFromHead(block) }
        // The rows it named are about to say something else.
        textSelection = nil
        closeEditor()
    }

    /// A binding into the draft of the block that starts at `row`.
    private func blockBinding(rowStart: Int) -> Binding<String> {
        Binding(
            get: { blockEdits[rowStart]?.text ?? "" },
            set: { text in
                blockEdits[rowStart]?.text = text
                // Whatever the copy meant by an empty block, the user is
                // typing in it now and means what the editor has always
                // meant: empty takes the lines out.
                blockEdits[rowStart]?.emptyIsOneBlankLine = false
            }
        )
    }

    /// Escape: throw this block's draft away and close the editor. Every
    /// other way out keeps it — the draft is unsaved work either way, and
    /// losing it to a stray click would be its own bug.
    private func cancelEditing(rowStart: Int) {
        blockEdits[rowStart] = nil
        if editingBlockRow == rowStart { editingBlockRow = nil }
    }

    /// The working line number at `idx`, or the nearest one above it.
    private func workingLineNumber(at idx: Int) -> Int? {
        guard idx < resolved.count else { return nil }
        return resolved[idx].rightLine ?? lastWorkingLine(atOrAbove: idx)
    }

    private func discardPendingEdits() {
        blockEdits = [:]
        editingBlockRow = nil
        editingCaretOffset = 0
    }

    /// Height of one rendered row, and so of one line inside a block editor.
    ///
    /// Computed from the font rather than measured from the views: the two
    /// panes have to agree on it exactly. A block whose editor is a hair
    /// taller per line than the HEAD rows beside it would walk the two
    /// columns apart by a pixel per line, which over a twenty-line block is
    /// a visible drift — and the alignment is the whole point of this view.
    private var lineHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular)
        return ceil(NSLayoutManager().defaultLineHeight(for: font))
    }

    /// Vertical padding a row carries above and below its text.
    private static let rowPadding: CGFloat = 1

    private var rowHeight: CGFloat { lineHeight + Self.rowPadding * 2 }

    /// Height of a "N unchanged lines hidden" marker. Fixed for the same
    /// reason `rowHeight` is: the drag hit-testing walks the row list adding
    /// heights, and a fold it cannot measure is a fold it cannot walk past.
    ///
    /// Rounded up rather than measured — the expand arrows sit in 18pt cells
    /// and the label is an 11pt system font at the app's zoom, so this is the
    /// taller of the two plus the marker's own padding. Over-estimating costs
    /// a spare point of row; under-estimating would clip the label.
    private var foldRowHeight: CGFloat {
        max(18, ceil(11 * uiScale * 1.4)) + 12
    }

    /// Lines a draft will actually put in the file, and so rows it takes on
    /// screen. An emptied block is none of them — it is on its way out, and
    /// drawing it as one blank row would be showing a line the save will not
    /// write.
    private func draftRowCount(_ edit: BlockEdit) -> Int {
        if edit.text.isEmpty { return edit.emptyIsOneBlankLine ? 1 : 0 }
        return TextBufferEdits.lines(of: edit.text).count
    }

    /// How tall a block is on each side, in rows: HEAD keeps the rows the
    /// diff gave it, WORKING has however many lines the draft now holds.
    /// Whichever is shorter is padded out, so the row after the block starts
    /// at the same Y in both panes.
    private func blockPadding(_ edit: BlockEdit, side: ComparePaneSide) -> CGFloat {
        // Gaps count: they are rows the working side holds open for lines
        // only HEAD has, so a section that has not been typed in comes out
        // exactly as tall as HEAD's rows and needs no padding at all.
        let workingRows = draftRowCount(edit) + edit.totalGapRows
        let mine = side == .left ? edit.headRows : workingRows
        return CGFloat(max(edit.headRows, workingRows) - mine) * rowHeight
    }

    /// Rows a section's working column occupies: its lines plus the space
    /// kept open between them.
    private func blockCellRows(_ edit: BlockEdit) -> Int {
        max(draftRowCount(edit), 1) + edit.totalGapRows
    }

    // MARK: - Drag selection

    /// ⌘C for the pane selection, with nothing on screen to press.
    ///
    /// The panes have no Copy control of their own — the row menu offers the
    /// command by name — but a selection the keyboard cannot copy is not a
    /// selection. Disabled wherever the window has a text field of its own in
    /// hand — a block editor, the find bar — which is what hands ⌘C back to
    /// whatever the user is actually typing in.
    private var copySelectionShortcut: some View {
        Button("Copy Selection") { copySelection() }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(textSelection == nil || editingBlockRow != nil || findFocused)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The rows on screen, folds included, in the order both panes draw them.
    private var displayRows: [DiffDisplayRow] {
        collapseUnchanged
            ? LineDiff.collapse(rows: rows, contextLines: contextLines, revealed: revealedLines)
            : rows.indices.map { .row($0) }
    }

    /// One pane's vertical layout, entry by entry, at the heights it draws
    /// them — which is what turns a drag's Y offset back into a row.
    ///
    /// Arithmetic rather than measurement. Every split row is pinned to
    /// `rowHeight` and every fold to `foldRowHeight` for exactly this, and
    /// the alternative — a `GeometryReader` behind each row — would put a
    /// measurement pass behind a view that already draws every row it shows.
    private func paneLayout(display: [DiffDisplayRow], side: ComparePaneSide) -> CompareRowLayout {
        var metrics: [CompareRowMetric] = []
        metrics.reserveCapacity(display.count)
        for entry in display {
            switch entry {
            case .fold:
                metrics.append(CompareRowMetric(row: nil, height: foldRowHeight))
            case .row(let idx):
                guard idx < resolved.count, !resolved[idx].hidden else {
                    // The placeholder half of a remove+add pair. Drawn as
                    // nothing, so it takes no height here either.
                    metrics.append(CompareRowMetric(row: nil, height: 0))
                    continue
                }
                guard let edit = draftedBlock(at: idx) else {
                    metrics.append(CompareRowMetric(row: idx, height: rowHeight))
                    continue
                }
                if side == .right {
                    // A drafted block is one cell on this side, and its text
                    // is the draft rather than the diff — nothing the pane
                    // selection can speak for, so it holds space and no row.
                    let height = idx == edit.rowStart
                        ? blockCellHeight(edit) + blockPadding(edit, side: .right)
                        : 0
                    metrics.append(CompareRowMetric(row: nil, height: height))
                } else {
                    let pad = idx == edit.headLastRow ? blockPadding(edit, side: .left) : 0
                    metrics.append(CompareRowMetric(row: idx, height: rowHeight + pad))
                }
            }
        }
        return CompareRowLayout(metrics: metrics)
    }

    /// What `blockCell` lays out to: one row's height per drafted line, or
    /// nothing at all for a block backspaced away and left alone.
    private func blockCellHeight(_ edit: BlockEdit) -> CGFloat {
        guard draftRowCount(edit) > 0 || editingBlockRow == edit.rowStart else { return 0 }
        return CGFloat(blockCellRows(edit)) * rowHeight
    }

    /// One row of one pane exactly as it is drawn — tabs expanded when
    /// whitespace is revealed, because that is what the columns a drag
    /// resolves are counted in.
    ///
    /// Nil where the side has no line at all: an absent row is hatched, not
    /// blank, and a selection running through it should copy nothing rather
    /// than an empty line the file does not contain.
    private func renderedText(row: Int, side: ComparePaneSide) -> String? {
        guard row >= 0, row < resolved.count, !resolved[row].hidden else { return nil }
        let spans = side == .left ? resolved[row].leftSpans : resolved[row].rightSpans
        guard !spans.isEmpty else { return nil }
        let raw = spans.map(\.text).joined()
        return showWhitespace ? CompareTextLayout.revealed(raw).text : raw
    }

    private func selectionRange(row: Int, side: ComparePaneSide) -> Range<Int>? {
        guard let selection = textSelection, selection.side == side,
              selection.covers(row: row),
              let text = renderedText(row: row, side: side)
        else { return nil }
        return selection.range(onRow: row, length: text.count)
    }

    /// Drag anywhere in a pane to select across its rows.
    ///
    /// Lives on the pane rather than on each row: a gesture attached to a row
    /// would only ever hear about the row it started in, and the whole point
    /// is the drag that leaves it. `startLocation` and `location` both arrive
    /// in the scrolling content's own coordinates, so a selection survives
    /// the pane scrolling under it mid-drag.
    private func selectionDrag(
        side: ComparePaneSide,
        display: [DiffDisplayRow],
        space: String
    ) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
            .onChanged { value in
                let layout = paneLayout(display: display, side: side)
                guard let anchorRow = layout.row(atY: value.startLocation.y),
                      let focusRow = layout.row(atY: value.location.y)
                else { return }
                if textSelection == nil {
                    // Starting a selection is leaving the editor: ⌘C has to
                    // mean one of the two, and it means whichever the user
                    // touched last.
                    closeEditor()
                }
                textSelection = CompareSelection(
                    side: side,
                    anchor: ComparePoint(
                        row: anchorRow,
                        column: column(atX: value.startLocation.x, row: anchorRow, side: side)
                    ),
                    focus: ComparePoint(
                        row: focusRow,
                        column: column(atX: value.location.x, row: focusRow, side: side)
                    )
                )
            }
    }

    /// Shift-click: keep the anchor where it is and move the far end to the
    /// clicked row, whole lines at a time. A column would be guesswork — the
    /// click that carries Shift is a click on a row, not on a character.
    private func extendSelection(to row: Int, side: ComparePaneSide) {
        guard var selection = textSelection, selection.side == side else { return }
        let length = renderedText(row: row, side: side)?.count ?? 0
        selection.focus = ComparePoint(
            row: row,
            column: row < selection.anchor.row ? 0 : length
        )
        textSelection = selection
    }

    private func column(atX x: CGFloat, row: Int, side: ComparePaneSide) -> Int {
        guard let text = renderedText(row: row, side: side) else { return 0 }
        return CompareTextHitTest.column(
            in: text,
            fontSize: monoSize,
            x: x - HalfRowView.textOriginX
        )
    }

    /// The selection as text: the selected part of every row it touches, in
    /// the order the pane draws them.
    ///
    /// Folded-away rows are not in it — they are not on screen, and a drag
    /// past a fold marker means "from here to there", not "and the four
    /// hundred lines you have collapsed". Rows with no line on this side
    /// contribute nothing rather than a blank line.
    private func selectionText() -> String? {
        guard let selection = textSelection, !selection.isEmpty else { return nil }
        var parts: [String] = []
        for entry in displayRows {
            guard case .row(let idx) = entry, selection.covers(row: idx) else { continue }
            // The WORKING side of a drafted block draws the draft, not the
            // diff; `paneLayout` keeps a selection out of it, and a selection
            // running across it skips it here for the same reason.
            if selection.side == .right, draftedBlock(at: idx) != nil { continue }
            guard let text = renderedText(row: idx, side: selection.side) else { continue }
            let characters = Array(text)
            if let range = selection.range(onRow: idx, length: characters.count) {
                parts.append(String(characters[range]))
            } else {
                parts.append("")
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    private func copySelection() {
        guard let text = selectionText() else { return }
        appState.copyToPasteboard(text)
    }

    // MARK: - Diff (compare) mode

    private var diffPanes: some View {
        let display = displayRows

        return VStack(spacing: 0) {
            Group {
                if wrapLines {
                    wrapDiffPanes(display: display)
                } else {
                    splitDiffPanes(display: display)
                }
            }
            // Not for a row inside a drafted block: the strip would be
            // quoting the text from disk at a block the user has retyped.
            if let idx = selectedRowIdx,
               idx < resolved.count,
               !resolved[idx].hidden,
               draftedBlock(at: idx) == nil
            {
                Divider()
                lineDetailPanel(line: resolved[idx])
            }
        }
    }

    /// Wrap-on: a single vertical `ScrollView` with row-major HStacks
    /// (HEAD cell · divider · WORKING cell). Long lines wrap inside
    /// each cell — the shared HStack guarantees the two columns stay
    /// aligned even when left and right cells wrap to different line
    /// counts.
    private func wrapDiffPanes(display: [DiffDisplayRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    Section {
                        ForEach(display, id: \.id) { entry in
                            switch entry {
                            case .row(let idx):
                                // A drafted block is one row here: HEAD's
                                // lines beside the draft's, both multi-line
                                // in a single HStack, which is how wrap mode
                                // keeps two columns of different heights
                                // aligned without any arithmetic.
                                if let edit = draftedBlock(at: idx) {
                                    if idx == edit.rowStart {
                                        wrapBlockRow(edit)
                                            .id("row-\(idx)")
                                    }
                                } else if idx < resolved.count, !resolved[idx].hidden {
                                    CompareRowView(
                                        line: resolved[idx],
                                        wrapLines: true,
                                        leftSyntax: syntax(for: resolved[idx].leftLine, side: .left),
                                        rightSyntax: syntax(for: resolved[idx].rightLine, side: .right),
                                        leftMatches: find.matches(onLine: idx, column: 0),
                                        rightMatches: find.matches(onLine: idx, column: 1),
                                        currentMatch: find.current,
                                        // While Align With waits for its
                                        // second line, the WORKING cell is
                                        // where that click lands — editable
                                        // file or not.
                                        onEditWorking: alignSource != nil
                                            ? { alignClick(row: idx, side: .right) }
                                            : workingIsEditable
                                                ? { beginEditing(row: idx) }
                                                : nil
                                    )
                                    .id("row-\(idx)")
                                    .background(rowSelectionBackground(idx: idx))
                                    .overlay(alignment: .leading) { alignMarks(idx: idx, side: nil) }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if alignSource != nil {
                                            alignClick(row: idx, side: .left)
                                        } else {
                                            selectRow(idx)
                                        }
                                    }
                                    .contextMenu { rowCopyMenu(idx, side: nil) }
                                }
                            case .fold(let start, let count):
                                FoldMarkerRow(
                                    hiddenCount: count,
                                    chunk: Self.expandChunk,
                                    expandDown: { revealFromTop(start: start, count: count) },
                                    expandUp: { revealFromBottom(start: start, count: count) },
                                    expandAll: { revealAll(start: start, count: count) },
                                    firstLeftLine: firstLeftLineNumber(from: start),
                                    firstRightLine: firstRightLineNumber(from: start)
                                )
                                .id(entry.id)
                            }
                        }
                    } header: {
                        paneHeaders
                    }
                }
            }
            .background(Color.bgInput)
            .onChange(of: currentAnchor) { _, idx in
                guard idx >= 0, idx < anchors.count else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("row-\(anchors[idx])", anchor: .center)
                }
            }
            .onChange(of: find.current) { _, match in
                guard let match else { return }
                revealRow(match.line)
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("row-\(match.line)", anchor: .center)
                }
            }
        }
    }

    /// Wrap-off: two side-by-side `ScrollView`s, each with its own
    /// horizontal scroll for long lines. The two panes are pinned to
    /// exactly half the viewport via `GeometryReader` so the wide
    /// intrinsic content can't push the HStack out of balance.
    ///
    /// The panes scroll as one, on both axes: `ComparePaneScrollSync`
    /// mirrors whichever side the user drags onto the other, so a row and
    /// its counterpart stay on the same line of the screen. Change-jumping
    /// (⌘J / ⌘K) additionally drives both panes through their own
    /// `ScrollViewReader` proxies — the two animations are identical, so the
    /// mirror sees no difference to correct and stays out of the way.
    private func splitDiffPanes(display: [DiffDisplayRow]) -> some View {
        GeometryReader { geo in
            let paneWidth = max(0, (geo.size.width - 1) / 2)
            HStack(spacing: 0) {
                diffSideColumn(
                    side: .left,
                    display: display,
                    paneWidth: paneWidth,
                    title: "HEAD",
                    subtitle: headExists ? "last committed" : "not in HEAD",
                    tint: .blue
                )
                Divider()
                diffSideColumn(
                    side: .right,
                    display: display,
                    paneWidth: paneWidth,
                    title: "WORKING",
                    subtitle: workingSubtitle,
                    tint: hasUnsavedChanges ? .orange : .green
                )
            }
            .background(Color.bgInput)
        }
    }

    private func diffSideColumn(
        side: ComparePaneSide,
        display: [DiffDisplayRow],
        paneWidth: CGFloat,
        title: String,
        subtitle: String,
        tint: Color
    ) -> some View {
        VStack(spacing: 0) {
            paneHeader(title: title, subtitle: subtitle, tint: tint)
            ScrollViewReader { proxy in
                // GeometryReader gives the viewport height so short content can
                // be pinned to the top. A two-axis ScrollView otherwise
                // *centers* content smaller than the viewport (unlike a
                // single-axis one), which left the rows floating mid-pane.
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(display, id: \.id) { entry in
                                splitRowEntry(entry: entry, side: side, paneWidth: paneWidth)
                                    .id(entry.id)
                            }
                        }
                        // Both axes — the resolver's `ConflictDiffPanes` uses
                        // the same top-pinning rule for its split columns.
                        // A short file's rows are narrower than the pane, and a
                        // two-axis ScrollView would centre them.
                        .frame(
                            minWidth: geo.size.width,
                            minHeight: geo.size.height,
                            alignment: .topLeading
                        )
                        // Sits inside the ScrollView so it can hand the
                        // backing NSScrollView to the sync controller.
                        .background(EnclosingScrollViewFinder { scrollView in
                            scrollSync.register(scrollView, as: side)
                        })
                        // So a drag can start in the empty space under the
                        // last row, which a container otherwise leaves to
                        // whatever is behind it.
                        .contentShape(Rectangle())
                        // Named so the drag reports its points in the rows'
                        // own coordinates rather than the viewport's, which
                        // is what lets a selection survive the pane scrolling
                        // under it. Lower priority than the rows' own tap and
                        // context menu: a click still inspects or edits a
                        // row, and only a drag reaches this.
                        .coordinateSpace(name: Self.paneSpace(side))
                        .gesture(selectionDrag(
                            side: side,
                            display: display,
                            space: Self.paneSpace(side)
                        ))
                    }
                    // The copy arrow rides the *viewport*, not the rows: a
                    // long line scrolls the pane sideways, and a button drawn
                    // beside the text would ride off with it. The hovered row
                    // reports where it sits in these coordinates and the
                    // button is placed at that height, hard against the
                    // divider, wherever the pane happens to be scrolled to.
                    .coordinateSpace(name: Self.paneViewportSpace(side))
                    .overlayPreferenceValue(CopyArrowRowKey.self) { anchor in
                        if side == .left, let anchor, let block = hoveredCopyBlock {
                            Group {
                                if let row = lineCopyRow(in: block) {
                                    copyLineFromHeadButton(row: row, block: block)
                                } else {
                                    copyFromHeadButton(block)
                                }
                            }
                                .position(
                                    x: geo.size.width - Self.copyArrowInset,
                                    y: min(max(anchor, 0), geo.size.height)
                                )
                                .opacity(anchor < 0 || anchor > geo.size.height ? 0 : 1)
                        }
                    }
                    // The other half of the rows' claim: the arrow stops being
                    // offered when the pointer leaves the whole pane — which
                    // it has not done by moving onto the arrow.
                    //
                    // Outside the overlay, not inside it. Whether SwiftUI
                    // reads hover off geometry or off who takes the hit, the
                    // pointer is within *this* view either way, so the
                    // button cannot pull the ground out from under itself.
                    .onHover { inside in
                        if !inside, side == .left { hoveredHeadRow = nil }
                    }
                    .onChange(of: currentAnchor) { _, idx in
                        guard idx >= 0, idx < anchors.count else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(DiffDisplayRow.row(anchors[idx]).id, anchor: .center)
                        }
                    }
                    .onChange(of: find.current) { _, match in
                        guard let match else { return }
                        revealRow(match.line)
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(DiffDisplayRow.row(match.line).id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: paneWidth, alignment: .leading)
        .clipped()
    }

    /// Coordinate space of one pane's scrolling content.
    private static func paneSpace(_ side: ComparePaneSide) -> String {
        side == .left ? "compare-pane-left" : "compare-pane-right"
    }

    /// Coordinate space of one pane's *viewport* — the window onto that
    /// content, which scrolling moves the content behind.
    private static func paneViewportSpace(_ side: ComparePaneSide) -> String {
        side == .left ? "compare-viewport-left" : "compare-viewport-right"
    }

    /// How far in from the pane's trailing edge the copy arrow sits.
    private static let copyArrowInset: CGFloat = 16

    /// The block the copy arrow is currently offering, or nil when the
    /// pointer is not over one that can be copied.
    ///
    /// An unchanged row is not one: copying it would write the line it
    /// already holds. Nor is anything at all in a file that cannot be
    /// written to.
    private var hoveredCopyBlock: BlockEdit? {
        guard workingIsEditable, let row = hoveredHeadRow, sectionHasChange(at: row)
        else { return nil }
        return blockEdit(containing: row)
    }

    /// The row the arrow copies on its own instead of the whole block: the
    /// one clicked, while the pointer is over its block and the two sides
    /// differ there.
    private func lineCopyRow(in block: BlockEdit) -> Int? {
        guard let row = selectedRowIdx, block.contains(row: row),
              block.canTakeLineFromHead(row: row)
        else { return nil }
        return row
    }

    /// The row the copy arrow is drawn beside: the clicked line when the
    /// arrow copies just that line, otherwise wherever the pointer is.
    private var copyArrowRow: Int? {
        if let block = hoveredCopyBlock, let row = lineCopyRow(in: block) { return row }
        return hoveredHeadRow
    }

    /// The arrow in its one-line form: smaller, and labelled, so it cannot be
    /// mistaken for the block's.
    private func copyLineFromHeadButton(row: Int, block: BlockEdit) -> some View {
        Button {
            copyLineFromHead(row: row)
        } label: {
            Image(systemName: "arrow.right.circle.fill")
                .scaledFont(11)
                .foregroundStyle(Color.accentBlue)
                .background(Circle().fill(Color.bgPanel).padding(1))
                // Hung below rather than stacked, so the arrow itself stays
                // centred on the line it copies.
                .overlay(alignment: .bottom) {
                    Text("line")
                        .scaledFont(8, weight: .semibold)
                        .foregroundStyle(Color.accentBlue)
                        .fixedSize()
                        .padding(.horizontal, 2)
                        .background(Color.bgPanel.opacity(0.85), in: RoundedRectangle(cornerRadius: 2))
                        .offset(y: 11)
                        .allowsHitTesting(false)
                }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside, hoveredHeadRow == nil { hoveredHeadRow = row }
        }
        .help(copyLineHelp(row: row, block: block))
    }

    private func copyLineHelp(row: Int, block: BlockEdit) -> String {
        guard let line = block.lineRows.first(where: { $0.row == row }) else { return "" }
        if line.head == nil { return "Remove this line from WORKING — HEAD has nothing here" }
        if line.working == nil { return "Put HEAD's line back into WORKING" }
        return "Overwrite this WORKING line with HEAD's"
    }

    private func copyFromHeadButton(_ block: BlockEdit) -> some View {
        Button {
            copyFromHead(block)
            textSelection = nil
            closeEditor()
        } label: {
            Image(systemName: "arrow.right.circle.fill")
                .scaledFont(15)
                .foregroundStyle(Color.accentBlue)
                .background(Circle().fill(Color.bgPanel).padding(1))
        }
        .buttonStyle(.plain)
        // Belt and braces for the same thing: pointing at the arrow re-states
        // which block it belongs to, so it survives even if the row beneath
        // it stops reporting the hover.
        // Only if the row beneath has already let go — re-stating it
        // unconditionally would jump the arrow to the top of the block the
        // moment the pointer reached it.
        .onHover { inside in
            if inside, hoveredHeadRow == nil { hoveredHeadRow = block.rowStart }
        }
        .help(copyHelp(for: block))
    }

    /// Says what the arrow will do to *this* block, because the three shapes
    /// do visibly different things and only one of them is "overwrite".
    private func copyHelp(for block: BlockEdit) -> String {
        let lines = headLines(of: block)
        if lines.isEmpty {
            let n = block.workingCount
            return "Remove \(n) line\(n == 1 ? "" : "s") from WORKING — HEAD has nothing here"
        }
        if block.workingCount == 0 {
            return "Put HEAD's \(lines.count) line\(lines.count == 1 ? "" : "s") back into WORKING"
        }
        return "Overwrite WORKING with HEAD's \(lines.count) line\(lines.count == 1 ? "" : "s")"
    }

    /// Faint wash over every row of the block the copy arrow is offering.
    /// Just the one row when the arrow copies just that line.
    private func copyHoverWash(idx: Int) -> Color {
        guard let block = hoveredCopyBlock, block.contains(row: idx) else { return .clear }
        if let row = lineCopyRow(in: block), row != idx { return .clear }
        return Color.accentBlue.opacity(0.10)
    }

    /// Highlight stack for a diff row: explicit selection (click)
    /// dominates over the change-anchor highlight (⌘J / ⌘K target),
    /// so users can tell the two cursors apart.
    private func rowSelectionBackground(idx: Int) -> Color {
        if idx == selectedRowIdx { return Color.accentBlue.opacity(0.28) }
        if idx == anchorRowID    { return Color.accentBlue.opacity(0.18) }
        return .clear
    }

    /// Bottom inspector strip — two thin rows showing the full HEAD
    /// and WORKING text of the clicked line, wrapped to dialog width
    /// so a long line can be read end-to-end without horizontal
    /// scrolling. Mirrors Beyond Compare's two-pane line view: side
    /// arrow, line number, full text. Word-diff tinting carries over
    /// from the main diff.
    private func lineDetailPanel(line: ResolvedLine) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                detailLine(
                    lineNumber: line.leftLine,
                    spans: line.leftSpans,
                    syntax: syntax(for: line.leftLine, side: .left),
                    kind: line.leftKind,
                    changeBackground: Color.diffDelWordBg
                )
                detailLine(
                    lineNumber: line.rightLine,
                    spans: line.rightSpans,
                    syntax: syntax(for: line.rightLine, side: .right),
                    kind: line.rightKind,
                    changeBackground: Color.diffAddWordBg
                )
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                selectedRowIdx = nil
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(9)
                    .foregroundStyle(Color.textSecondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help("Close inspector")
        }
        .background(Color.bgPanelHeader)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func detailLine(
        lineNumber: Int?,
        spans: [DiffSpan],
        syntax: [SyntaxToken],
        kind: CompareRow.Kind?,
        changeBackground: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Side colour swatch — same key as the row tints in the
            // main diff (red = HEAD, green = WORKING). 2pt wide is
            // enough to register without bulking up the strip.
            RoundedRectangle(cornerRadius: 1)
                .fill(detailSideAccent(for: kind))
                .frame(width: 2, height: 12)
            Text(lineNumber.map(String.init) ?? "")
                .font(.mono(size: max(9, monoSize - 2)))
                .foregroundStyle(Color.textDisabled)
                .frame(width: 36, alignment: .trailing)
            Group {
                if spans.isEmpty {
                    Text("(no line on this side)")
                        .font(.mono(size: monoSize))
                        .foregroundStyle(Color.textDisabled)
                        .italic()
                } else {
                    SpanText(
                        spans: spans,
                        syntax: syntax,
                        fontSize: monoSize,
                        changeBackground: changeBackground,
                        wrapLines: true
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 24) // room for the close button
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }

    /// Nearest working-side line number at or above `idx`, for rows that
    /// have none of their own.
    private func lastWorkingLine(atOrAbove idx: Int) -> Int? {
        for i in stride(from: min(idx, resolved.count - 1), through: 0, by: -1) {
            if let line = resolved[i].rightLine { return line }
        }
        return nil
    }

    private func detailSideAccent(for kind: CompareRow.Kind?) -> Color {
        switch kind {
        case .removed: return Color.diffDelText
        case .added:   return Color.diffAddText
        case .same:    return Color.textDisabled.opacity(0.4)
        case .none:    return Color.clear
        // A side is never `.modified` — `fromSimple` splits such a pair into
        // `.removed` on the left and `.added` on the right.
        case .modified: return Color.clear
        }
    }

    /// Wrap mode's version of a drafted block: HEAD's lines on the left,
    /// the draft on the right, one row for the pair.
    private func wrapBlockRow(_ edit: BlockEdit) -> some View {
        let isOpen = editingBlockRow == edit.rowStart
        let lines = TextBufferEdits.lines(of: edit.text)
        let headLines = (edit.rowStart...min(edit.rowEnd, rows.count - 1))
            .compactMap { rows[$0].leftText }
        return HStack(alignment: .top, spacing: 0) {
            Text(headLines.isEmpty ? " " : headLines.joined(separator: "\n"))
                .font(.mono(size: monoSize))
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, Self.rowPadding)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                blockGutter(
                    edit,
                    lineCount: max(draftRowCount(edit), 1),
                    lineHeight: lineHeight,
                    padding: Self.rowPadding
                )
                Group {
                    if isOpen {
                        BlockTextEditor(
                            text: blockBinding(rowStart: edit.rowStart),
                            fontSize: monoSize,
                            lineHeight: lineHeight,
                            gaps: edit.gaps,
                            caretLineOffset: editingCaretOffset,
                            caretAtLineEnd: editingCaretAtLineEnd,
                            // Same step Escape takes everywhere else in this
                            // window: leave the editor, keep the draft.
                            onEscape: { closeEditor() },
                            onBackspaceWhenEmpty: {
                                mergeIntoBlockAbove(from: edit.rowStart)
                            }
                        )
                    } else if draftRowCount(edit) > 0 {
                        BlockDraftText(lines: lines, fontSize: monoSize, lineHeight: lineHeight, gaps: edit.gaps)
                    } else {
                        // Emptied: the save will take these lines out, so the
                        // working side of the row shows what that leaves.
                        Text(" ")
                            .font(.mono(size: monoSize))
                            .padding(.horizontal, 6)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: CGFloat(blockCellRows(edit)) * lineHeight,
                    alignment: .topLeading
                )
                .padding(.vertical, Self.rowPadding)
                .background(Color.bgInput)
                .overlay {
                    if isOpen {
                        Rectangle()
                            .stroke(Color.accentBlue, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if !isOpen { beginEditing(row: edit.rowStart) } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The WORKING side of a block that has a draft: the text as it now
    /// stands, open for typing or waiting for Save.
    ///
    /// Plain in both states. Everything else in the pane is a statement about
    /// how the file compares to HEAD, and that comparison was computed before
    /// this block was retyped — so the honest thing to draw over a block
    /// under the user's hands is its text, and nothing else. Save re-runs the
    /// compare and the colour comes back, saying something true again.
    @ViewBuilder
    private func blockCell(_ edit: BlockEdit, paneWidth: CGFloat) -> some View {
        let isOpen = editingBlockRow == edit.rowStart
        let rowCount = draftRowCount(edit)
        let lines = TextBufferEdits.lines(of: edit.text)
        // Emptied and no longer being typed in: nothing at all on this side,
        // which is what the file will look like after the save. The HEAD rows
        // opposite stay, and the padding either side keeps them in step.
        if rowCount == 0, !isOpen {
            // Zero-height rather than `EmptyView`: the caller pads this by the
            // height of the HEAD rows opposite, and padding on an `EmptyView`
            // lays out nothing at all — which would drop this pane out of step
            // with the other by exactly the block it just removed.
            Color.clear.frame(height: 0)
        } else {
            // A line of the block is a row of the diff tall, padding and all,
            // not a line of text: HEAD opposite draws one row per line, and
            // anything shorter walks the block's lines up out of step with
            // them — and ends the block 2pt per line early, so every row
            // below it is out of step too.
            HStack(alignment: .top, spacing: 0) {
                blockGutter(edit, lineCount: rowCount, lineHeight: rowHeight, padding: 0)
                Group {
                    if isOpen {
                        BlockTextEditor(
                            text: blockBinding(rowStart: edit.rowStart),
                            fontSize: monoSize,
                            lineHeight: rowHeight,
                            gaps: edit.gaps,
                            caretLineOffset: editingCaretOffset,
                            caretAtLineEnd: editingCaretAtLineEnd,
                            // Same step Escape takes everywhere else in this
                            // window: leave the editor, keep the draft.
                            onEscape: { closeEditor() },
                            onBackspaceWhenEmpty: {
                                mergeIntoBlockAbove(from: edit.rowStart)
                            }
                        )
                    } else {
                        BlockDraftText(lines: lines, fontSize: monoSize, lineHeight: rowHeight, gaps: edit.gaps)
                    }
                }
                .frame(
                    width: blockContentWidth(lines: lines, paneWidth: paneWidth),
                    height: CGFloat(blockCellRows(edit)) * rowHeight,
                    alignment: .topLeading
                )
                .background(Color.bgInput)
                .overlay {
                    if isOpen {
                        Rectangle()
                            .stroke(Color.accentBlue, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                // Only while it is closed. Over an open editor this would be a
                // second claim on the same click, competing with the text
                // view's own — which is what places the caret.
                .contentShape(Rectangle())
                .onTapGesture { if !isOpen { beginEditing(row: edit.rowStart) } }
            }
        }
    }

    /// Line numbers down the side of a drafted block.
    ///
    /// They are the numbers the lines will carry once the block is saved —
    /// which is exact unless another block above has also grown or shrunk,
    /// and the alternative is a gutter that goes blank exactly where the user
    /// is working.
    private func blockGutter(
        _ edit: BlockEdit,
        lineCount: Int,
        lineHeight: CGFloat,
        padding: CGFloat
    ) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<max(lineCount, 1), id: \.self) { offset in
                // The space before this line carries no number: there is no
                // line there to number.
                if edit.gap(before: offset) > 0 {
                    Color.clear.frame(height: CGFloat(edit.gap(before: offset)) * lineHeight)
                }
                Text("\(edit.workingStart + offset)")
                    .font(.mono(size: max(9, monoSize - 2)))
                    .foregroundStyle(Color.textDisabled)
                    .frame(width: Self.blockGutterWidth, height: lineHeight, alignment: .trailing)
                    .padding(.trailing, 4)
            }
            if edit.gap(before: max(lineCount, 1)) > 0 {
                Color.clear
                    .frame(height: CGFloat(edit.gap(before: max(lineCount, 1))) * lineHeight)
            }
        }
        // Pinned, because the gap spacers above take any width they are
        // offered — and a split pane offers the width of its longest line,
        // which pushed the text that far off to the right.
        .frame(width: Self.blockGutterWidth + 4)
        .padding(.vertical, padding)
        .background(Color.bgPanelHeader.opacity(0.7))
        .overlay(alignment: .trailing) {
            // Amber, not the diff's red or green: this block no longer says
            // what the comparison beside it describes.
            Rectangle().fill(Color.editedLineAccent).frame(width: 2)
        }
    }

    /// Matches `HalfRowView`'s gutter, less the 2pt accent bar it draws as an
    /// overlay rather than as part of the stack.
    private static let blockGutterWidth: CGFloat = 44

    /// Wide enough for the longest line in the draft, so the pane's own
    /// horizontal scroll can reach the end of it, and never narrower than the
    /// pane.
    private func blockContentWidth(lines: [String], paneWidth: CGFloat) -> CGFloat {
        let longest = lines.map(\.count).max() ?? 0
        let estimate = CGFloat(longest) * monoSize * 0.62 + 32
        return max(estimate, paneWidth - (Self.blockGutterWidth + 6))
    }

    /// One ordinary (un-drafted) row of one pane.
    private func splitHalfRow(
        idx: Int,
        side: ComparePaneSide,
        paneWidth: CGFloat
    ) -> some View {
        HalfRowView(
            line: resolved[idx],
            side: side,
            minRowWidth: paneWidth,
            syntax: syntax(
                for: side == .left ? resolved[idx].leftLine : resolved[idx].rightLine,
                side: side
            ),
            searchMatches: find.matches(onLine: idx, column: side == .left ? 0 : 1),
            currentMatch: find.current,
            isEditTarget: side == .right && workingIsEditable,
            selection: selectionRange(row: idx, side: side),
            selectionIncludesNewline: textSelection?.side == side
                && textSelection?.includesLineBreak(after: idx) == true
        )
        // Pinned, not left to the text's own metrics: `paneLayout` turns a
        // drag's Y offset back into a row by adding these up, and a row a
        // point off its computed height walks that arithmetic out of step
        // over the length of a file. It is also the height every other piece
        // of this view already computes in — `blockPadding` pads one pane by
        // a count of these — so pinning them keeps the two columns level at
        // the zoom levels where the font's own line height rounds the other
        // way.
        .frame(height: rowHeight, alignment: .leading)
        // Only the row under the pointer measures itself, so the arrow costs
        // one `GeometryReader` rather than one per row.
        .background {
            // Hovered or clicked first: the arrow is beside one of those two,
            // and asking which costs a look at the block.
            if side == .left, idx == hoveredHeadRow || idx == selectedRowIdx,
               idx == copyArrowRow {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: CopyArrowRowKey.self,
                        value: geo.frame(in: .named(Self.paneViewportSpace(side))).midY
                    )
                }
            }
        }
        // Washes as much as the arrow copies — the whole block, or the one
        // line when it copies only that: a highlight wider or narrower than
        // what the button does is a highlight that lies about it.
        .background(copyHoverWash(idx: idx))
        .background(rowSelectionBackground(idx: idx))
        .overlay(alignment: .leading) { alignMarks(idx: idx, side: side) }
        // Claim only. Releasing is the pane's job, below: the arrow is drawn
        // *over* the row it belongs to, so moving the pointer onto it takes
        // the hover off that row — and a row that clears on its own way out
        // takes the button out from under the click that was reaching for it.
        .onHover { inside in
            guard side == .left, inside else { return }
            hoveredHeadRow = idx
        }
        .contentShape(Rectangle())
        // A click on the WORKING column opens that line's block for typing,
        // caret on the line that was clicked. On HEAD — a committed revision,
        // with nothing to write to — it selects the row for the inspector.
        // Either way it puts the drag selection away, as a click does in any
        // editor — unless Shift is down, which carries the selection here
        // instead. That is how a selection longer than the pane is made: a
        // drag cannot scroll the view under itself.
        .onTapGesture {
            // Align With is waiting for its second line, and this is it.
            if alignSource != nil {
                alignClick(row: idx, side: side)
                return
            }
            if NSEvent.modifierFlags.contains(.shift),
               textSelection?.side == side {
                extendSelection(to: idx, side: side)
                return
            }
            textSelection = nil
            if side == .right, workingIsEditable {
                beginEditing(row: idx)
            } else {
                selectRow(idx)
            }
        }
        .contextMenu { rowCopyMenu(idx, side: side) }
    }

    @ViewBuilder
    private func splitRowEntry(
        entry: DiffDisplayRow,
        side: ComparePaneSide,
        paneWidth: CGFloat
    ) -> some View {
        switch entry {
        case .row(let idx):
            if let edit = draftedBlock(at: idx) {
                // A block with a draft is one thing on the WORKING side —
                // drawn once, at its first row, as however many lines it now
                // holds. HEAD keeps its own rows; whichever side ends up
                // shorter is padded, so the row below the block starts at the
                // same height in both panes.
                if side == .right {
                    if idx == edit.rowStart {
                        blockCell(edit, paneWidth: paneWidth)
                            .padding(.bottom, blockPadding(edit, side: .right))
                    }
                } else if idx < resolved.count, !resolved[idx].hidden {
                    splitHalfRow(idx: idx, side: side, paneWidth: paneWidth)
                        .padding(.bottom, idx == edit.headLastRow
                                 ? blockPadding(edit, side: .left)
                                 : 0)
                }
            } else if idx < resolved.count, !resolved[idx].hidden {
                splitHalfRow(idx: idx, side: side, paneWidth: paneWidth)
            }
        case .fold(let start, let count):
            FoldMarkerHalfRow(
                hiddenCount: count,
                chunk: Self.expandChunk,
                expandDown: { revealFromTop(start: start, count: count) },
                expandUp: { revealFromBottom(start: start, count: count) },
                expandAll: { revealAll(start: start, count: count) },
                showLabel: side == .left,
                minRowWidth: paneWidth,
                height: foldRowHeight
            )
        }
    }

    /// Find the first non-nil left/right line number at or after the
    /// given row index — used to label fold markers with the range
    /// they hide ("@@ 24-87 @@" style).
    private func firstLeftLineNumber(from start: Int) -> Int? {
        for k in start..<rows.count {
            if let n = rows[k].leftLine { return n }
        }
        return nil
    }

    private func firstRightLineNumber(from start: Int) -> Int? {
        for k in start..<rows.count {
            if let n = rows[k].rightLine { return n }
        }
        return nil
    }

    private var anchorRowID: Int? {
        guard currentAnchor >= 0, currentAnchor < anchors.count else { return nil }
        return anchors[currentAnchor]
    }

    private var paneHeaders: some View {
        HStack(spacing: 0) {
            paneHeader(
                title: "HEAD",
                subtitle: headExists ? "last committed" : "not in HEAD",
                tint: .blue
            )
            Divider()
            paneHeader(
                title: "WORKING",
                subtitle: workingSubtitle,
                tint: hasUnsavedChanges ? .orange : .green
            )
        }
    }

    private var workingSubtitle: String {
        if hasUnsavedChanges { return "edited \u{00B7} unsaved" }
        return workingIsEditable ? "on disk \u{00B7} click to edit" : "on disk \u{00B7} read-only"
    }

    private func paneHeader(title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(title)
                .scaledFont(10, weight: .semibold)
                .foregroundStyle(Color.textPrimary)
            Text(subtitle)
                .scaledFont(9)
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.bgPanelHeader)
        .frame(maxWidth: .infinity)
    }

    private func jump(by delta: Int) {
        guard !anchors.isEmpty else { return }
        let raw = currentAnchor + delta
        let wrapped = ((raw % anchors.count) + anchors.count) % anchors.count
        currentAnchor = wrapped
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("Revert Edits") {
                // Drafts and pending deletions first: they are edits against
                // the buffer, and leaving them behind would re-apply them to
                // the restored text at the next save.
                discardPendingEdits()
                workingText = originalWorkingText
            }
            .disabled(!hasUnsavedChanges)
            .help("Undo any edits made in this view (working file on disk is unchanged)")

            Spacer()

            Text(editStatus)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)

            Button("Save") {
                Task { await save() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!hasUnsavedChanges || !workingIsEditable)
            .help("Apply the edits to the working file and compare again (⌘S)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bgPanelHeader)
    }

    /// Says how much is waiting for a save, in the unit the user made it in:
    /// blocks. "Unsaved edits" alone left no way to tell a stray keystroke in
    /// one block from a deliberate pass over six.
    private var editStatus: String {
        let blocks = changedBlocks.count
        if blocks == 0 { return hasUnsavedChanges ? "Unsaved edits" : "No changes" }
        // Net lines, which is the number that answers "what will this do to
        // the file": a block retyped in place contributes nothing to it, and
        // says so by not appearing.
        let delta = changedBlocks.reduce(0) { total, edit in
            // `draftRowCount`, not the line split: a cleared block writes no
            // lines at all, and counting the empty string as one would report
            // a three-line block being deleted as two lines gone.
            total + draftRowCount(edit) - edit.workingCount
        }
        let blockPart = "\(blocks) block\(blocks == 1 ? "" : "s") edited"
        switch delta {
        case 0:  return "\(blockPart) \u{00B7} unsaved"
        case 1...: return "\(blockPart), +\(delta) line\(delta == 1 ? "" : "s") \u{00B7} unsaved"
        default:
            let removed = -delta
            return "\(blockPart), \u{2212}\(removed) line\(removed == 1 ? "" : "s") \u{00B7} unsaved"
        }
    }

    /// How many lines one press of an expand arrow brings into view.
    ///
    /// Enough to see what a block sits inside, few enough that opening a
    /// fold in a large file is not a redraw of the whole file — which is
    /// what expanding a four-hundred-line gap in one go amounted to.
    static let expandChunk = 10

    /// Reveal from the top of a fold: carries the block *above* it further
    /// down.
    private func revealFromTop(start: Int, count: Int) {
        let n = min(Self.expandChunk, count)
        revealedLines.formUnion(start..<(start + n))
    }

    /// Reveal from the bottom of a fold: carries the block *below* it
    /// further up.
    private func revealFromBottom(start: Int, count: Int) {
        let n = min(Self.expandChunk, count)
        revealedLines.formUnion((start + count - n)..<(start + count))
    }

    private func revealAll(start: Int, count: Int) {
        revealedLines.formUnion(start..<(start + count))
    }

    /// Expands the collapsed region hiding `row`, if any.
    ///
    /// Without this a hit inside a folded run is unreachable: the find bar
    /// counts it, Next steps onto it, and the view cannot scroll anywhere
    /// because the row has no view to scroll to. Searching is exactly when the
    /// user wants to see a line they have collapsed away.
    private func revealRow(_ row: Int) {
        guard collapseUnchanged else { return }
        // The line itself is enough: whatever fold was hiding it splits
        // around it, and nothing else has to be expanded to get there.
        revealedLines.insert(row)
    }

    /// Copy actions for one diff row.
    ///
    /// These exist because text selection is scoped to a single `Text` by
    /// SwiftUI, so a drag cannot run across rows — this is how a whole line,
    /// or both versions of it, leave the window.
    ///
    /// `side` is the pane that was right-clicked; nil in wrap mode, where one
    /// row holds both.
    @ViewBuilder
    private func rowCopyMenu(_ idx: Int, side: ComparePaneSide?) -> some View {
        if idx < resolved.count {
            if let selection = textSelection, !selection.isEmpty {
                let lines = selection.end.row - selection.start.row + 1
                Button("Copy Selection (\(lines) line\(lines == 1 ? "" : "s"))") {
                    copySelection()
                }
                Divider()
            }
            let line = resolved[idx]
            let left = line.leftSpans.map(\.text).joined()
            let right = line.rightSpans.map(\.text).joined()

            if !left.isEmpty {
                Button("Copy HEAD Line") { appState.copyToPasteboard(left) }
            }
            if !right.isEmpty {
                Button("Copy WORKING Line") { appState.copyToPasteboard(right) }
            }
            if !left.isEmpty, !right.isEmpty {
                Divider()
                Button("Copy Both Sides") {
                    appState.copyToPasteboard(left + "\n" + right)
                }
            }
            if workingIsEditable {
                Divider()
                if sectionHasChange(at: idx), let block = blockEdit(containing: idx) {
                    Button(copyMenuTitle(for: idx, block: block)) {
                        copyFromHead(block)
                        textSelection = nil
                        closeEditor()
                    }
                    .help(copyHelp(for: block))
                    if block.canTakeLineFromHead(row: idx) {
                        Button("Copy Line from HEAD") { copyLineFromHead(row: idx) }
                            .help(copyLineHelp(row: idx, block: block))
                    }
                }
                // Adding and removing lines is ordinary typing once the block
                // is open, so this is the only edit command the row needs.
                Button("Edit This Section") { beginEditing(row: idx) }
                if let edit = draftedBlock(at: idx), edit.removed || edit.text != edit.original {
                    Button("Discard Section Edit", role: .destructive) {
                        cancelEditing(rowStart: edit.rowStart)
                    }
                }
            }
            Divider()
            alignMenu(idx, side: side)
            Divider()
            Button("Inspect Line") { selectRow(idx) }
        }
    }

    // MARK: - Align With

    /// Beyond Compare's manual alignment, on the row menu: right-click a line,
    /// Align With…, then click — or right-click — the line on the other side
    /// it belongs beside.
    @ViewBuilder
    private func alignMenu(_ idx: Int, side: ComparePaneSide?) -> some View {
        let sides = side.map { [$0] } ?? [.left, .right]
        if let source = alignSource {
            ForEach(sides.filter { $0 != source.side }, id: \.self) { target in
                if let line = alignLine(row: idx, side: target) {
                    Button("Align \(Self.sideName(target)) Line \(line) with \(Self.sideName(source.side)) Line \(source.line)") {
                        alignClick(row: idx, side: target)
                    }
                    .disabled(!canAlign)
                }
            }
            Button("Cancel Align With") { alignSource = nil }
        } else {
            ForEach(sides, id: \.self) { from in
                if let line = alignLine(row: idx, side: from) {
                    Button("Align \(Self.sideName(from)) Line \(line) With…") {
                        beginAlign(row: idx, side: from)
                    }
                    .disabled(!canAlign)
                    .help(canAlign
                          ? "Then click the line on the other side that belongs beside it"
                          : alignBlockedHelp)
                }
            }
        }
        if pinnedRows.contains(idx), let pinned = pinAlignment(atRow: idx) {
            Button("Remove Alignment") { removePins([pinned]) }
                .disabled(!canAlign)
        }
        if pins.count > 1 {
            Button("Remove All Alignments (\(pins.count))") { removePins(pins.map(\.alignment)) }
                .disabled(!canAlign)
        }
    }

    private static func sideName(_ side: ComparePaneSide) -> String {
        side == .left ? "HEAD" : "WORKING"
    }

    /// The line `row` shows on `side`, 1-based; nil for a side with none there.
    private func alignLine(row: Int, side: ComparePaneSide) -> Int? {
        guard resolved.indices.contains(row), !resolved[row].hidden else { return nil }
        return side == .left ? resolved[row].leftLine : resolved[row].rightLine
    }

    /// A pin re-runs the alignment, and section drafts are keyed by the rows
    /// of the one on screen — re-aligning under them would apply each to
    /// whatever lines land at its rows.
    private var canAlign: Bool { changedBlocks.isEmpty }

    private var alignBlockedHelp: String {
        "Save or discard your section edits first — aligning moves the rows they belong to"
    }

    private func beginAlign(row: Int, side: ComparePaneSide) {
        guard let line = alignLine(row: row, side: side) else { return }
        closeEditor()
        textSelection = nil
        alignSource = AlignEnd(side: side, line: line)
    }

    /// A click while Align With is waiting. The other side finishes it; the
    /// same side moves the starting line, which is how a misclick is undone
    /// without starting over. A row with no line on the clicked side has
    /// nothing to align.
    private func alignClick(row: Int, side: ComparePaneSide) {
        guard let source = alignSource else { return }
        guard let clicked = alignLine(row: row, side: side) else {
            NSSound.beep()
            return
        }
        if side == source.side {
            alignSource = AlignEnd(side: side, line: clicked)
            return
        }
        guard canAlign else {
            NSSound.beep()
            return
        }
        let headLine = side == .left ? clicked : source.line
        let workingLine = side == .right ? clicked : source.line
        let pin = ManualPin(
            alignment: LineAlignment(left: headLine - 1, right: workingLine - 1),
            headText: rows.first { $0.leftLine == headLine }?.leftText ?? "",
            workingText: line(workingLine)
        )
        alignSource = nil
        let kept = Set(LineAlignment.adding(pin.alignment, to: pins.map(\.alignment)))
        pins = (pins.filter { kept.contains($0.alignment) } + [pin]).sorted { $0.alignment.left < $1.alignment.left }
        pinToSelect = pin.alignment
        realign()
    }

    private func removePins(_ removed: [LineAlignment]) {
        guard canAlign else { return }
        let gone = Set(removed)
        pins.removeAll { gone.contains($0.alignment) }
        realign()
    }

    /// The pin whose HEAD line sits on `row`.
    private func pinAlignment(atRow row: Int) -> LineAlignment? {
        guard rows.indices.contains(row), let left = rows[row].leftLine else { return nil }
        return pins.first { $0.alignment.left == left - 1 }?.alignment
    }

    /// Runs the compare again for a change of pins. Section drafts name rows
    /// of the alignment being replaced, and `canAlign` has made sure none of
    /// them hold anything; nor do the row-indexed selections.
    private func realign() {
        discardPendingEdits()
        textSelection = nil
        selectedRowIdx = nil
        recomputeDiff()
    }

    /// The pin marker in the gutter of a row a pin put together, and the
    /// outline around the line Align With started from. `side` nil is wrap
    /// mode's both-sides row.
    @ViewBuilder
    private func alignMarks(idx: Int, side: ComparePaneSide?) -> some View {
        if let source = alignSource, side == nil || side == source.side,
           alignLine(row: idx, side: source.side) == source.line {
            Rectangle()
                .stroke(Color.accentBlue, lineWidth: 1.5)
                .allowsHitTesting(false)
        } else if pinnedRows.contains(idx) {
            Image(systemName: "pin.fill")
                .font(.system(size: max(7, monoSize - 5)))
                .foregroundStyle(Color.accentBlue)
                .padding(.leading, 3)
                .allowsHitTesting(false)
        }
    }

    /// The row menu's wording for the copy. A drag selection spanning several
    /// blocks says so, because the command will act on all of them.
    private func copyMenuTitle(for idx: Int, block: BlockEdit) -> String {
        if let selection = textSelection, !selection.isEmpty, selection.covers(row: idx) {
            let count = blocksToCopy().count
            if count > 1 { return "Copy \(count) Sections from HEAD" }
        }
        return "Copy Section from HEAD"
    }

    // MARK: - Diff caching + span resolution

    /// `resetView` is for a different file, or the same file changing
    /// underneath: folds and the change cursor describe the diff that was
    /// just thrown away. A save is the opposite case — folding away the
    /// region the user was just working in, and scrolling them off it, is not
    /// a reasonable answer to ⌘S — so it defaults to off.
    ///
    /// The work runs off the main thread (`CompareSnapshot.make`): on a file
    /// with tens of thousands of changed lines it takes long enough that
    /// doing it inline froze the whole app. A fresh file shows progress at
    /// once, with a Cancel; a re-run after a save keeps the old rows up and
    /// only says it is working if it is still going after a moment.
    private func recomputeDiff(resetView: Bool = false) {
        let head = headText
        let working = workingText
        let pins = pins
        // `apply` sets both texts and asks for a compare, and the two
        // `onChange`s then ask again for the same pair. Join the run.
        if case .running = comparePhase,
           let inputs = compareInputs, inputs.head == head, inputs.working == working,
           inputs.pins == pins {
            pendingReset = pendingReset || resetView
            if resetView { comparePhase = .running(showsProgress: true) }
            return
        }

        diffTask?.cancel()
        compareGeneration += 1
        let generation = compareGeneration
        pendingReset = pendingReset || resetView
        compareInputs = CompareInputs(head: head, working: working, pins: pins)
        compareSize = (Self.lineCount(head), Self.lineCount(working))
        comparePhase = .running(showsProgress: pendingReset)

        let language = SyntaxLanguage(path: path)
        let rescanHead = headSyntaxSource != head
        let rescanWorking = workingSyntaxSource != working

        if !pendingReset {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard generation == compareGeneration,
                      case .running(showsProgress: false) = comparePhase else { return }
                comparePhase = .running(showsProgress: true)
            }
        }

        diffTask = Task { @MainActor in
            let work = Task.detached(priority: .userInitiated) {
                CompareSnapshot.make(
                    head: head,
                    working: working,
                    pins: pins,
                    language: language,
                    rescanHead: rescanHead,
                    rescanWorking: rescanWorking
                )
            }
            let snapshot = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, generation == compareGeneration, let snapshot else { return }
            install(snapshot, head: head, working: working)
        }
    }

    private func install(_ snapshot: CompareSnapshot, head: String, working: String) {
        rows = snapshot.rows
        anchors = snapshot.anchors
        resolved = snapshot.resolved
        pins = snapshot.pins
        pinnedRows = snapshot.pinnedRows
        searchColumns = snapshot.searchColumns
        workingLines = snapshot.workingLines
        if let tokens = snapshot.headSyntax {
            headSyntax = tokens
            headSyntaxSource = head
        }
        if let tokens = snapshot.workingSyntax {
            workingSyntax = tokens
            workingSyntaxSource = working
        }
        recomputeSections()
        find.configure(columns: { searchColumns })
        // Offsets are into rows that have just been rebuilt, so anything the
        // find bar is holding describes the previous diff.
        find.recompute()
        // The rows it named have just been rebuilt; whatever sits at those
        // indices now is not what the user dragged across.
        textSelection = nil
        if pendingReset {
            revealedLines = []
            currentAnchor = -1
            // The split panes lay out every row they show, both sides, in
            // one pass on the main thread — tens of thousands of rows is a
            // window that stops answering. The wrapped layout is lazy.
            wrapIfTooLarge()
        }
        // Note: don't reset `selectedRowIdx` here — `load()` resets it on a
        // fresh file, and leaving the editor shouldn't close the inspector.
        // A pin just placed is the exception: the row it made is what the
        // user is looking for next.
        if let pin = pinToSelect {
            pinToSelect = nil
            if let row = rows.firstIndex(where: { $0.leftLine == pin.left + 1 }) {
                selectedRowIdx = row
                revealRow(row)
            }
        }
        pendingReset = false
        compareInputs = nil
        comparePhase = .idle
    }

    /// The Cancel button. The texts stay loaded; the stopped state offers to
    /// try again.
    private func stopCompare() {
        diffTask?.cancel()
        diffTask = nil
        compareGeneration += 1
        compareInputs = nil
        comparePhase = .stopped
    }

    /// The most rows the split panes are given when a file opens, or when
    /// Collapse is turned off.
    private static let splitPaneRowLimit = 3_000

    private func wrapIfTooLarge() {
        guard !wrapLines, displayRows.count > Self.splitPaneRowLimit else { return }
        wrapLines = true
        wrapForcedBySize = true
    }

    private static func lineCount(_ text: String) -> Int {
        text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    /// Groups the rows into sections.
    ///
    /// Asked of `LineDiff.collapse` rather than reimplemented beside it: the
    /// runs it keeps between its fold markers *are* the sections, and two
    /// pieces of code deciding that separately would eventually disagree
    /// about where one ends — which is where an editor would open over rows
    /// the user cannot see.
    ///
    /// `revealed: []` deliberately. Pulling a few lines out of a fold to read
    /// them should not quietly make the editable region four hundred lines
    /// long; the sections stay the natural ones however much context is
    /// showing, and stay bounded by the Context setting either way.
    private func recomputeSections() {
        sections = LineDiff.sections(rows: rows, contextLines: contextLines)
    }

    /// The section `idx` falls in, or nil for a row outside every one of them
    /// — an unchanged line the user pulled out of a fold, which is a line of
    /// its own and not part of any change.
    private func section(containing idx: Int) -> ClosedRange<Int>? {
        sections.first { $0.contains(idx) }
    }

    /// Syntax runs for a 1-based line number on one side, or none when the
    /// side has no line here (a pure add or delete) or the file isn't
    /// highlighted.
    private func syntax(for lineNumber: Int?, side: ComparePaneSide) -> [SyntaxToken] {
        let perLine = side == .left ? headSyntax : workingSyntax
        guard let lineNumber, lineNumber >= 1, lineNumber <= perLine.count else { return [] }
        return perLine[lineNumber - 1]
    }

    // MARK: - I/O

    /// The repository this compare belongs to. Usually the active one; a
    /// submodule's file is opened with its own, since the file exists there
    /// and not in the repository the main window has open.
    private var repoPath: String? { repoPathOverride ?? appState.activeRepo?.path }

    /// Both sides as they stand right now, read but not applied.
    ///
    /// Split out of `load()` so the staleness check can ask the same question
    /// without disturbing anything: what the window would show if it opened
    /// this second.
    private struct LoadedSides {
        /// Nil when the file is not in HEAD at all.
        let head: String?
        let working: String
        let workingIsEditable: Bool
    }

    private func readSides(repo: String) async -> LoadedSides {
        async let headTask: String? = try? await appState.git.fileAtHead(repoPath: repo, path: path)
        let working = readWorking(repo: repo)
        return LoadedSides(
            head: (await headTask) ?? nil,
            working: working.text,
            workingIsEditable: working.isEditable
        )
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let repo = repoPath else {
            errorMessage = "No active repository"
            return
        }
        apply(await readSides(repo: repo))
    }

    private func apply(_ sides: LoadedSides) {
        self.headExists = (sides.head != nil)
        self.headText = sides.head ?? ""
        self.workingText = sides.working
        self.originalWorkingText = sides.working
        self.workingIsEditable = sides.workingIsEditable
        // Drafts are line numbers into the file that was open a moment ago.
        // Against a different one they name whatever happens to sit at those
        // numbers now, which is how an edit ends up in a file it was never
        // typed into.
        discardPendingEdits()
        self.selectedRowIdx = nil
        // Row indices into the diff that is being thrown away.
        self.textSelection = nil
        self.diskChanged = false
        recomputeDiff(resetView: true)
    }

    // MARK: - Keeping up with the disk

    /// Whether either side has moved since it was read, with edits of the
    /// user's own standing in the way of simply catching up.
    ///
    /// Checked when the window comes forward rather than streamed: the app's
    /// file watcher feeds cache invalidation for the main window's panels,
    /// and a compare is a document window — the moment it matters is the
    /// moment you look at it, which is exactly when an editor checks.
    private func checkDisk() async {
        guard !isLoading, errorMessage == nil, let repo = repoPath else { return }
        let sides = await readSides(repo: repo)
        let moved = (sides.head ?? "") != headText
            || (sides.head != nil) != headExists
            || sides.working != originalWorkingText
        guard moved else {
            diskChanged = false
            return
        }
        // Nothing of the user's to lose: catch up silently, the way an editor
        // reloads a document it hasn't been typed into. With work pending,
        // say so and leave the decision alone — reloading would throw it away.
        if hasUnsavedChanges {
            diskChanged = true
        } else {
            apply(sides)
        }
    }

    /// The Reload button, and ⌘R. Unlike the silent catch-up above this can
    /// be pressed with edits pending, so it asks first.
    private func reload() async {
        if hasUnsavedChanges {
            let blocks = changedBlocks.count
            let what = blocks > 0
                ? "\(blocks) edited block\(blocks == 1 ? "" : "s")"
                : "unsaved edits"
            guard appState.platform.confirmWarning(
                title: "Reload from disk?",
                message: """
                This compare has \(what) that no save has applied.

                Reloading reads both sides again and throws them away.
                """,
                primaryButton: "Reload"
            ) else { return }
        }
        await load()
    }

    /// The working file's text, and whether it is text at all.
    ///
    /// A file that isn't UTF-8 used to read as `""`, indistinguishable from
    /// an empty one — which was survivable while the view could only read.
    /// It stops being survivable the moment Save can write: typing into a
    /// PNG's compare and hitting ⌘S would replace the image with whatever
    /// was typed. Unreadable files still open, still show their diff (of
    /// nothing), and simply cannot be edited.
    private func readWorking(repo: String) -> (text: String, isEditable: Bool) {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Deleted from the working tree. Saving would resurrect it as a
            // side effect of opening a compare, which nobody asked for.
            return ("", false)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ("", false)
        }
        return (text, true)
    }

    private func save() async {
        guard let repo = repoPath else { return }
        // The buffer being written was read before whatever moved the file,
        // so this save is a whole-file overwrite of somebody else's work.
        // Same warning the banner carries, at the moment it would happen.
        if diskChanged {
            guard appState.platform.confirmWarning(
                title: "Overwrite the changed file?",
                message: """
                \(path) has changed on disk since this compare was read.

                Saving writes this window's version over it, and what changed \
                underneath is not in it.
                """,
                primaryButton: "Save Anyway"
            ) else { return }
        }
        let url = URL(fileURLWithPath: repo).appendingPathComponent(path)
        // Everything typed since the last save, including the block still
        // open — what the user is looking at is part of what they mean by
        // "save", and leaving it out would write the file without it.
        let text = TextBufferEdits.applying(
            blocks: changedBlocks.map(\.asBlock),
            to: workingText
        )
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            // Setting the buffer re-runs the compare (see `onChange(of:
            // workingText)`), which is the point the drafts stop being
            // pending edits and become the file's own lines — coloured,
            // re-aligned, with the line numbers they really have.
            discardPendingEdits()
            workingText = text
            originalWorkingText = text
            // What is on disk is now what this window holds.
            diskChanged = false

            // `refreshAllForced` only drops L1 — the next `load()` reads
            // L2's pre-save snapshot, schedules a background refresh,
            // and the FILES + diff panels display the stale data until
            // the user clicks away and back. Drive `forceRefresh` on
            // both viewmodels directly so the panels reflect the new
            // file *now*, not on the next interaction.
            if repoPathOverride == nil {
                await appState.filesVM.forceRefresh()
                await appState.diffVM.forceReloadCurrent()
            } else {
                // The main window's panels are showing a different
                // repository — refreshing them would say nothing about this
                // save. Whoever opened the compare knows what to reload.
                await onSaved?()
            }
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Resolved line + row view

/// One block of the diff as the user has retyped it — the unit the compare
/// window edits in.
///
/// A block is what the view is already showing: the run of rows the aligner
/// grouped as one change (or a single unchanged line, clicked on its own).
/// Editing at that size is what makes adding and removing lines ordinary —
/// inside a block's own text they are just typing, and the only thing that
/// changes height is the block.
struct BlockEdit {
    /// Row span in the diff on screen, inclusive. Valid only while that diff
    /// is the one on screen, which is exactly as long as the draft lives:
    /// Save applies it and rebuilds the alignment in the same breath.
    let rowStart: Int
    let rowEnd: Int
    /// How many rows the HEAD pane draws for the block, and the last of them.
    /// Not the span: a remove+add pair is two rows of the alignment drawn as
    /// one, so the span over-counts by one per pair — and padding computed
    /// from it would push the two columns apart by exactly that much.
    let headRows: Int
    let headLastRow: Int
    /// First working line the block covers, and how many. A count of zero is
    /// a block that exists only on the HEAD side — a deletion — where typing
    /// inserts at `workingStart` rather than replacing anything.
    let workingStart: Int
    let workingCount: Int
    /// The block's text as the file has it, kept so a click that changes
    /// nothing can be told from an edit.
    let original: String
    var text: String
    /// Backspaced out of existence. Needed as its own flag for the one block
    /// an empty draft cannot speak for: a block that was *already* a single
    /// blank line, where empty text is what the file says too. Without it
    /// that line would read as deleted on screen and survive the save.
    var removed: Bool = false
    /// How an empty `text` reads. Emptying a block by typing means "take
    /// these lines out", which is what Backspace through a block has always
    /// done. But a block copied from HEAD can *be* one blank line, and an
    /// empty string is what that looks like once its one line is joined. Set
    /// only by the copy, and cleared the moment the user types — from then on
    /// the ordinary reading is the right one again.
    var emptyIsOneBlankLine: Bool = false
    /// Blank rows to leave before each line of `text`, plus a trailing entry
    /// — the places the section's other side has a line and this one does
    /// not. Empty when there are none.
    ///
    /// Held as rows, and drawn as space. Nothing goes into `text` that the
    /// file will not get.
    var gaps: [Int] = []

    /// One row the HEAD pane draws for the section, with what each side holds
    /// there. Nil is a side with no line on that row.
    struct LineRow: Equatable {
        let row: Int
        let head: String?
        let working: String?
    }

    /// The section row by row, as it was opened — what a copy of one line
    /// needs to know where that line lands among the others.
    var lineRows: [LineRow] = []
    /// Rows already switched to HEAD's side, one line at a time.
    var takenFromHead: Set<Int> = []

    func gap(before line: Int) -> Int {
        gaps.indices.contains(line) ? gaps[line] : 0
    }

    /// Rows of pure space the section holds. Pinned at the alignment the
    /// section opened with: typing inside a line moves nothing, adding one
    /// slides the gaps below it by a row until the next Save re-runs the
    /// compare. Space only — a gap in the wrong place is a cosmetic thing,
    /// which is the whole reason it is not made of characters.
    var totalGapRows: Int { gaps.reduce(0, +) }

    func contains(row: Int) -> Bool { row >= rowStart && row <= rowEnd }

    var asBlock: TextBufferEdits.Block {
        TextBufferEdits.Block(
            start: workingStart,
            count: workingCount,
            text: text,
            emptyIsOneBlankLine: emptyIsOneBlankLine
        )
    }

    /// This block with its working side replaced by what HEAD holds there —
    /// Beyond Compare's "Copy to Right", as a draft.
    ///
    /// The three shapes a block can have all fall out of one assignment. Both
    /// sides present: the working lines become HEAD's. HEAD only (`headLines`
    /// non-empty against a `workingCount` of zero): they are put back where
    /// they were. Working only (`headLines` empty): they go, which is what an
    /// empty draft has always meant.
    func copyingFromHead(_ headLines: [String]) -> BlockEdit {
        var out = self
        out.text = headLines.joined(separator: "\n")
        out.removed = headLines.isEmpty
        // Except for the one line that joins to the same empty string it
        // would be deleted by: a block whose HEAD side is a single blank
        // line has to come back as a single blank line.
        out.emptyIsOneBlankLine = headLines == [""]
        return out
    }

    /// The working column with `taken` rows on HEAD's side and the rest as
    /// the file has them — nil where that row ends up with no line.
    private func shape(taking taken: Set<Int>) -> [String?] {
        lineRows.map { taken.contains($0.row) ? $0.head : $0.working }
    }

    /// Whether the draft is still only what earlier line copies made of it.
    /// Once the user has typed in it, there is no telling which of its lines
    /// a row still stands for.
    var followsLineRows: Bool {
        !lineRows.isEmpty && text == shape(taking: takenFromHead).compactMap { $0 }.joined(separator: "\n")
    }

    /// Whether the line arrow has anything to do on `row`: the two sides
    /// differ there, and nothing typed has moved the line out from under it.
    func canTakeLineFromHead(row: Int) -> Bool {
        guard !takenFromHead.contains(row), followsLineRows,
              let line = lineRows.first(where: { $0.row == row })
        else { return false }
        return line.head != line.working
    }

    /// This block with `rows` switched to HEAD's side and every other row
    /// left as it stands — the whole block when `rows` is all of them.
    ///
    /// The section's space is re-laid from the same rows, so a line taken out
    /// leaves its row open opposite HEAD's rather than pulling the lines
    /// below it up out of step.
    func takingFromHead(rows: Set<Int>) -> BlockEdit {
        let taken = takenFromHead.union(rows)
        let column = shape(taking: taken)
        var out = copyingFromHead(column.compactMap { $0 })
        out.takenFromHead = taken
        // An emptied block draws nothing, and the HEAD rows opposite pad it —
        // space held open as well would count those rows twice.
        out.gaps = out.removed ? [] : LineDiff.gapRows(hasWorkingLine: column.map { $0 != nil })
        return out
    }
}

private enum ComparePhase: Equatable {
    case idle
    /// `showsProgress` is false for the first moments of a re-run, while
    /// the previous rows are still the best thing to show.
    case running(showsProgress: Bool)
    /// Cancelled from the progress state.
    case stopped
}

private struct CompareInputs {
    let head: String
    let working: String
    let pins: [ManualPin]
}

/// A pin as the compare window holds it: the two lines, and what they said
/// when it was placed. A save or a reload can move lines; a pin whose lines no
/// longer say that is let go, rather than left joining whatever sits at those
/// numbers now.
private struct ManualPin: Equatable, Sendable {
    let alignment: LineAlignment
    let headText: String
    let workingText: String
}

/// The first line of an Align With, waiting for the second. 1-based.
private struct AlignEnd: Equatable {
    let side: ComparePaneSide
    let line: Int
}

/// Everything the panes draw that is derived from the two texts, built in
/// one pass off the main thread. Checks for cancellation between stages and
/// gives back nil once it is set.
private struct CompareSnapshot: Sendable {
    let rows: [CompareRow]
    let anchors: [Int]
    /// The pins that still hold, and the rows they put together.
    let pins: [ManualPin]
    let pinnedRows: Set<Int>
    let resolved: [ResolvedLine]
    let searchColumns: [[String]]
    /// The working buffer split once, so building a section's text is
    /// linear in the section rather than in the file.
    let workingLines: [String]
    /// Nil for a side whose text is unchanged since it was last scanned —
    /// the tokens already held for it still apply.
    let headSyntax: [[SyntaxToken]]?
    let workingSyntax: [[SyntaxToken]]?

    static func make(
        head: String,
        working: String,
        pins: [ManualPin],
        language: SyntaxLanguage?,
        rescanHead: Bool,
        rescanWorking: Bool
    ) -> CompareSnapshot? {
        let left = LineDiff.split(head)
        let right = LineDiff.split(working)
        let pins = pins.filter {
            left.indices.contains($0.alignment.left) && left[$0.alignment.left] == $0.headText
                && right.indices.contains($0.alignment.right) && right[$0.alignment.right] == $0.workingText
        }
        let rows = LineDiff.compute(left: left, right: right, pins: pins.map(\.alignment))
        guard !Task.isCancelled else { return nil }
        let resolved = resolveSpans(in: rows)
        guard let resolved, !Task.isCancelled else { return nil }

        // Whole-document scans rather than lazily per visible row: the panes
        // are `LazyVStack`s, so a lazy scheme would rescan the same lines on
        // every scroll, and a document scan is one linear pass.
        var headSyntax: [[SyntaxToken]]?
        var workingSyntax: [[SyntaxToken]]?
        if let language {
            if rescanHead { headSyntax = SyntaxHighlighter.highlight(document: head, language: language) }
            guard !Task.isCancelled else { return nil }
            if rescanWorking { workingSyntax = SyntaxHighlighter.highlight(document: working, language: language) }
            guard !Task.isCancelled else { return nil }
        } else {
            headSyntax = []
            workingSyntax = []
        }

        // A pin's row is the one holding its HEAD line: the pair's first half
        // when the two lines differ, which is the row drawn for both.
        let pinnedLeft = Set(pins.map { $0.alignment.left + 1 })
        return CompareSnapshot(
            rows: rows,
            anchors: LineDiff.changeAnchors(in: rows),
            pins: pins,
            pinnedRows: pinnedLeft.isEmpty
                ? []
                : Set(rows.indices.filter { rows[$0].leftLine.map(pinnedLeft.contains) == true }),
            resolved: resolved,
            searchColumns: [
                resolved.map { $0.leftSpans.map(\.text).joined() },
                resolved.map { $0.rightSpans.map(\.text).joined() }
            ],
            workingLines: TextBufferEdits.lines(of: working),
            headSyntax: headSyntax,
            workingSyntax: workingSyntax
        )
    }

    /// Walks the row list looking for adjacent `removed` then `added`
    /// pairs (line replacement, the common case) and pre-computes a
    /// word-level diff for each. Other rows become trivial single-span
    /// renderings.
    private static func resolveSpans(in rows: [CompareRow]) -> [ResolvedLine]? {
        // Resolved entries are indexed 1:1 with input rows so
        // `DiffDisplayRow.row(i)` can look up `resolved[i]` directly.
        var out: [ResolvedLine] = []
        out.reserveCapacity(rows.count)
        var i = 0
        while i < rows.count {
            if i % 1024 == 0, Task.isCancelled { return nil }
            let row = rows[i]
            if row.kind == .removed,
               i + 1 < rows.count,
               rows[i + 1].kind == .added
            {
                // Beyond Compare-style: render a remove+add pair as
                // ONE row with the old text on the left and the new
                // text on the right, both at the same Y. Word-level
                // intra-line spans tint which characters changed.
                // The second slot is kept as a hidden placeholder so
                // `resolved[i]` keeps lining up with `rows[i]`.
                let next = rows[i + 1]
                let (l, r) = WordDiff.diff(
                    left: row.leftText ?? "",
                    right: next.rightText ?? ""
                )
                out.append(ResolvedLine(
                    id: i,
                    leftLine: row.leftLine,
                    leftSpans: l,
                    leftKind: .removed,
                    rightLine: next.rightLine,
                    rightSpans: r,
                    rightKind: .added,
                    hidden: false
                ))
                out.append(ResolvedLine(
                    id: i + 1,
                    leftLine: nil,
                    leftSpans: [],
                    leftKind: nil,
                    rightLine: nil,
                    rightSpans: [],
                    rightKind: nil,
                    hidden: true
                ))
                i += 2
                continue
            }
            out.append(ResolvedLine.fromSimple(row: row, id: i))
            i += 1
        }
        return out
    }
}

/// Fully resolved render data for one row of the diff. Splitting this
/// out of `CompareRowView` keeps the LCS + WordDiff work in a single
/// pre-pass instead of being redone every SwiftUI render.
private struct ResolvedLine: Identifiable, Sendable {
    let id: Int                          // index in resolved list — stable
    let leftLine: Int?
    let leftSpans: [DiffSpan]
    let leftKind: CompareRow.Kind?       // nil means "no content on this side"
    let rightLine: Int?
    let rightSpans: [DiffSpan]
    let rightKind: CompareRow.Kind?
    /// True for the trailing entry of a removed+added pair: that pair
    /// is now rendered as one combined row (Beyond Compare-style) at
    /// the position of the `.removed` half, and this entry exists only
    /// so `resolved[i]` stays index-aligned with `rows[i]`. Render an
    /// `EmptyView` for these.
    var hidden: Bool = false

    static func fromSimple(row: CompareRow, id: Int) -> ResolvedLine {
        switch row.kind {
        case .same:
            return ResolvedLine(
                id: id,
                leftLine: row.leftLine,
                leftSpans: [DiffSpan(text: row.leftText ?? "", kind: .same)],
                leftKind: .same,
                rightLine: row.rightLine,
                rightSpans: [DiffSpan(text: row.rightText ?? "", kind: .same)],
                rightKind: .same
            )
        case .removed:
            return ResolvedLine(
                id: id,
                leftLine: row.leftLine,
                // `.same`, not `.changed` — matching the `.added` case below.
                // The word-level background means "these particular characters
                // changed"; on a line that is wholly gone every character did,
                // so it says nothing the row background and gutter accent
                // don't already say, and it left deletions wearing a band that
                // insertions never got.
                leftSpans: [DiffSpan(text: row.leftText ?? "", kind: .same)],
                leftKind: .removed,
                rightLine: nil,
                rightSpans: [],
                rightKind: nil
            )
        case .added:
            return ResolvedLine(
                id: id,
                leftLine: nil,
                leftSpans: [],
                leftKind: nil,
                rightLine: row.rightLine,
                rightSpans: [DiffSpan(text: row.rightText ?? "", kind: .same)],
                rightKind: .added
            )
        case .modified:
            // Matched to each other but not identical — a whitespace-only
            // difference. Rendered exactly like a remove+add pair, one row
            // with both sides at the same Y, and the word diff carrying
            // which characters moved. Without those spans the difference
            // would be invisible: two lines that look the same, aligned,
            // with nothing to say why the row is marked.
            let (l, r) = WordDiff.diff(
                left: row.leftText ?? "",
                right: row.rightText ?? ""
            )
            return ResolvedLine(
                id: id,
                leftLine: row.leftLine,
                leftSpans: l,
                leftKind: .removed,
                rightLine: row.rightLine,
                rightSpans: r,
                rightKind: .added
            )
        }
    }
}

/// "··· N lines hidden ···" placeholder for a collapsed unchanged region.
///
/// Two arrows rather than one click that opens everything. A fold in a
/// real file is often hundreds of lines, and what someone wants when they
/// press it is a few lines of context around one of the blocks it
/// separates — not the whole gap laid out, which in a large file is a
/// visible stall. Down carries the block above further down; up carries
/// the block below further up. "Show all" is still there for the times
/// that is what was meant.
private struct FoldMarkerRow: View {
    let hiddenCount: Int
    let chunk: Int
    let expandDown: () -> Void
    let expandUp: () -> Void
    let expandAll: () -> Void
    let firstLeftLine: Int?
    let firstRightLine: Int?
    @Environment(\.monoFontSize) private var monoSize

    var body: some View {
        HStack(spacing: 8) {
            FoldExpandButtons(
                hiddenCount: hiddenCount,
                chunk: chunk,
                expandDown: expandDown,
                expandUp: expandUp,
                expandAll: expandAll
            )
            Text("\(hiddenCount) unchanged line\(hiddenCount == 1 ? "" : "s") hidden")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
            if let l = firstLeftLine, let r = firstRightLine {
                Text("(left \(l), right \(r))")
                    .scaledFont(10)
                    .foregroundStyle(Color.textDisabled)
            }
            Spacer()
            if hiddenCount > chunk {
                Button("Show all \(hiddenCount)", action: expandAll)
                    .buttonStyle(.plain)
                    .scaledFont(10)
                    .foregroundStyle(Color.accentBlue)
                    .help("Every hidden line at once — slow in a large file, which is what the arrows are for")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.bgPanelHeader.opacity(0.7))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.borderColor).frame(height: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.borderColor).frame(height: 0.5)
        }
    }
}

/// The arrows themselves, shared by the full-width marker and the
/// half-width one each pane draws.
private struct FoldExpandButtons: View {
    let hiddenCount: Int
    let chunk: Int
    let expandDown: () -> Void
    let expandUp: () -> Void
    let expandAll: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            // A gap no bigger than one press has nothing to expand *towards*
            // — two arrows that do the same thing is a choice with no
            // meaning, so it becomes one.
            if hiddenCount <= chunk {
                button("chevron.down.circle", help: "Show the \(hiddenCount) hidden lines", action: expandAll)
            } else {
                button(
                    "chevron.down.circle",
                    help: "Show \(chunk) more lines below the block above",
                    action: expandDown
                )
                button(
                    "chevron.up.circle",
                    help: "Show \(chunk) more lines above the block below",
                    action: expandUp
                )
            }
        }
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Renders one aligned line of the side-by-side diff. Both cells live
/// in a single HStack so vertical scroll keeps the two columns
/// pixel-aligned (no separate ScrollViews needed for sync).
private struct CompareRowView: View {
    let line: ResolvedLine
    let wrapLines: Bool
    /// Syntax runs for this row's HEAD and WORKING lines, resolved by the
    /// parent from its per-document scan.
    var leftSyntax: [SyntaxToken] = []
    var rightSyntax: [SyntaxToken] = []
    var leftMatches: [TextSearchMatch] = []
    var rightMatches: [TextSearchMatch] = []
    var currentMatch: TextSearchMatch?
    /// Opens this row's block for typing. Nil for a file that can't be
    /// written to.
    var onEditWorking: (() -> Void)? = nil
    @State private var hoveringWorking = false
    @Environment(\.monoFontSize) private var monoSize

    private static let gutterWidth: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            cell(lineNumber: line.leftLine,
                 spans: line.leftSpans,
                 syntax: leftSyntax,
                 matches: leftMatches,
                 kind: line.leftKind,
                 changeBackground: Color.diffDelWordBg)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            workingCell
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The WORKING half. It is a click target — it opens the editor — and
    /// says so on hover: a column that silently starts accepting clicks is a
    /// column nobody clicks.
    @ViewBuilder
    private var workingCell: some View {
        let base = cell(lineNumber: line.rightLine,
                        spans: line.rightSpans,
                        syntax: rightSyntax,
                        matches: rightMatches,
                        kind: line.rightKind,
                        changeBackground: Color.diffAddWordBg)
            .overlay {
                if onEditWorking != nil, hoveringWorking, line.rightLine != nil {
                    Rectangle()
                        .stroke(Color.accentBlue.opacity(0.5), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hoveringWorking = $0 }
            .contentShape(Rectangle())

        if let onEditWorking {
            base.onTapGesture { onEditWorking() }
        } else {
            base
        }
    }

    @ViewBuilder
    private func cell(
        lineNumber: Int?,
        spans: [DiffSpan],
        syntax: [SyntaxToken],
        matches: [TextSearchMatch],
        kind: CompareRow.Kind?,
        changeBackground: Color
    ) -> some View {
        HStack(spacing: 0) {
            // Gutter — line number + tiny side-marker bar
            HStack(spacing: 0) {
                Text(lineNumber.map(String.init) ?? "")
                    .font(.mono(size: max(9, monoSize - 2)))
                    .foregroundStyle(Color.textDisabled)
                    .frame(width: Self.gutterWidth, alignment: .trailing)
                    .padding(.trailing, 4)
                Rectangle()
                    .fill(gutterAccent(for: kind))
                    .frame(width: 2)
            }
            .background(Color.bgPanelHeader.opacity(0.7))

            // Content — attributed text with per-span backgrounds for
            // the intra-line word diff. A cell with no counterpart (.added
            // on the left, .removed on the right) is hatched rather than
            // left blank, so a block of them reads as one absent region
            // instead of as a run of empty lines.
            ZStack(alignment: .leading) {
                if kind == nil {
                    DiffAbsentHatch()
                } else {
                    Rectangle()
                        .fill(rowBackground(for: kind))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if spans.isEmpty {
                    Text(" ")
                        .font(.mono(size: monoSize))
                        .padding(.horizontal, 6)
                } else {
                    SpanText(
                        spans: spans,
                        syntax: syntax,
                        searchMatches: matches,
                        currentMatch: currentMatch,
                        fontSize: monoSize,
                        changeBackground: changeBackground,
                        wrapLines: wrapLines
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                }
            }
        }
    }

    /// Subtle pane background for the whole row on the affected side.
    private func rowBackground(for kind: CompareRow.Kind?) -> Color {
        switch kind {
        case .removed: return Color.diffDelBg.opacity(0.5)
        case .added:   return Color.diffAddBg.opacity(0.5)
        case .same, .none: return .clear
        // A side is never `.modified` — `fromSimple` splits such a pair into
        // `.removed` on the left and `.added` on the right.
        case .modified: return .clear
        }
    }

    /// Vertical accent bar in the gutter — pure visual cue that
    /// matches what BBEdit / Beyond Compare do at the row edge.
    private func gutterAccent(for kind: CompareRow.Kind?) -> Color {
        switch kind {
        case .removed: return Color.diffDelText.opacity(0.7)
        case .added:   return Color.diffAddText.opacity(0.7)
        case .same, .none: return .clear
        // A side is never `.modified` — `fromSimple` splits such a pair into
        // `.removed` on the left and `.added` on the right.
        case .modified: return .clear
        }
    }
}

/// A drafted block's text, waiting for Save.
///
/// One `Text` per line rather than one multi-line `Text`: each line is pinned
/// to the same height the diff rows use, which is what keeps the block the
/// exact height the padding either side of it was computed for.
private struct BlockDraftText: View {
    let lines: [String]
    let fontSize: CGFloat
    let lineHeight: CGFloat
    /// Blank rows before each line, plus a trailing entry — see
    /// `BlockEdit.gaps`. Keeps a waiting draft standing where the open
    /// editor stood, so closing one does not slide the column.
    var gaps: [Int] = []

    private func gap(before line: Int) -> Int {
        gaps.indices.contains(line) ? gaps[line] : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                if gap(before: index) > 0 {
                    Color.clear.frame(height: CGFloat(gap(before: index)) * lineHeight)
                }
                Text(line.isEmpty ? " " : line)
                    .font(.mono(size: fontSize))
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: lineHeight, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            if gap(before: lines.count) > 0 {
                Color.clear.frame(height: CGFloat(gap(before: lines.count)) * lineHeight)
            }
        }
    }
}

/// A block of the working file, open for typing inside the diff.
///
/// An `NSTextView` without a scroll view of its own: the pane it sits in
/// already scrolls, and a second scroller inside one block would let the text
/// move independently of the HEAD lines it is being compared against.
///
/// Every line is pinned to `lineHeight` through the paragraph style, so the
/// editor is exactly `lines × lineHeight` tall. That is what lets the view
/// around it pad the other pane by a line count instead of measuring: the two
/// columns stay row-for-row while a block grows and shrinks under the caret.
private struct BlockTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let lineHeight: CGFloat
    /// Blank rows to leave before each line — see `BlockEdit.gaps`. Drawn as
    /// paragraph spacing, so the buffer holds the file's lines and nothing
    /// else: there is no filler to recognise again on save, and so no rule
    /// that can be made to eat a real line for looking like one.
    var gaps: [Int] = []
    /// Which line of the block to put the caret on when it opens — the one
    /// that was clicked.
    let caretLineOffset: Int
    /// Put it at the end of that line rather than the start of it.
    var caretAtLineEnd: Bool = false
    /// Escape: leave the editor, keeping the draft. Reached only when the
    /// window's own Escape hooks have stood down, which they do while a block
    /// is open.
    let onEscape: () -> Void
    /// Backspace with nothing left in the block: it goes, and the caret
    /// carries on in the block above. Backspace at the top of a block that
    /// still holds lines is handled here — see `TextBufferEdits.backspace`.
    let onBackspaceWhenEmpty: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.insertionPointColor = Palette.textPrimary
        view.textContainer?.lineFragmentPadding = 6
        // No wrapping: a long line runs past the block and the pane scrolls
        // to it, the same as every other line in the column.
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.isHorizontallyResizable = true
        view.string = text
        context.coordinator.style(view, fontSize: fontSize, lineHeight: lineHeight, gaps: gaps)

        // On the next pass: the view is not in a window yet, and
        // `makeFirstResponder` on a view without one does nothing.
        let offset = caretLineOffset
        let atEnd = caretAtLineEnd
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(
                Self.range(ofLine: offset, atLineEnd: atEnd, in: view.string)
            )
        }
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        // Only when the change came from outside — a revert, a different file.
        // Reassigning while the user types would drop the selection and clear
        // the undo stack.
        if view.string != text {
            view.string = text
            context.coordinator.style(view, fontSize: fontSize, lineHeight: lineHeight, gaps: gaps)
        } else if context.coordinator.needsRestyle(fontSize: fontSize, gaps: gaps) {
            context.coordinator.style(view, fontSize: fontSize, lineHeight: lineHeight, gaps: gaps)
        }
    }

    /// Empty range at the start of the `offset`-th line (0-based), or at its
    /// end, clamped into `text`.
    static func range(ofLine offset: Int, atLineEnd: Bool = false, in text: String) -> NSRange {
        let full = (text as NSString).length
        var location = 0
        var remaining = offset
        for character in text {
            if remaining == 0 { break }
            location += String(character).utf16.count
            if character == "\n" { remaining -= 1 }
        }
        location = min(location, full)
        if atLineEnd {
            // To the newline that ends the line, or to the end of the text if
            // this is the last one.
            let rest = (text as NSString).range(
                of: "\n",
                range: NSRange(location: location, length: full - location)
            )
            location = rest.location == NSNotFound ? full : rest.location
        }
        return NSRange(location: location, length: 0)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockTextEditor
        private var lastFontSize: CGFloat?
        private var lastGaps: [Int] = []

        init(_ parent: BlockTextEditor) { self.parent = parent }

        func needsRestyle(fontSize: CGFloat, gaps: [Int]) -> Bool {
            lastFontSize != fontSize || lastGaps != gaps
        }

        /// Font and line height for the whole block. Attribute-only, so it
        /// does not register with the undo manager and does not move the
        /// caret — safe to run under the user's cursor.
        func style(_ view: NSTextView, fontSize: CGFloat, lineHeight: CGFloat, gaps: [Int]) {
            lastFontSize = fontSize
            lastGaps = gaps
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            // A line can stand for a whole diff row, padding included, which
            // is taller than the font's own line. Pinned that tall, TextKit
            // puts all the spare height above the text, a point under where
            // the rows' text sits. So the line keeps the font's height, the
            // spare goes between lines, and the inset starts the first line
            // half of it down — mid-row, like the rows beside it.
            let textHeight = min(lineHeight, ceil(NSLayoutManager().defaultLineHeight(for: font)))
            let spare = lineHeight - textHeight
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = textHeight
            paragraph.maximumLineHeight = textHeight
            paragraph.paragraphSpacing = spare
            view.textContainerInset = NSSize(width: 0, height: spare / 2)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: Palette.textPrimary,
                .paragraphStyle: paragraph
            ]
            view.typingAttributes = attributes
            view.defaultParagraphStyle = paragraph
            view.font = font
            view.textColor = Palette.textPrimary
            guard let storage = view.textStorage else { return }
            storage.setAttributes(
                attributes,
                range: NSRange(location: 0, length: storage.length)
            )
            applyGaps(gaps, to: storage, lineHeight: lineHeight, base: paragraph)
        }

        /// Opens a gap before the lines that need one, as space above the
        /// paragraph rather than as text in it.
        ///
        /// Pinned to paragraph *positions*, which is what makes it survive
        /// typing: editing inside a line moves nothing, and adding one slides
        /// the gaps below it by a row until the next Save re-runs the
        /// alignment. Space in the wrong place is a cosmetic fault — the
        /// reason for not making it out of characters is that the other kind
        /// of fault would be in the file.
        private func applyGaps(
            _ gaps: [Int],
            to storage: NSTextStorage,
            lineHeight: CGFloat,
            base: NSMutableParagraphStyle
        ) {
            guard gaps.contains(where: { $0 > 0 }) else { return }
            let text = storage.string as NSString
            var lineStarts: [Int] = [0]
            text.enumerateSubstrings(
                in: NSRange(location: 0, length: text.length),
                options: [.byLines, .substringNotRequired]
            ) { _, _, enclosing, _ in
                let next = NSMaxRange(enclosing)
                if next < text.length { lineStarts.append(next) }
            }

            for (index, rows) in gaps.enumerated() where rows > 0 {
                let style = base.mutableCopy() as! NSMutableParagraphStyle
                let space = CGFloat(rows) * lineHeight
                if index < lineStarts.count {
                    // Space above the line the gap belongs before.
                    style.paragraphSpacingBefore = space
                    let start = lineStarts[index]
                    let paragraph = text.paragraphRange(for: NSRange(location: start, length: 0))
                    storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                } else if let last = lineStarts.last {
                    // Past the end: the gap hangs off the final line instead.
                    style.paragraphSpacing += space
                    let paragraph = text.paragraphRange(for: NSRange(location: last, length: 0))
                    storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }

        func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                switch TextBufferEdits.backspace(
                    in: view.string,
                    selection: view.selectedRange()
                ) {
                case .passThrough:
                    return false
                case .leaveBlock:
                    parent.onBackspaceWhenEmpty()
                    return true
                case .dropFirstLine:
                    dropFirstLine(in: view)
                    return true
                }
            default:
                return false
            }
        }

        /// Takes the emptied first line out of the block, leaving the caret
        /// where it is — which is now the start of the line that moved up.
        ///
        /// Written through `shouldChangeText` / `didChangeText` rather than
        /// by assigning the string: that pair is what registers the edit with
        /// the text view's undo manager and posts the change the draft is
        /// read from, so the line can be put back with ⌘Z like any other
        /// keystroke in the block.
        private func dropFirstLine(in view: NSTextView) {
            let newline = NSRange(location: 0, length: 1)
            guard view.shouldChangeText(in: newline, replacementString: "") else { return }
            view.textStorage?.replaceCharacters(in: newline, with: "")
            view.didChangeText()
            view.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }
}

/// Renders a sequence of `DiffSpan` values as one inline-styled run.
/// Uses `AttributedString` so the changed spans get a tinted background
/// without having to manually layout HStacks of `Text` views (which
/// SwiftUI lays out as separate runs and breaks selection).
struct SpanText: View {
    let spans: [DiffSpan]
    /// Syntax runs for this line, in the *original* line's coordinates. Empty
    /// for a file whose language the highlighter doesn't know, which renders
    /// exactly as it did before highlighting existed.
    var syntax: [SyntaxToken] = []
    /// Find-bar hits on this line, and which of them the bar is sitting on.
    var searchMatches: [TextSearchMatch] = []
    var currentMatch: TextSearchMatch?
    let fontSize: CGFloat
    /// Background for the characters the word diff marked as changed.
    let changeBackground: Color
    let wrapLines: Bool
    /// SwiftUI's own text selection, which scopes a drag to a single `Text`.
    ///
    /// Off in the split panes, which run their own selection across rows (see
    /// `CompareSelection`) and draw it through `selection` below. Still on
    /// where one row really is the whole of what can be selected: the bottom
    /// inspector, the wrapped single-scroll mode, the resolver's panes.
    var selectable: Bool = true
    /// Characters of this line the pane's own selection covers, as offsets
    /// into the *rendered* text — the same coordinates `CompareTextLayout`
    /// hands back, so a revealed tab counts as the columns it occupies.
    var selection: Range<Int>? = nil
    /// Whether the line break after this line is inside that selection. Drawn
    /// as a selected blank cell past the last character, which is how every
    /// editor says "the newline is in it too".
    var selectionIncludesNewline: Bool = false
    @Environment(\.showWhitespace) private var showWhitespace

    @ViewBuilder
    var body: some View {
        let base = Text(makeAttributed())
            .font(.mono(size: fontSize))
            .foregroundStyle(Color.textPrimary)
            .conditionallySelectable(selectable)
            // Painted over the line, not written into it — a selection
            // has to copy the characters, not the markers.
            .whitespaceMarkers(revealed, fontSize: fontSize)

        if wrapLines {
            base
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // Intrinsic single-line width so the enclosing horizontal
            // `ScrollView` can scroll past the cell edge — no "…"
            // truncation, just hidden text that the user can drag to.
            base
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var revealed: RevealedLine? {
        showWhitespace
            ? CompareTextLayout.revealed(spans.map(\.text).joined())
            : nil
    }

    /// Two independent layers over the same characters: syntax colour on the
    /// foreground, the word diff on the background. `CompareTextLayout` does
    /// the cutting; this only decides what each piece looks like.
    private func makeAttributed() -> AttributedString {
        var out = AttributedString()
        let runs = CompareTextLayout.runs(
            spans: spans,
            syntax: syntax,
            searchMatches: searchMatches,
            currentMatch: currentMatch,
            revealWhitespace: showWhitespace
        )
        for run in runs {
            var piece = AttributedString(run.text)
            // Set via the explicit attribute-key subscript rather than the
            // `piece.backgroundColor = …` dynamic-member setter: the latter
            // implicitly forms a non-Sendable `KeyPath` into
            // `AttributeScopes.SwiftUIAttributes`, which warns under strict
            // concurrency (an error in Swift 6 mode).
            // Whitespace glyphs override the syntax colour: a dot is
            // punctuation the file doesn't contain, and colouring it like the
            // code around it would read as content.
            piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] =
                run.isWhitespace ? Color.whitespaceGlyph : run.kind.color
            // A search hit takes the background from the word diff — while the
            // find bar is open, "where is my query" is the live question.
            switch run.search {
            case .current:
                piece[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color.searchCurrentBg
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color.black
            case .match:
                piece[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color.searchMatchBg
            case nil:
                if run.isChanged {
                    piece[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = changeBackground
                }
            }
            out.append(piece)
        }
        applySelection(to: &out)
        return out
    }

    /// Washes the selected characters, over whatever the diff, the syntax and
    /// the find bar have already put there — a selection is the user's own
    /// mark on the text, and has to win against all three.
    private func applySelection(to out: inout AttributedString) {
        let length = out.characters.count
        if let selection {
            let lower = max(0, min(selection.lowerBound, length))
            let upper = max(lower, min(selection.upperBound, length))
            if lower < upper {
                let from = out.index(out.startIndex, offsetByCharacters: lower)
                let to = out.index(out.startIndex, offsetByCharacters: upper)
                out[from..<to][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] =
                    Color.textSelectionBg
            }
        }
        guard selectionIncludesNewline else { return }
        var trailing = AttributedString(" ")
        trailing[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] =
            Color.textSelectionBg
        out.append(trailing)
    }
}

// MARK: - Split (wrap-off) mode views

/// Says the compare no longer describes what is on disk.
///
/// Only ever shown with edits pending: without them the window has already
/// read both sides again by the time this would have appeared. So it is not
/// a notice, it is a choice — the reload throws those edits away.
private struct DiskChangedBanner: View {
    let reload: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(10)
                .foregroundStyle(Color.orange)
            Text("The file has changed on disk since this compare was read")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
            Spacer()
            Button(action: reload) {
                Label("Reload", systemImage: "arrow.clockwise")
                    .scaledFont(10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentBlue)
            .help("Read both sides again, discarding the edits in this window")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.orange.opacity(0.35)).frame(height: 0.5)
        }
    }
}

/// Says Align With is waiting, and for what — the next click on the other
/// side goes somewhere it otherwise would not, so the window says so.
private struct AlignPromptBanner: View {
    let source: AlignEnd
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pin")
                .scaledFont(10)
                .foregroundStyle(Color.accentBlue)
            Text(message)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
            Spacer()
            Button("Cancel", action: cancel)
                .buttonStyle(.plain)
                .scaledFont(10)
                .foregroundStyle(Color.accentBlue)
                .help("Stop aligning (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.accentBlue.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.accentBlue.opacity(0.35)).frame(height: 0.5)
        }
    }

    private var message: String {
        let from = source.side == .left ? "HEAD" : "WORKING"
        let to = source.side == .left ? "WORKING" : "HEAD"
        return "Aligning \(from) line \(source.line) — click the \(to) line that belongs beside it"
    }
}

/// Where the hovered HEAD row sits in its pane's viewport, so the copy arrow
/// can be drawn beside it without living inside the pane's horizontal scroll.
private struct CopyArrowRowKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// Which side of the side-by-side diff a `HalfRowView` belongs to.
/// Named with the `ComparePane` prefix to avoid colliding with the
/// project-level `DiffSide` (`.old` / `.new`) used by the hunk model.
enum ComparePaneSide: Hashable, Sendable {
    case left, right

    var opposite: ComparePaneSide { self == .left ? .right : .left }
}

/// Compare is the two-member specialization of the shared scroll group also
/// used by the resolver's three aligned panes.
typealias ComparePaneScrollSync = SynchronizedPaneScrollGroup<ComparePaneSide>

/// Renders one *side* of one diff row for split-pane (wrap-off) mode.
/// Lives inside its pane's horizontal `ScrollView`, so the text is
/// laid out at its natural single-line width — no truncation, drag
/// the pane to see the rest. `minRowWidth` keeps short rows filling
/// at least the pane viewport so the per-row tint doesn't end
/// abruptly mid-pane.
private struct HalfRowView: View {
    let line: ResolvedLine
    let side: ComparePaneSide
    /// Width of the pane this row sits in. Rows are otherwise as wide as
    /// their text, which is what lets a long line scroll — but a row with no
    /// text at all would then hatch a few pixels of nothing, so the absent
    /// ones stretch to the full pane instead.
    var minRowWidth: CGFloat = 0
    /// Syntax runs for this side's line, resolved by the parent from its
    /// per-document scan.
    var syntax: [SyntaxToken] = []
    var searchMatches: [TextSearchMatch] = []
    var currentMatch: TextSearchMatch?
    /// True on the WORKING pane of an editable file: the row outlines itself
    /// on hover to say it can be clicked into.
    var isEditTarget: Bool = false
    /// The part of this row the pane's drag selection covers, and whether the
    /// line break after it is in there too. Both resolved by the parent, which
    /// is the only thing that knows where the drag started.
    var selection: Range<Int>? = nil
    var selectionIncludesNewline: Bool = false
    @State private var hovering = false
    @Environment(\.monoFontSize) private var monoSize

    static let gutterWidth: CGFloat = 44

    /// Where a row's text starts, measured from the row's left edge: the
    /// gutter, its trailing gap and accent bar, then the cell's own padding.
    /// The pane's hit-testing subtracts this before asking CoreText which
    /// character an X offset lands on, so the two have to agree exactly.
    static let textOriginX: CGFloat = gutterWidth + 4 + 2 + 6

    private var lineNumber: Int? {
        side == .left ? line.leftLine : line.rightLine
    }
    private var spans: [DiffSpan] {
        side == .left ? line.leftSpans : line.rightSpans
    }
    private var kind: CompareRow.Kind? {
        side == .left ? line.leftKind : line.rightKind
    }
    private var changeBackground: Color {
        side == .left ? Color.diffDelWordBg : Color.diffAddWordBg
    }

    var body: some View {
        HStack(spacing: 0) {
            // Gutter — line number + tiny side-marker bar.
            HStack(spacing: 0) {
                Text(lineNumber.map(String.init) ?? "")
                    .font(.mono(size: max(9, monoSize - 2)))
                    .foregroundStyle(Color.textDisabled)
                    .frame(width: Self.gutterWidth, alignment: .trailing)
                    .padding(.trailing, 4)
                Rectangle()
                    .fill(gutterAccent(for: kind))
                    .frame(width: 2)
            }
            .background(Color.bgPanelHeader.opacity(0.7))

            // Content — natural single-line width so long lines push
            // the row past the pane viewport and the parent
            // `ScrollView` actually has something to scroll.
            Group {
                if spans.isEmpty {
                    // Nothing on this side at all. It still takes a row, and
                    // a selection running through it still has to show, so
                    // the blank cell carries the wash on its own.
                    Text(" ")
                        .font(.mono(size: monoSize))
                        .background(selectionIncludesNewline ? Color.textSelectionBg : .clear)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                } else {
                    SpanText(
                        spans: spans,
                        syntax: syntax,
                        searchMatches: searchMatches,
                        currentMatch: currentMatch,
                        fontSize: monoSize,
                        changeBackground: changeBackground,
                        wrapLines: false,
                        // The pane owns selection in split mode — see
                        // `FileCompareView.selectionDrag`.
                        selectable: false,
                        selection: selection,
                        selectionIncludesNewline: selectionIncludesNewline
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                }
            }
            // Every row, not just the hatched ones: a blank line's text is
            // zero points wide, so a cell sized to its text is a cell that
            // cannot be clicked. The row still grows past this for long
            // lines, which is what the pane scrolls horizontally for.
            .frame(minWidth: contentMinWidth, alignment: .leading)
            .background {
                if kind == nil {
                    DiffAbsentHatch()
                } else {
                    rowBackground(for: kind)
                }
            }
            .overlay {
                if isEditTarget, hovering, lineNumber != nil {
                    Rectangle()
                        .stroke(Color.accentBlue.opacity(0.5), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering = $0 }
        }
        // Pin to the natural (text) height. Without this the gutter accent
        // `Rectangle` is vertically greedy, so when the pane's top-pinning
        // frame hands the column extra height the rows stretch to fill it
        // instead of sitting compactly at the top.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Pane width less the gutter, which draws its own background.
    private var contentMinWidth: CGFloat {
        max(0, minRowWidth - (Self.gutterWidth + 6))
    }

    private func rowBackground(for kind: CompareRow.Kind?) -> Color {
        switch kind {
        case .removed: return Color.diffDelBg.opacity(0.5)
        case .added:   return Color.diffAddBg.opacity(0.5)
        case .same, .none: return .clear
        // A side is never `.modified` — `fromSimple` splits such a pair into
        // `.removed` on the left and `.added` on the right.
        case .modified: return .clear
        }
    }

    private func gutterAccent(for kind: CompareRow.Kind?) -> Color {
        switch kind {
        case .removed: return Color.diffDelText.opacity(0.7)
        case .added:   return Color.diffAddText.opacity(0.7)
        case .same, .none: return .clear
        // A side is never `.modified` — `fromSimple` splits such a pair into
        // `.removed` on the left and `.added` on the right.
        case .modified: return .clear
        }
    }
}

/// Split-mode counterpart of `FoldMarkerRow`: one half of an "N lines
/// hidden" affordance, rendered once per pane. Only the left side
/// gets the descriptive label — the right side just shows the chevron
/// and a strip, so the two halves read as one continuous bar.
private struct FoldMarkerHalfRow: View {
    let hiddenCount: Int
    let chunk: Int
    let expandDown: () -> Void
    let expandUp: () -> Void
    let expandAll: () -> Void
    let showLabel: Bool
    let minRowWidth: CGFloat
    /// Pinned by the pane so its drag hit-testing can add row heights up
    /// instead of measuring them. Both panes draw the same marker, so both
    /// get the same number.
    let height: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            FoldExpandButtons(
                hiddenCount: hiddenCount,
                chunk: chunk,
                expandDown: expandDown,
                expandUp: expandUp,
                expandAll: expandAll
            )
            if showLabel {
                Text("\(hiddenCount) unchanged line\(hiddenCount == 1 ? "" : "s") hidden")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: minRowWidth, minHeight: height, maxHeight: height, alignment: .leading)
        .background(Color.bgPanelHeader.opacity(0.7))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.borderColor).frame(height: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.borderColor).frame(height: 0.5)
        }
    }
}

private extension View {
    /// `.textSelection(.enabled)` and `.textSelection(.disabled)`
    /// return different concrete types, so we can't pick between them
    /// with a ternary. A `@ViewBuilder` branch sidesteps that.
    @ViewBuilder
    func conditionallySelectable(_ enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
    }
}

/// `NSViewRepresentable` that fires `onWindow` every time the
/// hosting NSWindow is known, both on initial attach
/// (`viewDidMoveToWindow`) and on every SwiftUI update pass. The
/// double path is intentional: depending on SwiftUI's hosting choices
/// either signal can race or no-op, but configuring the same window
/// twice is harmless and the controller dedupes via `===`.
struct WindowFinder: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: WindowAccessorView, context: Context) {
        nsView.onWindow = onWindow
        if let window = nsView.window {
            onWindow(window)
        }
    }
}

final class WindowAccessorView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindow?(window)
        }
    }
}

/// Tells a resize that came from the window's own tab group apart from one
/// SwiftUI made up.
///
/// Split out from the controller, and phrased in sizes rather than windows,
/// so the rule can be tested without putting real windows on a screen.
enum CompareTabGroupSizing {

    /// True when `size` is the size the rest of the tab group is already at.
    ///
    /// Tabs share one frame: resizing one tab resizes all of them, and AppKit
    /// hands that shared frame to a sibling at the moment it is selected. The
    /// sibling sees it as a plain `didResize` — no live resize ever happened
    /// on *that* window — so a controller that trusts only its own drags reads
    /// it as SwiftUI auto-fit and snaps the tab back to the size it opened at,
    /// dragging the whole group down with it. That was the bug: make tab one
    /// bigger, switch to tab two, watch it shrink.
    ///
    /// Matching against the siblings rather than waving through every resize
    /// in a group keeps the auto-fit defence intact: SwiftUI fitting the
    /// window to its content produces a size no other tab is at, so that one
    /// still snaps back.
    static func isGroupSize(
        _ size: CGSize,
        siblings: [CGSize],
        tolerance: CGFloat = 0.5
    ) -> Bool {
        siblings.contains { sibling in
            abs(sibling.width - size.width) <= tolerance
                && abs(sibling.height - size.height) <= tolerance
        }
    }
}

/// Holds `FileCompareView`'s window at the size it should be.
///
/// Enforces the minimum, captures the size the user picks via
/// `didEndLiveResize`, and snaps the window back to that size on any other
/// resize — which is what stops SwiftUI's auto-fit-to-content from shrinking
/// the window when the Wrap or Collapse toggles change the content's natural
/// height.
///
/// The *opening* size is deliberately not set here: `CompareWindowPresenter`
/// sizes the window to the display before the view is hosted, and this adopts
/// whatever it finds. Overriding it here would undo that and put the window
/// back to a dialog-sized box.
///
/// A window that is one tab of a compare group has a second source of
/// legitimate sizes — the group's shared frame, set when another tab was
/// dragged bigger. See `CompareTabGroupSizing`.
@MainActor
private final class CompareWindowSizeController: ObservableObject {
    private let minSize: CGSize
    private weak var window: NSWindow?
    private var closeOnEscape: (() -> Bool)?
    private var lastUserSize: CGSize?
    // `nonisolated(unsafe)` so the nonisolated `deinit` can unregister the
    // tokens. Safe: every mutation happens on the main thread (configure /
    // teardown run on the main actor; deinit only reads-and-clears).
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var escapeMonitor: Any?
    private var suppressRestore = false

    init(minSize: CGSize) {
        self.minSize = minSize
    }

    /// Idempotent — repeat calls with the same window are no-ops.
    func configure(window: NSWindow, closeOnEscape: @escaping () -> Bool) {
        self.closeOnEscape = closeOnEscape
        guard self.window !== window else { return }
        teardown()
        self.window = window

        window.styleMask.insert(.resizable)
        window.contentMinSize = minSize
        // Adopt the size the window was opened at rather than imposing one.
        lastUserSize = atLeastMinimum(window.contentRect(forFrameRect: window.frame).size)

        // User finished a drag: that's the new target.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            // `queue: .main` guarantees this runs on the main actor; the
            // compiler can't infer that, so assert it explicitly.
            MainActor.assumeIsolated {
                guard let window, let self else { return }
                self.lastUserSize = self.atLeastMinimum(
                    window.contentRect(forFrameRect: window.frame).size
                )
            }
        })

        // Any other resize is SwiftUI auto-fit — snap it back.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreIfNeeded() }
        })

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let window else { return event }
            let handled = MainActor.assumeIsolated {
                self?.handleEscape(event, window: window) == true
            }
            return handled ? nil : event
        }
    }

    private func handleEscape(_ event: NSEvent, window: NSWindow) -> Bool {
        guard event.isEscapeKey,
              receivesEscapeEvent(event, window: window)
        else { return false }
        return closeOnEscape?() == true
    }

    private func receivesEscapeEvent(_ event: NSEvent, window: NSWindow) -> Bool {
        event.windowNumber == window.windowNumber
            || window.isKeyWindow
            || NSApp.keyWindow === window
            || (window.sheetParent != nil && NSApp.keyWindow === window.sheetParent)
    }

    /// Never track a size below the window's own minimum.
    ///
    /// `lastUserSize` is latched and then re-applied on every stray resize, so
    /// a single bad reading pins the window at that size for good — there is
    /// no path back up. Clamping here means that even if the window is somehow
    /// measured while collapsed, the controller pulls it back out instead of
    /// enforcing the collapse.
    private func atLeastMinimum(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(size.width, minSize.width),
            height: max(size.height, minSize.height)
        )
    }

    private func restoreIfNeeded() {
        guard !suppressRestore,
              let window,
              !window.inLiveResize,
              let target = lastUserSize.map(atLeastMinimum) else { return }
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(current.width - target.width) > 0.5
              || abs(current.height - target.height) > 0.5 else { return }
        // The size a sibling tab is already at is the user's own resize
        // arriving by way of the tab group, not something to undo.
        if CompareTabGroupSizing.isGroupSize(current, siblings: siblingTabSizes(of: window)) {
            lastUserSize = atLeastMinimum(current)
            return
        }
        suppressRestore = true
        window.setContentSize(target)
        DispatchQueue.main.async { [weak self] in
            self?.suppressRestore = false
        }
    }

    /// Content sizes of the other tabs sharing `window`'s group. Empty when
    /// the window stands alone, which is every compare opened on its own.
    private func siblingTabSizes(of window: NSWindow) -> [CGSize] {
        guard let group = window.tabGroup else { return [] }
        return group.windows
            .filter { $0 !== window }
            .map { $0.contentRect(forFrameRect: $0.frame).size }
    }

    private func teardown() {
        for o in observers {
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    deinit {
        for o in observers {
            NotificationCenter.default.removeObserver(o)
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }
}
