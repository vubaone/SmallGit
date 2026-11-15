import SwiftUI

struct FileContextMenu: View {
    let files: [GitFileStatus]
    @Bindable var appState: AppState

    private var paths: [String] { files.map(\.path) }
    /// Stage / unstage targets — expands renames to both the new and the
    /// original path so the move stages as a single unit (see
    /// `GitFileStatus.affectedPaths`).
    private var stagePaths: [String] { files.flatMap(\.affectedPaths) }
    /// Unstage targets. A conflicted path is not one: `git reset` on it does
    /// not take a staged change back, it throws the conflict away and leaves
    /// a file full of markers that nothing on screen calls conflicted.
    /// `AppState.unstage` drops them too, so a mixed selection still unstages
    /// the rest; this is what keeps the item from reading as available when
    /// the selection has nothing else in it.
    private var unstagePaths: [String] {
        files.filter { !$0.isConflict }.flatMap(\.affectedPaths)
    }
    private var first: GitFileStatus? { files.first }
    private var repoRoot: String? { appState.activeRepo?.path }
    private var untrackedPaths: [String] {
        files.filter { $0.state == .untracked }.map(\.path)
    }

    /// One menu item does both directions, and which one it offers is
    /// decided by the whole selection: clearing is only offered when every
    /// selected file is flagged, so a mixed selection sets the flag on the
    /// rest rather than silently unflagging the ones that had it.
    private var allAssumedUnchanged: Bool {
        !files.isEmpty && files.allSatisfy(\.isAssumeUnchanged)
    }

    /// `git update-index` needs an index entry to flag, which untracked and
    /// ignored files haven't got, and refuses a path in a conflicted state.
    /// One of those in the selection fails the whole invocation, so the item
    /// is off rather than half-working.
    private var canAssumeUnchanged: Bool {
        !files.isEmpty && files.allSatisfy { !$0.hasNoIndexEntry && !$0.isConflict }
    }

    /// Taking a path out of the index needs it to be in the index, so a
    /// selection of nothing but untracked and ignored rows has no work in
    /// it. Deleting from disk still does — `removeFiles` routes those paths
    /// through `git clean` — so only the index-only item switches off.
    private var hasIndexedFile: Bool {
        files.contains { !$0.hasNoIndexEntry }
    }

    /// Default file name for "Create Patch…" — uses the single
    /// selected file's basename when only one is selected, otherwise
    /// a "changes-N-files" stub that the user is expected to rename.
    private var suggestedPatchName: String {
        if files.count == 1, let f = first {
            return "\((f.name as NSString).deletingPathExtension).patch"
        }
        return "changes-\(files.count)-files.patch"
    }

    var body: some View {
        Group {
            if let f = first, let root = repoRoot {
                let abs = (root as NSString).appendingPathComponent(f.path)

                Button("Log") {
                    appState.fileHistoryTarget = .init(path: f.path)
                }

                if files.count > 1 {
                    Button("Compare \(files.count) Files…") {
                        appState.openCompares(paths: paths)
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(files.contains(where: \.isSubmodule))
                    .help(files.contains(where: \.isSubmodule)
                          ? "A submodule is a repository, not a file, so it cannot be included in a file compare."
                          : "Open every selected file as a tab in one compare window.")
                } else if f.isConflict {
                    Button("Resolve Conflict…") {
                        appState.openCompareOrMerge(path: f.path, isConflict: true)
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                } else {
                    Button("Compare…") {
                        appState.openCompareOrMerge(path: f.path, isConflict: false)
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                }

                if f.state != .untracked {
                    Button("Blame…") {
                        appState.blameTarget = .init(path: f.path)
                    }
                }
                Divider()

                Button("Open")            { appState.openInFinder(path: abs) }
                Button("Reveal in Finder") { appState.revealInFinder(path: abs) }
                Button("Open in Editor")   { appState.openInEditor(path: abs) }

                Divider()
            }

            Button("Stage") {
                Task { await appState.stage(files: stagePaths) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(files.isEmpty)

            Button("Unstage") {
                Task { await appState.unstage(files: unstagePaths) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(unstagePaths.isEmpty)
            .help(unstagePaths.isEmpty && !files.isEmpty
                  ? "A conflict has nothing staged to take back. Resolve it, or discard it to take HEAD's version."
                  : "Take these files out of the index")

            Button("Stash Selected…") {
                appState.pendingStashScope = AppState.PendingStashScope(
                    paths: stagePaths,
                    includesUntracked: !untrackedPaths.isEmpty
                )
                appState.showStashSaveDialog = true
            }
            .disabled(files.isEmpty)
            .help("Stash only the selected files; other changes stay in the working tree.")

            Divider()

            Button("Discard…") {
                appState.confirmDiscard = true
            }
            .disabled(files.isEmpty)

            if !untrackedPaths.isEmpty {
                Button("Delete Untracked…") {
                    Task { await appState.discardUntracked(paths: untrackedPaths) }
                }
            }

            Button("Ignore") {
                Task { await appState.addToGitignore(patterns: paths) }
            }
            .disabled(files.isEmpty)

            Button("Create Patch…") {
                appState.patchSource = .files(
                    paths: paths,
                    suggestedName: suggestedPatchName
                )
            }
            .disabled(files.isEmpty)

            Divider()

            Button(allAssumedUnchanged ? "Stop Assuming Unchanged" : "Assume Unchanged") {
                Task {
                    await appState.setAssumeUnchanged(
                        files: files,
                        on: !allAssumedUnchanged
                    )
                }
            }
            .disabled(!canAssumeUnchanged)
            .help(allAssumedUnchanged
                ? "Let git check these files again — edits to them start showing up in status and diffs."
                : "Tell git to stop checking these files. Local edits to them stay out of status, diffs and commits; ⌘5 in the Files header lists what is flagged.")

            Divider()

            Menu("Remove") {
                Button("From Index Only (keep file)") {
                    Task { await appState.removeFiles(files: files, deleteFromDisk: false) }
                }
                .disabled(!hasIndexedFile)
                .help("Untracked and ignored files are already outside the index, so there is nothing to take out of it.")

                Button("From Index and Disk") {
                    Task { await appState.removeFiles(files: files, deleteFromDisk: true) }
                }
            }
            .disabled(files.isEmpty)

            Divider()

            if let f = first, let root = repoRoot {
                let abs = (root as NSString).appendingPathComponent(f.path)
                Button("Copy Name")          { appState.copyToPasteboard(f.name) }
                Button("Copy Path")          { appState.copyToPasteboard(abs) }
                Button("Copy Relative Path") { appState.copyToPasteboard(f.path) }
            }
        }
    }
}
