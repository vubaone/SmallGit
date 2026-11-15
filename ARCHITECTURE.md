# SmallGit Architecture

A two-page tour of how SmallGit is built. For the deep-dive design docs see
[docs/architecture/](docs/architecture/). Where any of these documents and
the code disagree, the code wins.

## One picture

```
┌──────────────────────────────────────────────────────────────────────┐
│                          SwiftUI Views                               │
│   MainWindow · Sidebar · Files · Diff · Journal · Dialogs · …        │
│                                                                      │
│   • Mutations go through AppState, never straight to GitService.     │
│   • Views never spawn subprocesses.                                  │
│   • AppKit (NSTextView, NSTableView tweaks, open/save panels, …) is   │
│     used in Views/ where SwiftUI falls short.                        │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │ read state / call actions
                                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│                     ViewModels (@MainActor @Observable)              │
│   AppState · FilesVM · BranchesVM · DiffVM · JournalVM · …           │
│                                                                      │
│   • Hold UI state. Read panel data through CacheCoordinator.         │
│   • Run writes through GitService, then coordinator.after(action).   │
│   • Reach AppKit only through PlatformServices.                      │
└───────────────┬──────────────────────────────────────┬───────────────┘
                │ get(key) / forceRefresh(key)         │ writes, one-off reads
                ▼                                      │
┌─────────────────────────────────────────────────┐    │
│                CacheCoordinator                 │    │
│  ┌─────────────┐  miss  ┌─────────────┐  miss   │    │
│  │ MemoryCache │ ─────► │  DiskCache  │ ─────►  │    │
│  │ (L1, LRU)   │        │ (L2, ~/Lib/ │ fetcher │    │
│  └─────────────┘        │   Caches)   │ (L3)    │    │
│                         └─────────────┘    │    │    │
│  InvalidationEngine (pure mapping):        │    │    │
│   changed paths → keys, GitAction → keys   │    │    │
│        ▲                                   │    │    │
└────────┼───────────────────────────────────┼────┘    │
         │ onFileSystemChange(paths)         ▼         ▼
 FileWatcherService (FSEvents)      ┌──────────────────────────┐
 owned by AppState                  │ GitService (actor,       │
                                    │ conforms to GitBackend)  │
                                    └────────────┬─────────────┘
                                                 ▼
                                    ┌──────────────────────────┐
                                    │ ProcessRunner (actor)    │
                                    │ spawns git: run / stream │
                                    └──────────────────────────┘
```

## The five rules

1. **Panels read from the cache.** Panel data (status, branches, tags,
   stashes, log, diff) flows `View → ViewModel → CacheCoordinator.get(key)`
   (or `forceRefresh` after a change). The coordinator serves L1, falls
   back to L2 and refreshes in the background, or calls the fetcher (git)
   on a full miss. One-off detail reads — blame, file history, a commit's
   files, a stash's diff — go to `GitService` directly, mostly from
   `AppState`; a few views (`LogWindow`, `StashDiffView`, `FileCompareView`,
   `PushToSheet`) do the same through `appState.git`.
2. **Subprocesses live in one place.** Every `git` invocation is spawned by
   `ProcessRunner`, an actor: `run` for buffered results, `stream` for live
   output (the Terminal panel). The actor serializes its own state only —
   concurrent invocations run as independent processes. The one other
   `Process` spawn is `AppState` launching a configured external
   diff / merge tool.
3. **Invalidation is declared, not view-driven.** Two paths feed
   `InvalidationEngine`: a mutating op declares a `GitAction`
   (`coordinator.after(.commit)`) that maps to the stale keys, and
   `FileWatcherService` reports FSEvents paths that map the same way
   (`.git/index` → file status, `.git/refs/heads/*` → branches + log, …).
   After either, `AppState` reloads the panels; a batch that maps to no key
   (lock files, `COMMIT_EDITMSG`) triggers no refresh.
4. **AppKit stays out of the core.** `Services/` (except
   `MacPlatformServices`), `Cache/`, `Models/`, `Logging/`, `Syntax/` and
   `ViewModels/` have no `import AppKit`. `AppState` reaches the OS through
   the `PlatformServices` protocol (open panel, confirmations, Finder /
   Terminal / editor, pasteboard), implemented by `MacPlatformServices`.
   AppKit in the UI is confined to `Views/`. Three core files import
   SwiftUI for `Color` (`AppState`, `Models/GitFileStatus`,
   `Models/OutputEntry`).
5. **Strict concurrency is enabled.** New types crossing actor boundaries
   need `Sendable`. The package builds with `StrictConcurrency` and
   `BareSlashRegexLiterals` as upcoming features (mirrored in `project.yml`).

## Module map

| Path | Responsibility |
|------|----------------|
| `Sources/SmallGit/Models/` | Plain value types: `GitRepository`, `GitBranch`, `GitCommit`, `GitFileStatus`, `DiffHunk`, `OutputEntry`, `AppConfig`, `RepoLayout`, `ConflictChunk`, `LineDiff`, `GitWorktree`, `GitSubmodule`, `WindowFrameState` (+ `WindowPlacement`, the pure multi-display restore rules) |
| `Sources/SmallGit/Services/GitBackend.swift` | The contract: every git operation (~120), stated independently of how it runs, plus shared vocabulary (`GitCommandResult`, `InProgressOperation`, …). |
| `Sources/SmallGit/Services/GitService.swift` | Actor, the only `GitBackend` conformer: domain-typed facade over the `git` CLI (status v2, branches, log + history search, diff, commit + fixup, push, pull, merge, rebase + interactive / autosquash, stash, tags, blame, reflog, remotes, worktrees, submodules). |
| `Sources/SmallGit/Services/ProcessRunner.swift` | Actor wrapping `Process`; resolves the git binary and imports the user's login-shell environment (`UserShellEnvironment`). |
| `Sources/SmallGit/Services/GitOutputParser.swift` | Parses raw git output (porcelain v2 status, log, branch, etc.). |
| `Sources/SmallGit/Services/DiffPatchBuilder.swift` | Builds patches for hunk / line staging from in-memory `DiffHunk`s. |
| `Sources/SmallGit/Services/FileWatcherService.swift` | FSEvents wrapper over `RepoLayout.watchRoots`; hands batched paths to `CacheCoordinator.onFileSystemChange`. |
| `Sources/SmallGit/Services/PlatformServices.swift`, `MacPlatformServices.swift` | OS seam used by `AppState`, and its AppKit implementation. |
| `Sources/SmallGit/Services/SmartGitImporter.swift` | Reads SmartGit's YAML config (newest `~/Library/Preferences/SmartGit/<version>/`, via Yams) and seeds the repo list. |
| `Sources/SmallGit/Services/ConfigService.swift` | Actor; JSON read/write to `~/Library/Application Support/SmallGit/`. |
| `Sources/SmallGit/Cache/CacheCoordinator.swift` | Read-through coordinator: L1 → L2 → L3, stale-while-revalidate via `maxAge`. |
| `Sources/SmallGit/Cache/MemoryCache.swift` | In-process LRU cache, capped at 120 entries. |
| `Sources/SmallGit/Cache/DiskCache.swift` | Actor; JSON files under `~/Library/Caches/SmallGit/<repo-hash>/`. |
| `Sources/SmallGit/Cache/InvalidationEngine.swift` | Pure mapping: changed path → keys, `GitAction` → keys. |
| `Sources/SmallGit/ViewModels/` | `AppState` (root, runs every action) plus RepositoryList, RepoTree, Branches, Files, Diff, Journal, Terminal, ConflictResolution VMs, `SubmoduleSession`, and `OutputLog`. |
| `Sources/SmallGit/Views/` | SwiftUI views: panels, dialogs, context menus, toolbar, Log / Submodule windows, preferences. |
| `Sources/SmallGit/Syntax/`, `Logging/` | Syntax highlighting + find for compare views; the size-capped diagnostic log under `~/Library/Logs/SmallGit/`. |

## Adding a new feature — the checklist

When you add a feature that touches git:

1. **Model first.** If the feature reads new data, add the type under
   `Models/` and make it `Codable` + `Sendable`.
2. **Backend.** Declare the operation in `GitBackend` and implement it in
   `GitService` (and a parser in `GitOutputParser` if needed). Keep it pure
   git — no UI imports.
3. **Cache key.** If a panel will display the data, define a `CacheKey`
   for it and wire invalidation in `InvalidationEngine`: which paths and
   which `GitAction`s make it stale?
4. **View model.** Add a method to the relevant VM that calls
   `CacheCoordinator.get(key)` and exposes results via observable state.
   Mutations go in `AppState` (usually through `runGit`) and end with
   `coordinator.after(...)`.
5. **View.** Render. Use existing components (`PanelHeader`, `RefBadge`,
   `DiffLineView`, `ComparePanes`) before writing new ones.
6. **Tests.** Unit test the parser and patch math. Integration-test the
   end-to-end flow against a real `git` in a temp repo (see
   `Tests/SmallGitTests/*IntegrationTests.swift` for the pattern).

## Going deeper

- [`docs/architecture/SMALLGIT_SPEC.md`](docs/architecture/SMALLGIT_SPEC.md) — full spec: panels, layout, models, parsers, git backend.
- [`docs/architecture/SMALLGIT_CACHE_SPEC.md`](docs/architecture/SMALLGIT_CACHE_SPEC.md) — cache layering, invalidation policy, maxAge guidelines, performance budget.
- [`docs/architecture/SMALLGIT_CONTEXTMENUS_SPEC.md`](docs/architecture/SMALLGIT_CONTEXTMENUS_SPEC.md) — every right-click menu, mapped to git command, cache key, and keyboard shortcut.
- [`docs/architecture/SMALLGIT_INDEX.md`](docs/architecture/SMALLGIT_INDEX.md) — reading order, dependency graph and source-tree map.
