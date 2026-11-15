import SwiftUI

/// Diff-line context menu. Receives the line that was right-clicked plus
/// the hunk it belongs to (when known) so it can wire Stage Line / Stage
/// Hunk through `DiffPatchBuilder` + `git apply`. Selection-aware items
/// (Stage Selection, Discard Selection, …) read the current set of
/// selected line ids from the diff view-model.
///
/// The current diff source dictates which actions make sense: stage/
/// unstage are only available for working-tree or staged-index diffs of a
/// single file (i.e. `source.isStageable`). Stash diffs disable them.
struct DiffContextMenu: View {
    let line: DiffLine?
    let hunk: DiffHunk?
    let source: DiffSource
    @Bindable var appState: AppState
    @Bindable var viewModel: DiffViewModel

    private var lineIsActionable: Bool {
        guard let t = line?.type else { return false }
        return t == .add || t == .del
    }

    private var canStage: Bool {
        source.isStageable && source.file != nil
    }

    /// Selected ids that point at an actionable (+/-) line — context and
    /// empty lines in the selection are ignored at apply time.
    private var actionableSelectionIDs: Set<UUID> {
        var actionable: Set<UUID> = []
        for hunk in viewModel.hunks {
            for line in hunk.lines where line.type == .add || line.type == .del {
                actionable.insert(line.id)
            }
        }
        return viewModel.selection.ids.intersection(actionable)
    }

    /// True when the user has at least one stage-able line highlighted
    /// (and that line is *not* just the row they right-clicked). When
    /// only the clicked line is "selected" we fall through to the
    /// single-line items rather than duplicate them.
    private var hasMultiSelection: Bool {
        actionableSelectionIDs.count > 1
    }

    var body: some View {
        Group {
            if source.staged {
                stagedItems
            } else {
                workingTreeItems
            }

            Divider()

            // Whole rows, not the drag-selected characters inside one:
            // SwiftUI scopes text selection to a single `Text`, and a diff
            // row is one — so without these, nothing spanning two lines can
            // be got out of the panel at all.
            DiffRowCopyMenu(
                line: line,
                selection: viewModel.selection,
                lines: viewModel.flatLines,
                appState: appState
            )

            Button("Edit in Index Editor") {
                appState.notImplemented("Index Editor")
            }
            .disabled(true)
        }
    }

    // MARK: - Working-tree (unstaged) items

    @ViewBuilder
    private var workingTreeItems: some View {
        // Visual parity with SmartGit's menu. We don't yet implement
        // word-level (intra-line) staging — git's index is line-oriented
        // and partial-line staging needs us to manufacture a fresh blob
        // for the index. Listed disabled so the slot stays familiar.
        Button("Stage Inner-line Change") { }
            .disabled(true)
            .help("Not yet implemented")

        Button("Stage Line") {
            if let line, let hunk, let file = source.file {
                Task { await appState.stageLine(line, in: hunk, file: file) }
            }
        }
        .disabled(!lineIsActionable || !canStage)

        if hasMultiSelection {
            let ids = actionableSelectionIDs
            Button("Stage Selection (\(ids.count))") {
                if let file = source.file {
                    Task { await appState.stageLines(ids, in: viewModel.hunks, file: file) }
                }
            }
            .disabled(!canStage)
        }

        Button("Stage Hunk") {
            if let hunk, let file = source.file {
                Task { await appState.stageHunk(hunk, file: file) }
            }
        }
        .disabled(hunk == nil || !canStage)

        Divider()

        Button("Discard Line") {
            if let line, let hunk, let file = source.file {
                Task { await appState.discardLine(line, in: hunk, file: file) }
            }
        }
        .disabled(!lineIsActionable || !canStage)

        if hasMultiSelection {
            let ids = actionableSelectionIDs
            Button("Discard Selection (\(ids.count))") {
                if let file = source.file {
                    Task { await appState.discardLines(ids, in: viewModel.hunks, file: file) }
                }
            }
            .disabled(!canStage)
        }

        Button("Discard Hunk") {
            if let hunk, let file = source.file {
                Task { await appState.discardHunk(hunk, file: file) }
            }
        }
        .disabled(hunk == nil || !canStage)
    }

    // MARK: - Staged-index items

    @ViewBuilder
    private var stagedItems: some View {
        Button("Unstage Line") {
            if let line, let hunk, let file = source.file {
                Task { await appState.unstageLine(line, in: hunk, file: file) }
            }
        }
        .disabled(!lineIsActionable || !canStage)

        if hasMultiSelection {
            let ids = actionableSelectionIDs
            Button("Unstage Selection (\(ids.count))") {
                if let file = source.file {
                    Task { await appState.unstageLines(ids, in: viewModel.hunks, file: file) }
                }
            }
            .disabled(!canStage)
        }

        Button("Unstage Hunk") {
            if let hunk, let file = source.file {
                Task { await appState.unstageHunk(hunk, file: file) }
            }
        }
        .disabled(hunk == nil || !canStage)
    }
}
