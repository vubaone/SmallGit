# SmallGit — SmartGit-Inspired Specification

> Reconciled with the code on 2026-09-28. The code is the source of truth; if this document and the code disagree, the code wins.

## For: AI Coding Agents (Claude, Codex, Copilot Workspace, etc.)

This started as the pre-implementation design spec. It is now an orientation
document: what the app is, where things live, and which types to read. It does
not try to list every feature. Related documents:

- `ARCHITECTURE.md` (repo root) — overall architecture
- `docs/architecture/SMALLGIT_CACHE_SPEC.md` — the L1/L2/L3 cache and invalidation
- `docs/architecture/SMALLGIT_CONTEXTMENUS_SPEC.md` — every context menu
- `docs/architecture/SMALLGIT_INDEX.md` — index of the docs

---

## 1. Project Overview

### 1.1 What Is This?

A free, open-source **native macOS** Git GUI for SmartGit-style workflows.
SmallGit implements familiar Git client patterns with a native SwiftUI
interface, while keeping its branding, code, and design independent.

### 1.2 Core Philosophy

- Toolbar buttons and menu items map to `git` CLI commands (a few, like Save
  Snapshot, are short sequences of them)
- The app NEVER bundles its own git binary — it calls the system's `git` executable via `Process`
- All git operations are async (`async/await`) and non-blocking
- Every user-initiated git action is recorded in the Output panel: the entry
  opens as running and is filled in with the command, output, status and
  duration when the command finishes (output is buffered, not streamed line by
  line — only the Terminal panel streams). Every git invocation, including
  background reads, also goes to the diagnostics log
- The app reads SmartGit's config files to offer a "Sync from SmartGit" onboarding flow

### 1.3 Tech Stack

| Layer | Technology | Notes |
|-------|-----------|--------|
| **UI Framework** | SwiftUI (plus AppKit where needed: `NSTextView` compare panes, `NSOpenPanel`, `NSWorkspace`) | |
| **App Lifecycle** | SwiftUI `App` + a small `NSApplicationDelegateAdaptor` (`AppDelegate` in `SmallGitApp.swift`) | Delegate themes the app before first draw, raises the open-file limit, flushes the log on quit |
| **Layout** | `HSplitView` / `VSplitView` | Resizable panels; no `NavigationSplitView` |
| **State** | `@Observable` (Observation framework) | `AppState` is the root; `@MainActor` |
| **Git Operations** | `Process` spawning `git` via `ProcessRunner` actor | Behind the `GitBackend` protocol |
| **Caching** | `CacheCoordinator` — L1 memory, L2 JSON on disk (`~/Library/Caches/SmallGit/`), L3 git | See SMALLGIT_CACHE_SPEC.md |
| **File Watching** | `FSEvents` (`FileWatcherService`) | |
| **YAML Parsing** | `Yams` (SPM package) | For reading SmartGit config files |
| **Data Persistence** | `Codable` + JSON files in `~/Library/Application Support/SmallGit/` | |
| **Concurrency** | Swift structured concurrency, actors | `StrictConcurrency` upcoming feature enabled |
| **Min Deployment** | macOS 14.0 (Sonoma) | `Package.swift` `.macOS(.v14)` |
| **Swift Version** | swift-tools-version 5.10 | Swift 5 language mode with strict concurrency checking |

Builds: `swift build` / `swift test` from `SmallGit/` (Package.swift is the
source of truth). `scripts/build-app.sh` wraps the executable into a `.app`;
`scripts/xcode.sh` generates `SmallGit.xcodeproj` from `project.yml`
(arm64 only).

### 1.4 Project Structure

Top-level layout of the Swift package (not every file is listed):

```
SmallGit/
├── Package.swift                  // SPM manifest (Yams); macOS 14; executable + test target
├── Info.plist                     // embedded into the binary via linker flags
├── project.yml                    // XcodeGen spec for the optional Xcode project
├── Resources/AppIcon.icns
├── scripts/                       // build-app.sh, build-dmg.sh, xcode.sh, …
│
├── Sources/SmallGit/
│   ├── SmallGitApp.swift          // @main, menu commands, secondary windows, AppDelegate
│   ├── Models/                    // AppConfig, GitRepository (RepositoryEntry/Group/Config),
│   │                              // GitFileStatus, GitCommit, GitBranch, DiffHunk, OutputEntry,
│   │                              // GitSubmodule, GitWorktree, GitReflogEntry, RebaseTodo, …
│   ├── Services/
│   │   ├── GitBackend.swift       // GitBackend protocol + GitCommandResult
│   │   ├── GitService.swift       // actor — the shell-backed GitBackend
│   │   ├── ProcessRunner.swift    // actor — spawns git, buffered run + streaming
│   │   ├── GitOutputParser.swift  // porcelain/log/branch/diff/stash/… parsers
│   │   ├── DiffPatchBuilder.swift // builds patches for hunk/line staging
│   │   ├── FileWatcherService.swift
│   │   ├── ConfigService.swift    // actor — JSON config in Application Support
│   │   ├── SmartGitImporter.swift
│   │   ├── GitCredentials.swift, GitRemoteFailure.swift
│   │   ├── PlatformServices.swift, MacPlatformServices.swift  // Finder/Terminal/editor/dialogs
│   │   └── PerformanceSampler.swift, TerminalCompletion.swift, UserShellEnvironment.swift
│   ├── Cache/                     // CacheCoordinator, MemoryCache, DiskCache, InvalidationEngine, …
│   ├── Logging/                   // diagnostics log (Log, LogStore → ~/Library/Logs/SmallGit/)
│   ├── Syntax/                    // syntax highlighting, text search, compare layout
│   ├── ViewModels/                // AppState, BranchesViewModel, FilesViewModel, DiffViewModel,
│   │                              // JournalViewModel, OutputLog, TerminalViewModel,
│   │                              // ConflictResolutionViewModel, RepositoryListViewModel, …
│   ├── Views/
│   │   ├── MainWindow.swift       // root split layout, sheets, alerts
│   │   ├── ToolbarView.swift
│   │   ├── PreferencesView.swift  // Settings sheet
│   │   ├── WelcomeView.swift, SyncFromSmartGitView.swift
│   │   ├── LogWindow.swift, SubmoduleLogWindow.swift
│   │   ├── Sidebar/               // RepositoriesPanel, BranchesPanel, SubmoduleRow
│   │   ├── Content/               // FilesTableView, DiffView, TerminalPanel
│   │   ├── Bottom/                // JournalView, OutputView, BottomPanelsBar
│   │   ├── ContextMenus/          // one file per menu
│   │   ├── Dialogs/               // CommitDialog, BranchPickerSheet, ConflictResolutionView,
│   │   │                          // FileCompareView, BlameView, StashesView, …
│   │   └── Components/            // PanelHeader, StatusBar, Theme, CommitGraphCell, FindBar, …
│   ├── Utilities/                 // DateFormatters, NaturalOrder, StringExtensions
│   └── Resources/                 // (placeholder)
│
└── Tests/SmallGitTests/           // XCTest suite (see §12)
```

### 1.5 SPM Dependencies

One dependency: `Yams` (`https://github.com/jpsim/Yams.git`, from `5.0.0`).
Everything else is Apple frameworks.

---

## 2. Sync from SmartGit — Onboarding Feature

### 2.1 Concept

On first launch (no `~/Library/Application Support/SmallGit/` directory),
`AppState.isFirstLaunch` is set and `MainWindow` presents `WelcomeView` as a
sheet with three options: **Sync from SmartGit**, **Open a Repository**,
**Start Fresh**. Choosing any of them writes the config so the sheet does not
return. The welcome sheet can be reopened from Help › Welcome to SmallGit.

The import dialog (`SyncFromSmartGitView`) is also reachable from the app menu
and Help menu ("Sync from SmartGit…") and from Settings › External Tools ›
"Re-sync from SmartGit…".

### 2.2 SmartGit Config Location

```
~/Library/Preferences/SmartGit/<version>/
```

`SmartGitImporter.detect()` lists directories matching `^\d+\.\d+$`, sorts them
numerically descending, and uses the newest. There is no UI to pick a different
version.

### 2.3 SmartGit Config Files Read

| File | Used for |
|------|----------|
| `repository-grouping.yml` | **Primary source.** `structure` → groups and their repositories (`path.absolute`, else `path` with `~` expanded; `name`), plus `recentlyUsed` for ungrouped repos |
| `repositories.yml` | Fallback only when grouping yields nothing: keys of `gitRootSettingsSet` of the form `root<absolute-path>` |
| `credentials.yml` | URLs + usernames are parsed and **counted** in the dialog; nothing is imported. Passwords are never read |
| `accelerators.yml` | Parsed and **counted** in the dialog; shortcuts are not imported |

`bugtracker.yml`, `ui-state.yml` and `repository-cache` are not read.

Each repository is marked valid if its path contains a `.git` entry; paths are
deduplicated.

### 2.4 Sync Dialog

`SyncFromSmartGitView` scans on appear and shows: the version and path found,
repository count (valid · missing), group count, credentials count, keyboard
shortcut count, and — if any are missing — a checkbox "Also import N missing
paths". **Import** calls `SmartGitImporter.materialize(_:into:includeMissing:)`,
which merges repositories into `RepositoriesConfig` (skipping paths already
present, creating groups by name), then saves `repositories.json` and sets
`syncedFromSmartGit` / `smartGitConfigPath` in the app config.

---

## 3. UI Layout Specification

### 3.1 Overall Structure

```
┌─────────────────────────────────────────────────────────────┐
│ Title: active repo name (or "SmallGit")                      │
├─────────────────────────────────────────────────────────────┤
│ [Sidebar] [Refresh] | [Pull▾][Sync][Push▾] | [Commit][Stage] │
│ [Unstage][Discard] | [Save Stash▾][Apply Stash▾][Apply Patch▾]│
│ | [Merge][Rebase] | [Settings]                                │
├────────────┬────────────────────────────────────────────────┤
│ Repos      │ Files (Table: Name / State / Relative Directory)│
│ (groups,   ├────────────────────────────────────────────────┤
│  folder    │ Changes (Diff)  — or the Terminal panel         │
│  tree)     │                                                 │
├────────────┼──────────────────────┬─────────────────────────┤
│ Branches   │ Journal (graph log)  │ Output (command log)     │
│ (+ tags,   │  — collapsible to a single bar (⌃⌘J)           │
│  submods,  │                      │                          │
│  stashes)  │                      │                          │
├────────────┴──────────────────────┴─────────────────────────┤
│ Status Bar: status text · working indicator · file count ·   │
│             optional performance badge                       │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Layout Implementation

See `MainWindow.mainSplits`. An `HSplitView` holds the sidebar (a `VSplitView`
of `RepositoriesPanel` over `BranchesPanel`, hidden in compact mode) and the
content (a `VSplitView` of Files over Diff-or-Terminal, then Journal | Output in
an `HSplitView`, or `BottomPanelsBar` when collapsed). The `StatusBar` is
stacked below the splits in a `VStack` (not an overlay); transient toasts float
above. Minimum window size is 1000×640. Split ratios and the compact /
terminal / collapsed flags persist in `UIState` (§7).

Besides the main window, `SmallGitApp` declares singleton windows for **Log**
(`LogWindow`, ⌘L), **Submodule** (`SubmoduleLogWindow`) and **Resolve
Conflict** (the 4-pane resolver). File compare, File History and Stashes also
open as real windows; most other dialogs are `.sheet`s on `MainWindow`.

### 3.3 Theme

Light, Dark or System, chosen in Settings › General (`AppConfig.appearance`,
default `.system`) and applied to `NSApp` and via `.preferredColorScheme`.
Colours live in `Views/Components/Theme.swift`: a `Palette` of dynamic
`NSColor`s, each with a light and a dark value, mirrored as `Color` statics
(`bgApp`, `bgPanel`, `textPrimary`, `accentBlue`, `diffAddBg`, …). Compare and
conflict colours can be overridden per appearance in Settings › Colors
(`DiffColorOverrides`). Text size scales with ⌘= / ⌘- / ⌘0 via the
`monoFontSize` / `uiScale` environment values.

---

## 4. Feature Specifications

### 4.1 Toolbar Actions — Git Command Mapping

Defined in `Views/ToolbarView.swift`; every action routes through `AppState`,
whose `runGit` helper logs to Output, sets the status text, runs the
`GitService` call, fires post-action cache invalidation and refreshes the
panels. Toolbar labels can be hidden (Settings › General › "Show button
labels").

| Button | Behaviour / git command(s) | Menu |
|--------|----------------------------|------|
| **Sidebar** (leading) | Toggles compact mode (hides sidebar), ⌃⌘0 | — |
| **Refresh** | Force-refreshes all panels (same as ⌘R) | — |
| **Pull** (split button) | Click repeats the remembered mode: `git pull [--rebase] --autostash` (`--autostash` dropped if git rejects it) | Pull (Merge), Pull (Rebase) — checkmarked, picking one also remembers it (`pullUsesRebase`); Fetch = `git fetch --all --prune` |
| **Sync** | Pull (rebase) then push; stops if the pull did not complete or left conflicts. ⌘Y | — |
| **Push** | `git push`; a first push without upstream sets one via `pushTo`; rejected non-fast-forward pushes offer pull-then-push or force | Push, Push Tags (`git push --tags`), Force Push (with lease) (`--force-with-lease`) |
| **Commit** | Opens the commit dialog (§4.2). ⌘K | — |
| **Stage** | `git add -- <selected>`. ⌘↩ | — |
| **Unstage** | `git reset HEAD -- <selected>` (conflicted files skipped). ⌘⌫ | — |
| **Discard** | Confirmation alert, then per kind: tracked `git checkout -- <paths>`, conflicted `git checkout HEAD -- <paths>`, untracked `git clean -f -d -- <paths>` | — |
| **Save Stash** | Opens the stash dialog: `git stash push [--include-untracked] [--keep-index] [-m msg] [-- paths]` | Save Stash…, Save Stash (incl. untracked)…, Save Snapshot (keeps your changes)… (`git stash create` + `git stash store`, see `GitService.stashSnapshot`) |
| **Apply Stash** | — | Apply: <stash> (`git stash apply stash@{n}`), Pop Latest (`git stash pop`), Browse Stashes… |
| **Apply Patch** | NSOpenPanel for `.patch`/`.diff`, then `git apply --whitespace=nowarn [--3way] <file>` | Apply Patch…, Apply Patch (3-way)… |
| **Merge** | Branch picker sheet → `git merge [--ff-only] --autostash <branch>` | — |
| **Rebase** | Branch picker sheet → `git rebase --autostash <onto>` (or `--onto <onto> <from>` when the base was rewritten) | — |
| **Settings** | Opens the Settings sheet (⌘, lives on the app menu) | — |

Not in the toolbar (unlike the original plan): Log is ⌘L / Repository › Log
(the Log window); Blame and file Log (history) are on the Files context menu;
interactive rebase, squash, reword, cherry-pick, revert, reset, tags and so on
are on the Journal / Branches context menus. There is no Git-Flow,
Investigate, or standalone Index Editor.

### 4.2 Commit Dialog

`Views/Dialogs/CommitDialog.swift`, presented as a `.sheet`. Two tabs — Local
Changes and Staged Changes — with per-file checkboxes; which tab and which files
start ticked follow `CommitScope` (a Files-panel selection wins over the index).
A single message editor (first line is the subject), a History menu (Recent
Messages from `AppConfig.recentCommitMessages`, Recent Commits), "Amend last
commit", and **Cancel / Commit / Commit & Push**. Unticked staged files are
unstaged before committing.

Double-clicking a file previews what the commit will record for it, in the
external diff tool if one is set or the built-in read-only compare otherwise.
A staged file is committed as the index holds it (the dialog never re-stages
it), so it shows **HEAD vs Index** (`git diff --cached`); a file with nothing
staged, or a conflict, shows HEAD vs the working tree.

**Git command:** `git commit [--amend] -m <subject> [-m <body>]`; Commit & Push
then pushes.

### 4.3 Repositories Panel (Left Top)

**Data source:** `~/Library/Application Support/SmallGit/repositories.json`
(`RepositoriesConfig`: named `groups`, `ungrouped`, `ungroupedExpanded`).
`RepositoryEntry` holds `id`, `path`, `name`, `currentBranch`, `isFavorite`,
and the journal's `logSelection`. See `Models/GitRepository.swift`.

**Behavior** (`Views/Sidebar/RepositoriesPanel.swift`):
- Collapsible groups plus an "Other" section for ungrouped repos; a favorites-only filter
- Each repo row can expand into a lazily-read folder tree (`RepoTreeStore`)
- Click opens the repo (or double-click, if "Single click opens a repository" is off)
- Missing / non-repository folders are badged ("Not Found" / "Not a Repo") and can be relocated or removed
- Drag and drop: rearrange repos between groups; drop folders from Finder to add them
- Header menu: Add Group…, Add Existing Folder…, Clone…
- Context menus: see SMALLGIT_CONTEXTMENUS_SPEC.md (`RepositoryContextMenu`, `RepoTreeContextMenu`)

### 4.4 Branches Panel (Left Bottom)

**Data source** (`GitService.localBranches` / `remoteBranches` / `tags`):

```bash
git branch --format='%(refname:short)%00%(upstream:short)%00%(worktreepath)%00%(HEAD)%00%(upstream:remotename)%00%(upstream:track,nobracket)'
git branch -r --format='%(refname:short)%00%(upstream:short)%00%(worktreepath)%00'
git tag --sort=-creatordate
```

Names are sorted in natural order. **Behavior** (`Views/Sidebar/BranchesPanel.swift`):
- Sections: Local Branches, Remote Branches, Tags, Submodules, Stashes
- Folders built from `/`-separated name prefixes
- Checkboxes pick which refs the Journal graphs (multi-ref log, `JournalRefSelection`)
- Double-click / Return: local branch → checkout (offering fast-forward when behind); folder → toggle; stash → stash diff; submodule → open it
- Context menu (`BranchContextMenu`): Check Out, Fast-Forward, Merge, Rebase, Rebase Interactively, Push / Push To, Log, Reset, New Branch from Here, Rename, Set Tracked Branch / Stop Tracking, delete, …

### 4.5 Files Panel (Right Top)

**Data source:**

```bash
git status --porcelain=v2 -z --untracked-files=all [--ignored=traditional]
```

plus an exact-content rename pass that pairs an unstaged deletion with an
identical untracked file (`GitService.status`).

**`Table`** (`Views/Content/FilesTableView.swift`) with sortable **Name**,
**State**, **Relative Directory** columns and a coloured status dot. States
(`GitFileStatus`): Mod, Add, Del, Ren, Cop, New (untracked), Ign, Cnf
(conflict), Typ, unmodified. Header toggles ⌘1–⌘5 show staged, unstaged,
untracked, ignored and assume-unchanged files; a text filter searches the file
list. Return opens the selected file in the compare window; conflicts open the
resolver.

### 4.6 Diff Panel (Right Middle)

`Views/Content/DiffView.swift` + `ViewModels/DiffViewModel.swift`. Shows a
`DiffSource`: working-tree file changes, untracked file, conflict, stash, commit,
or submodule.

```bash
git diff [--cached] [-w] [--unified=100000] --no-color -- <file>   # HEAD↔Index / Index↔Working
git diff --no-index --no-color -- /dev/null <file>                  # untracked
git diff HEAD --no-color -- <file>                                  # conflicted
```

- Layout picker: **Unified** / **Side by Side** (`DiffMode`)
- Compare picker: **HEAD ↔ Index** (staged) / **Index ↔ Working** (unstaged) (`DiffCompareMode`)
- Overflow menu toggles: Compact (changed regions only, orthogonal to layout), Ignore Whitespace, Show Whitespace
- Syntax highlighting and line selection with copy (word-level diff is in the compare and conflict windows, not this panel)
- Stage / unstage / discard by line, selection or hunk (patches built by `DiffPatchBuilder`, applied with `git apply [--cached]`)

A switch in the panel header (⌃⌘T) swaps this slot for the **Terminal** panel,
which runs typed commands in the repo and streams their output.

### 4.7 Journal Panel (Bottom Left)

**Data source** (`GitService.log`):

```bash
git log --topo-order --format='%H%x00%h%x00%s%x00%an%x00%ae%x00%aI%x00%D%x00%P' -n <count> [--ignore-missing <refs>… | --stdin]
```

Paged 100 commits at a time. Rows are drawn with `ScrollView` + `LazyVStack`
(not a `Table`): commit graph lanes (`CommitGraphLayout`, `CommitGraphCell`),
sync marker, ref badges, subject, author badge, relative date. A working-tree
row sits on top when there are changes. Search uses `GitService.searchLog`
(message, author, content `-S`, regex `-G`) across the whole history. See
`JournalView.swift` / `JournalViewModel.swift`.

### 4.8 Output Panel (Bottom Right)

`Views/Bottom/OutputView.swift`, fed by `ViewModels/OutputLog.swift` (capped at
500 entries, FIFO). `OutputEntry` (`Models/OutputEntry.swift`) holds timestamp,
`CommandStatus` (`.running` / `.success` / `.failure`), action, detail, command,
duration and an optional link (e.g. a written patch file, revealed in Finder).
Auto-scrolls to new entries, text is selectable, and the header has a Clear
button.

### 4.9 Status Bar

`Views/Components/StatusBar.swift`: status text, a working indicator while
commands are in flight, the changed-file count, and — when enabled in Settings
› Diagnostics — a performance badge (CPU, memory, disk and network I/O from
`PerformanceSampler`). There is no line:column readout in use.

---

## 5. Keyboard Shortcuts

Main menu (`SmallGitApp.swift`) and toolbar:

| Action | Shortcut | Where bound |
|--------|----------|-------------|
| Open Repository… | ⌘O | File menu |
| Settings… | ⌘, | App menu |
| Zoom In / Out / Actual Size | ⌘= (also ⌘+) / ⌘- / ⌘0 | View menu (+ `Theme.swift` for ⌘+) |
| Refresh | ⌘R | Repository menu |
| Log window | ⌘L | Repository menu |
| Undo Last Operation… (reflog-based) | ⌥⌘Z | Repository menu |
| New Branch… | ⇧⌘B | Repository menu |
| Browse Stashes… | ⇧⌘S | Repository menu |
| Browse Reflog… | ⇧⌘G | Repository menu |
| Worktrees… | ⇧⌘T | Repository menu |
| Close Repository | ⇧⌘W | Repository menu |
| Toggle sidebar (compact mode) | ⌃⌘0 | Toolbar |
| Commit | ⌘K | Toolbar |
| Push | ⇧⌘K | Toolbar Push menu |
| Sync | ⌘Y | Toolbar |
| Stage selected | ⌘↩ | Toolbar, Files context menu |
| Unstage selected | ⌘⌫ | Toolbar, Files context menu |

Panel- and window-scoped:

| Action | Shortcut | Where |
|--------|----------|-------|
| Files filters: staged / unstaged / untracked / ignored / assume-unchanged | ⌘1 … ⌘5 | Files panel header |
| Open selected file in compare | ↩ | Files panel |
| Compare… / Resolve Conflict… | ⇧⌘D / ⇧⌘R | Files context menu |
| Toggle Diff ↔ Terminal | ⌃⌘T | Diff / Terminal header |
| Stop running terminal command | ⌘. | Terminal panel |
| Collapse / expand Journal + Output | ⌃⌘J | Bottom panels |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G | Compare and conflict windows |
| Previous / next change | ⌘K / ⌘J | Compare window |
| Reload both sides / copy block from HEAD / save | ⌘R / ⌥→ / ⌘S | Compare window |
| Previous / next conflict chunk / save & mark resolved | ⌘[ / ⌘] / ⌘S | Conflict resolver |

There is no Pull shortcut and no Discard shortcut. SmartGit accelerators are
not imported.

---

## 6. File Watching & Auto-Refresh

`Services/FileWatcherService.swift` wraps `FSEventStream` (file events, 0.4 s
latency, `NoDefer`, `WatchRoot`) on its own dispatch queue and delivers batches
of changed absolute paths. It watches one active repository at a time, rooted at
`RepoLayout.watchRoots` (the work tree, plus the git directories of a linked
worktree).

`AppState.startWatching(layout:)` hands each batch to
`CacheCoordinator.onFileSystemChange`, which uses `InvalidationEngine` to map
paths to cache keys (`.git/HEAD` → current branch + log, `.git/index` → file
status, `.git/refs/…` → branches, …). Only if something was invalidated — and
the active repo has not changed meanwhile — does it call `refreshPanels()`,
which reloads files, branches, journal, stashes, in-progress operation and
submodules. This guard avoids a feedback loop from git's own `.git/` writes.

The main window also force-refreshes when the app becomes active again (e.g.
after returning from an external merge tool). Details in SMALLGIT_CACHE_SPEC.md.

---

## 7. Data Storage

### 7.1 Locations

```
~/Library/Application Support/SmallGit/
  config.json          # AppConfig
  repositories.json    # RepositoriesConfig (groups + ungrouped repos)
  ui-state.json        # UIState (panel ratios, flags, main window frame)
~/Library/Caches/SmallGit/<repo-hash>/   # L2 disk cache
~/Library/Logs/SmallGit/                 # diagnostics log
```

`ConfigService` (actor) reads and writes the three JSON files (pretty-printed,
sorted keys, atomic writes). A file that fails to decode is moved aside as
`<name>.invalid-<timestamp>` and defaults are used. All decoders are tolerant:
missing keys fall back to defaults.

### 7.2 Config Schema

See `Models/AppConfig.swift` for the authoritative definition.

**`AppConfig`** (`config.json`):

| Field | Default | Notes |
|-------|---------|-------|
| `fontSize`, `monoFontSize` | 13, 12 | `monoFontSize` drives zoom |
| `diffMode` | `.sideBySide` | `DiffMode`: `unified`, `sideBySide` (old `"compact"` values migrate to unified + compact) |
| `diffCompactMode` | `true` | |
| `ignoreWhitespace`, `showWhitespace` | `false`, `false` | |
| `gitPath` | `nil` | nil = auto-detect (see §8.1) |
| `syncedFromSmartGit`, `smartGitConfigPath` | `false`, `nil` | |
| `externalEditor` | `.system` | `ExternalEditor`: `system`, `zed`, `vscode`, `cursor`, `windsurf`, `sublime`, `nova`, `bbedit`, `textmate`, `intellij`, `androidStudio`, `xcode`, `custom` |
| `customEditorPath` | `nil` | Used when `externalEditor == .custom` |
| `externalDiffTool` | `.builtin` | `ExternalDiffTool`: `builtin`, `beyondCompare`, `kaleidoscope`, `fileMerge`, `custom` |
| `customDiffToolPath`, `customDiffArgs`, `customMergeArgs` | `nil`, `"${leftFile} ${rightFile}"`, `"${leftFile} ${rightFile} ${baseFile} ${mergedFile}"` | |
| `lastOpenedRepoID` | `nil` | Reopened on launch |
| `toolbarShowsLabels`, `escapeClosesSubwindows`, `quitsOnMainWindowClose`, `singleClickOpensRepo` | all `true` | |
| `recentCommitMessages` | `[]` | Up to 10 |
| `diagnosticsLoggingEnabled`, `perfBadgeEnabled` | `true`, `false` | |
| `appearance` | `.system` | `AppearanceMode`: `system`, `light`, `dark` |
| `pullUsesRebase` | `false` | What the Pull button repeats |
| `diffColors` | empty | `DiffColorOverrides` per appearance |

**`UIState`** (`ui-state.json`): `sidebarWidth` (260), `reposPanelRatio` (0.5),
`topBottomRatio` (0.55), `journalOutputRatio` (0.6), `compactMode`,
`showsTerminal`, `bottomPanelsCollapsed` (all `false`), `mainWindowFrame`
(`WindowFrameState?`, restored on the same display).

**`RepositoriesConfig`** (`repositories.json`): see §4.3.

### 7.3 Settings UI

`Views/PreferencesView.swift`, presented as a sheet (⌘, or the toolbar gear —
not a SwiftUI `Settings` scene). Tabs:

- **General** — Appearance (theme), Interface (button labels, Escape closes secondary views, closing the window quits, single-click opens a repository), Editor ("Open files / folders in" + custom app), Diff defaults (mode, compact, ignore whitespace), Zoom
- **Colors** — compare/conflict colour overrides with preview
- **Git** — global identity (writes `~/.gitconfig`), git executable path with detected path
- **External Tools** — diff/merge tool, SmartGit import (Re-sync)
- **Diagnostics** — record diagnostics, performance badge, log summary tables (`DiagnosticsView`)

---

## 8. Git Operations — Backend Implementation

### 8.1 ProcessRunner

`Services/ProcessRunner.swift`, an actor (`ProcessRunner.shared`).

- `run(in:args:stdin:env:timeout:)` → `GitCommandResult` (command, exitCode,
  stdout, stderr, duration; `succeeded`, `combinedOutput`). Buffered. Prepends
  `-C <repo>`. Default timeout 120 s; network operations pass `0` (no timeout).
  Optional stdin (patches for `git apply`) and env (e.g. `GIT_SEQUENCE_EDITOR`
  for interactive rebase). Every call is recorded in the diagnostics log.
- `stream(executable:args:cwd:env:)` → `AsyncThrowingStream<ShellEvent, Error>`
  (lines, then the exit code). stdin is `/dev/null`. Used by the Terminal panel.
- git lookup (`gitExecutablePath`): the configured `gitPath`, else
  `/usr/bin/git`, `/opt/homebrew/bin/git`, `/usr/local/bin/git`, else
  `command -v git` in a login shell; throws `ProcessError.gitNotFound`.
- Environment: the user's interactive login-shell environment is captured once
  per session (`UserShellEnvironment`) so proxies, PATH and SSH agent match
  Terminal; Homebrew/MacPorts bin dirs are appended to PATH so hooks like
  git-lfs work from a Finder launch.

### 8.2 GitBackend and GitService

`Services/GitBackend.swift` defines `protocol GitBackend: Actor` — every git
operation SmallGit performs, stated independently of how it runs — plus
`GitCommandResult` and shared enums (`LogSearchMode`, `ConfigScope`,
`ConflictSide`, `InProgressOperation`). `GitService` (actor,
`GitService.shared`, `Services/GitService.swift`) is the only conformer; the
protocol exists so a future libgit2 backend (e.g. a sandboxed App Store build)
has a written contract. Default arguments live on `GitService`, so callers hold
the concrete type.

`GitService` covers, roughly: discovery and layout (`isRepository`,
`probeWorkTree`, `layout`), status and tracked/assume-unchanged files, branches,
tags, log / search / file history / blame, diffs (working tree, untracked,
conflict, commit, stash), index actions (stage, unstage, discard, clean,
hunk/line patches), commit / fixup / autosquash, pull / push / fetch / clone /
push-to, remotes and upstreams, config values and credential helper, conflict
stages and accept-ours/theirs/mark-resolved, merge / rebase / interactive rebase
/ squash / reword, continue/abort of in-progress operations, stash (save,
snapshot, apply, pop, drop, rename, diff), reflog, reset, cherry-pick, revert,
tags, submodules, worktrees, gc, patches and `.gitignore`. Failures surface as
`GitServiceError.gitFailed(command:exitCode:stderr:)` or as a non-success
result.

Read paths go through `CacheCoordinator` rather than calling `GitService`
directly; actions go through `AppState.runGit`, which calls `GitService` and
then tells the coordinator what changed (`coordinator.after(…)`).

### 8.3 Output Parsers

`Services/GitOutputParser.swift` (`enum GitOutputParser`, static functions):
`parseStatus` (porcelain v2, `-z`), `parseLog` (NUL-separated fields including
parents), `parseBranches(_:remote:)`, `parseDiff` (hunks with old/new line
numbers), `parseNameStatus`, `parseBlame`, `parseStashList`, `parseReflog`,
`parseWorktrees`, `parseSubmoduleStatus` / `parseGitmodules` /
`mergeSubmodules`, `parseAssumeUnchanged`, `parseObjectDatabaseSizeKiB`,
`isBinaryDiff`, and `autostashOutcome` (what `--autostash` did, since git exits
0 even when reapplying conflicts). Ref decorations are parsed by `RefParser`.

---

## 9. Error Handling

### 9.1 Git Not Found

There is no startup alert. If git cannot be located, commands fail with
`ProcessError.gitNotFound` (recorded in Output / status text), and Settings ›
Git shows "git not found — install Xcode CLT (xcode-select --install)" as the
detected path.

### 9.2 Repository and Remote Errors

| Situation | Handling |
|-----------|----------|
| Saved repo missing / no longer a repository | `RepositoryAvailability`: sidebar badge, empty-state panel with message, relocate or remove |
| Command failure | Output entry marked failed; status text summarises it (`AppState.failureStatus`) |
| In-progress merge / rebase / cherry-pick / revert | Detected from marker files (`InProgressOperation`); banner with Continue / Abort |
| Merge conflicts | Files panel shows conflict states; resolve in the built-in 4-pane resolver or an external tool; unstage skips conflicted files |
| Dirty tree on pull / merge / rebase | `--autostash`; a stash that fails to reapply is reported |
| Detached HEAD after checkout | Status text says so |
| HTTPS auth required | `GitCredentials` recognises git's prompt failure and shows `CredentialsSheet`; the answer is stored through git's credential helper (Keychain helper can be enabled) |
| SSH / HTTP / network failures | One-line hints from `GitCredentials.sshFailureHint` and `GitRemoteFailure.hint` (HTTP status, DNS, refused, timeout, TLS) |
| Push rejected (non-fast-forward) | Choice: pull then push, force push (with lease), or cancel |

Stale `.git/index.lock` files are not handled with a dedicated alert.

---

## 10. App Entry Point

`SmallGitApp.swift`: `WindowGroup("SmallGit") { MainWindow(appState:) }` —
the welcome flow is a sheet inside `MainWindow`, not a separate root. Commands:
File (Open Repository…), app menu (Sync from SmartGit…, Settings…), View (zoom),
a **Repository** menu (Refresh, Log, Undo Last Operation, New Branch, Merge,
Rebase, Browse Stashes, Browse Reflog, Worktrees, Submodules, Close
Repository), and Help (Welcome to SmallGit, Sync from SmartGit…). Extra scenes:
`Window("Submodule")`, `Window("Log")`, `Window("Resolve Conflict")`.
`AppState.bootstrap()` (run from `MainWindow.task`) loads the three config
files, applies `gitPath`, and reopens `lastOpenedRepoID` or the first repo.

---

## 11. Status

Implemented today (non-exhaustive): the six-panel layout with compact mode,
collapsible bottom row and Terminal panel; light/dark/system themes; repository
groups, favorites, folder tree, clone, init, relocation; SmartGit import of
repositories and groups; status, staging and discarding at file, hunk, line and
selection level; commit dialog with amend and commit & push; pull / fetch /
push / sync with autostash and credential prompts; branches, tags, remotes,
tracking; merge, rebase, interactive rebase, squash, reword, fixup, cherry-pick,
revert, reset, reflog-based undo; stashes (save, snapshot, partial, browse,
rename, multi-drop); commit graph journal with paging, multi-ref selection and
history search; Log, File History, Blame, compare windows; built-in 4-pane
conflict resolver and external diff/merge tools; submodules and worktrees;
patches; the three-layer cache with FSEvents invalidation; diagnostics logging
and performance badge.

Known unimplemented bits:
- Diff context menu: **Stage Inner-line Change** and **Edit in Index Editor** are shown disabled, not implemented (`Views/ContextMenus/DiffContextMenu.swift`)
- No Git-Flow support, no Investigate, no standalone Index Editor
- SmartGit import: credentials and keyboard shortcuts are only counted, not imported; JIRA/bugtracker and panel layout are not read

---

## 12. Testing

A single XCTest target, `Tests/SmallGitTests/` (run with `swift test` from
`SmallGit/`), ~130 test files. Coverage includes:

- Parsers — `GitOutputParserTests`, `RefParserTests`, `SubmoduleParserTests`, `WorktreeParserTests`, …
- Config — `AppConfigTests`, `ConfigServiceTests` (Codable round-trips, tolerant decode)
- SmartGit import — `SmartGitImporterTests` (fixture YAML), `SmartGitImporterLiveTests`
- Cache — `CacheTests`, `CacheEvictionTests`, `InvalidationInvariantTests`
- Integration tests against temporary git repositories — the `*IntegrationTests` files (hunk staging, line revert, conflicts, interactive rebase, remote ops, reflog, stash diff, submodules, …)
- View-model and layout logic — journal, files filtering/sorting, diff selection, commit graph, compare windows, zoom, window placement; `TestAppState.swift` is a shared helper

There are no XCUITest UI tests.

---

## 13. Non-Goals (Out of Scope)

- Windows/Linux support (macOS only — native SwiftUI)
- Git LFS management UI
- GitHub/GitLab/Bitbucket API integration (PR creation, etc.)
- Multi-language / i18n (English only)
- Auto-update (e.g. Sparkle)
- iOS/iPadOS version
