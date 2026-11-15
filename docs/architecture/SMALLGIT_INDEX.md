# SmallGit — Master Specification Index

## "Small but mighty. Free but better."

Reconciled with the code on 2026-09-28. The code is the source of truth; if these documents and the code disagree, the code wins.

---

## Spec Files

Read in this order. Each file builds on the previous:

| # | File | What It Covers |
|---|------|---------------|
| 1 | `SMALLGIT_SPEC.md` | Product overview, SmartGit onboarding, UI layout and panels, features, keyboard shortcuts, file watching, data storage, git backend, error handling, testing |
| 2 | `SMALLGIT_CACHE_SPEC.md` | 3-layer cache (Memory → Disk → Git), `CacheKey`, `CacheCoordinator`, `InvalidationEngine`, FSEvents integration, maxAge guidelines, performance budget |
| 3 | `SMALLGIT_CONTEXTMENUS_SPEC.md` | Every right-click menu (repositories, branches, tags, stashes, submodules, multi-row selections, files, diff, journal and the secondary windows), each item mapped to its git command, cache invalidation, shortcut and enabled conditions |

For a two-page overview start with [`ARCHITECTURE.md`](../../ARCHITECTURE.md) at the repo root.

---

## Architecture Dependency Graph

```
SmallGitApp.swift (@main)
  │   Scenes: main WindowGroup (MainWindow), Log, Submodule and
  │   Resolve Conflict windows, Settings (PreferencesView)
  └── AppState (@MainActor @Observable — root state; every user action)
        ├── CacheCoordinator        ← SMALLGIT_CACHE_SPEC.md
        │     ├── MemoryCache (L1, LRU, 120 entries)
        │     ├── DiskCache (L2, ~/Library/Caches/SmallGit/<repo-hash>/)
        │     └── GitService (L3, through fetcher closures)
        │
        ├── InvalidationEngine      (pure enum: changed paths → keys,
        │                            GitAction → keys)
        ├── FileWatcherService      (FSEvents) → CacheCoordinator.onFileSystemChange
        │
        ├── GitService (actor, conforms to GitBackend)   ← SMALLGIT_SPEC.md
        │     ├── GitOutputParser, DiffPatchBuilder
        │     └── ProcessRunner (actor; spawns git — run + stream)
        │
        ├── ConfigService (actor)   → ~/Library/Application Support/SmallGit/
        │                             repositories.json, config.json, ui-state.json
        ├── PlatformServices (protocol) ← MacPlatformServices (AppKit)
        ├── OutputLog               (Output panel command journal)
        │
        ├── ViewModels (panel data read through CacheCoordinator)
        │     ├── RepositoryListViewModel, RepoTreeStore
        │     ├── BranchesViewModel
        │     ├── FilesViewModel
        │     ├── DiffViewModel
        │     ├── JournalViewModel (+ CommitGraphLayout, JournalDisplayRow)
        │     ├── TerminalViewModel
        │     ├── ConflictResolutionViewModel
        │     └── SubmoduleSession (Submodule window, its own CacheCoordinator)
        │
        └── Views                   ← SMALLGIT_SPEC.md (layout, panels)
              ├── MainWindow, ToolbarView, WelcomeView, PreferencesView
              ├── Sidebar / Content / Bottom panels
              ├── ContextMenus      ← SMALLGIT_CONTEXTMENUS_SPEC.md
              ├── Dialogs (sheets and tool windows)
              ├── LogWindow, SubmoduleLogWindow
              └── SyncFromSmartGitView → SmartGitImporter (actor, Yams)

Cross-cutting: Logging/ (Log, LogStore → ~/Library/Logs/SmallGit/smallgit.log),
Services/PerformanceSampler (status-bar perf badge), Syntax/ (compare views).
```

---

## Source Tree

Paths are relative to `SmallGit/` (the Swift package). 165 Swift files in
`Sources/SmallGit`, 135 in `Tests/SmallGitTests`, at the time of writing.

| Directory | What lives there | Notable files |
|-----------|------------------|---------------|
| `Sources/SmallGit/` | App entry point, scenes, menu commands | `SmallGitApp.swift` |
| `Models/` | Plain value types, mostly `Codable` + `Sendable` | `GitRepository`, `GitBranch`, `GitCommit`, `GitFileStatus`, `DiffHunk`, `AppConfig`, `RepoLayout` (where a repo / linked worktree keeps its metadata), `ConflictChunk`, `GitWorktree`, `GitSubmodule`, `RebaseTodo`, `SquashPlan`, `RewordPlan`, `WindowFrameState` |
| `Services/` | Git backend, subprocesses, persistence, platform bridge | `GitBackend` (protocol + shared vocabulary), `GitService` (actor, the only implementation), `ProcessRunner`, `GitOutputParser`, `DiffPatchBuilder`, `FileWatcherService`, `ConfigService`, `SmartGitImporter`, `PlatformServices` / `MacPlatformServices`, `GitCredentials`, `GitRemoteFailure`, `UserShellEnvironment`, `TerminalCompletion`, `PerformanceSampler` |
| `Cache/` | 3-layer cache and invalidation | `CacheKey`, `CacheEntry`, `MemoryCache`, `DiskCache`, `CacheCoordinator`, `InvalidationEngine` (also defines `GitAction`) |
| `ViewModels/` | `@Observable` state, `@MainActor` | `AppState` (root, owns everything above), one VM per panel (see graph), `OutputLog`, `CommitGraphLayout` |
| `Views/` | Top-level windows | `MainWindow`, `ToolbarView`, `WelcomeView`, `SyncFromSmartGitView`, `PreferencesView`, `LogWindow`, `SubmoduleLogWindow` |
| `Views/Sidebar/` | Repositories and Branches panels | `RepositoriesPanel`, `BranchesPanel`, `SubmoduleRow` |
| `Views/Content/` | Files, Diff and Terminal panels | `FilesTableView`, `DiffView`, `TerminalPanel` |
| `Views/Bottom/` | Journal and Output panels | `JournalView`, `OutputView`, `BottomPanelsBar` |
| `Views/ContextMenus/` | Right-click menus | `RepositoryContextMenu`, `RepoTreeContextMenu`, `SidebarSelectionContextMenu`, `BranchContextMenu`, `TagContextMenu`, `SubmoduleContextMenu`, `FileContextMenu`, `DiffContextMenu`, `JournalContextMenu` |
| `Views/Dialogs/` | Sheets and tool windows (~34) | `CommitDialog`, `NewBranchSheet`, `DeleteBranchSheet`, `InteractiveRebaseSheet`, `SquashCommitsSheet`, `RewordCommitSheet`, `StashesView`, `ConflictResolutionView`, `FileCompareView`, `FileHistoryView`, `BlameView`, `ReflogBrowserView`, `WorktreesView`, `SubmodulesView`, `CloneRepositorySheet`, `CredentialsSheet`, `DiagnosticsView` |
| `Views/Components/` | Shared building blocks | `PanelHeader`, `StatusBar`, `RefBadge`, `DiffLineView`, `ComparePanes`, `CommitGraphCell`, `FindBar`, `Theme`, `DiffColors`, `ModalWindowPresenter`, `MainWindowStateHandler` |
| `Syntax/` | Syntax highlighting and text search for compare views (hand-written language specs, no dependency) | `SyntaxHighlighter`, `SyntaxLanguage`, `CompareTextLayout`, `TextSearch` |
| `Logging/` | Size-capped diagnostic log and its summary / diagnosis | `Log`, `LogStore`, `LogSummary`, `LogDiagnosis` |
| `Utilities/` | Small helpers | `DateFormatters`, `StringExtensions`, `NaturalOrder` |
| `Sources/SmallGit/Resources/` | SwiftPM resource folder (currently empty) | — |
| `Resources/` (package root) | App icon | `AppIcon.icns` |
| `Tests/SmallGitTests/` | Unit tests (parsers, cache, patch math, layout) and `*IntegrationTests.swift` that run real `git` in temp repos | — |
| `scripts/` | Packaging and tooling | `build-app.sh` (release `.app`), `build-dmg.sh`, `xcode.sh` (generates `project.yml` / Xcode project), `generate-icon.sh`, `create-dev-cert.sh` |

Also at the package root: `Package.swift` (source of truth for `swift build`,
`swift test` and CI), `project.yml` + `SmallGit.xcodeproj` (mirror it for
Xcode), `Info.plist` (embedded into the executable and copied into the bundle).

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| macOS minimum | 14.0 (Sonoma) — `Package.swift` and `project.yml` | `@Observable`, modern `Table`, `Window` scenes |
| Toolchain | swift-tools-version 5.10; Apple silicon only in the Xcode project (`ARCHS: arm64`) | Matches `swift build`, which builds for the host arch |
| Git integration | `git` CLI via `Process`, behind the `GitBackend` protocol | Works with any installed git; the protocol leaves room for a libgit2 backend, though callers still hold the concrete `GitService` |
| State management | `@Observable` (Observation), `@MainActor` view models | No Combine boilerplate, SwiftUI-native |
| Concurrency | `async/await` + actors (`GitService`, `ProcessRunner`, `ConfigService`, `DiskCache`, `SmartGitImporter`); `StrictConcurrency` and `BareSlashRegexLiterals` upcoming features on | Thread-safe by construction |
| Cache persistence | JSON under `~/Library/Caches/SmallGit/<repo-hash>/` | Standard macOS cache dir, purgeable by the system |
| Config persistence | JSON under `~/Library/Application Support/SmallGit/` | Standard macOS persistent storage |
| External dependency | Yams (SPM, `from: 5.0.0`) — the only one, imported only by `SmartGitImporter` | SmartGit keeps its repository list in YAML |
| Platform calls | `PlatformServices` protocol, `MacPlatformServices` implementation (open panel, alerts, Finder / Terminal / editor, pasteboard) | Keeps `NSWorkspace` / `NSAlert` out of `AppState` |
| File watching | FSEvents via `CoreServices`, rooted at `RepoLayout.watchRoots` | Kernel-level and cheap; covers linked worktrees whose metadata sits outside the checkout |
| Diff rendering | Custom SwiftUI views; AppKit (`NSTextView` via `NSViewRepresentable`) where editing or large compare panes need it | `Table` doesn't support per-row backgrounds well enough |
| Syntax highlighting | Hand-written language specs in `Syntax/` | No JavaScriptCore-based dependency |
| Context menus | `.contextMenu { }` modifier | Native macOS feel |

---

## Handoff Instruction for Agent

> You are working on SmallGit, a native macOS SwiftUI git client for
> SmartGit-style workflows. The app is well past MVP: read the code first,
> and use the specs (`SMALLGIT_SPEC.md`, `SMALLGIT_CACHE_SPEC.md`,
> `SMALLGIT_CONTEXTMENUS_SPEC.md`) and `ARCHITECTURE.md` for intent. Where
> they disagree with the code, the code wins.
>
> - Panel data is read through `CacheCoordinator.get` / `forceRefresh`
>   with a `CacheKey`; don't add ad-hoc git reads for data a panel shows.
> - Git work goes through `GitService` (declared in `GitBackend`), which
>   runs `git` only via `ProcessRunner`. `GitService` imports no SwiftUI or
>   AppKit.
> - A mutating action runs in `AppState` (usually via `runGit`), records to
>   `OutputLog`, then calls `coordinator.after(GitAction)` so
>   `InvalidationEngine` drops the right keys, and refreshes the panels.
>   A new mutating operation adds or reuses a `GitAction` case — it
>   declares keys, not views to refresh.
> - AppKit calls from `AppState` go through `PlatformServices`; view-level
>   AppKit stays in `Views/`.
> - Keep strict concurrency clean: types crossing actors are `Sendable`.
>   No `try!`, no `fatalError`.
> - Target: macOS 14+, Swift 5.10, one SPM dependency (Yams).
> - After a code change, run the tests the change touches (`swift test`
>   in `SmallGit/`, filtered as needed) and build the release app with
>   `SmallGit/scripts/build-app.sh --release`. Hand off
>   `release/SmallGit.app` (stripped, no `.dSYM`), not a debug build.
>   Build a DMG only when asked. See `AGENTS.md` and `CONTRIBUTING.md`.
