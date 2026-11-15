# SmallGit — 3-Layer Cache System Specification

> Reconciled with the code on 2026-09-28. The code is the source of truth; if this document and the code disagree, the code wins.

## Addendum to SMALLGIT_SPEC.md

All cache code lives in `SmallGit/Sources/SmallGit/Cache/`. The types named
below are the real ones; read the file when you need a signature.

---

## 1. Architecture Overview

### 1.1 The Problem

Without caching, a Git GUI spawns `git` processes on every interaction: a repo
switch needs `status`, `branch`, `branch -r`, `tag`, `symbolic-ref`, `log` and
`stash list`; clicking a file needs a `diff`; and reacting to every filesystem
event with a fresh `git status` keeps the CPU busy while the user is only
typing in their editor.

On a large repo (50k+ files), `git status` alone can take 1–2 seconds.
Multiplied by constant file watching, that makes a Git GUI feel sluggish and
battery-hungry. (These figures are design-time estimates for an uncached
client, not measurements of SmallGit.)

There is a second trap the design has to avoid: git writes into `.git/` while
answering read-only commands (`git status` refreshes the index). A watcher that
reacts to *every* `.git/` change with a refresh feeds its own writes back into
itself — an idle-I/O loop. SmallGit has hit that bug once; the invalidation
rules in §6 are what keep it from recurring.

### 1.2 The Solution: 3-Layer Cache

```
┌──────────────────────────────────────────────────────────────┐
│              UI (SwiftUI Views → view-model properties)       │
│     view-models read through CacheCoordinator, never git      │
├──────────────────────────────────────────────────────────────┤
│  Layer 1: MEMORY CACHE (L1) — MemoryCache                    │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  In-process, @MainActor, type-erased CacheEntry<T>     │  │
│  │  LRU-capped at 120 entries                             │  │
│  │  Lifetime: until repo switch / invalidation            │  │
│  └────────────────────────────────────────────────────────┘  │
│                          ↕ populate / write-through           │
│  Layer 2: DISK CACHE (L2) — DiskCache (actor)                │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  JSON files in ~/Library/Caches/SmallGit/<repo-hash>/  │  │
│  │  Lifetime: persistent across launches                  │  │
│  │  Written after every successful L3 fetch               │  │
│  └────────────────────────────────────────────────────────┘  │
│                          ↕ fetch / refresh                    │
│  Layer 3: REAL DATA (L3) — GitService + ProcessRunner        │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  git CLI commands, passed in as a `fetcher` closure    │  │
│  │  Called on a full miss, a stale entry, or forceRefresh │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

`CacheCoordinator` sits in front of all three and is the only thing
view-models talk to (§5).

### 1.3 Core Principle: Serve Cached, Invalidate Surgically, Refresh Deliberately

1. **Reads go through the coordinator** — `get` returns whatever it has (even
   stale) and refreshes in the background.
2. **FSEvents fire** — `InvalidationEngine` maps each changed path to the
   affected cache keys; paths no cache depends on map to nothing and trigger
   no refresh at all.
3. **User action** (commit, stage, pull, …) — the action is known, so
   `CacheCoordinator.after(_:)` invalidates exactly its key set, and the panels
   are re-read.
4. **Invalidation clears L1, not L2** (commit logs are the one exception,
   §5.3). Because a plain `get` would then fall through to the pre-change disk
   snapshot, the post-action and post-FSEvents refresh uses `forceRefresh` for
   the panels that must be exact (§7.2).
5. **Manual refresh** (⌘R, Repository → Refresh) — `AppState.refreshAllForced()`:
   `invalidateAll()`, then `refreshPanels()`, then force-reloads the on-screen
   diff.

---

## 2. Data Source Analysis

### 2.1 Cache Key Classification

| Cache key | Git command (in `GitService`) | Changes when | Invalidated by (FS) |
|-----------|-------------------------------|--------------|---------------------|
| `fileStatus` | `status --porcelain=v2 -z --untracked-files=all` (+ `--ignored=traditional` when showing ignored) | File saved, staged, index modified | Working-tree change, `.git/index`, `MERGE_HEAD`, `REBASE_HEAD` |
| `trackedFiles` | `ls-files -z` | Add / rm | `.git/index` |
| `assumeUnchangedFiles` | `ls-files -v -z` | `update-index --[no-]assume-unchanged` | `.git/index` |
| `currentBranch` | `symbolic-ref --short HEAD` | Checkout, rebase, reset | `.git/HEAD` |
| `branchList` | `branch --format=…` (includes upstream ahead/behind) | Branch create/delete/rename, tip moves, upstream moves | `refs/heads/*`, `refs/remotes/*`, `packed-refs` |
| `remoteBranches` | `branch -r --format=…` | Fetch, push, pull | `refs/remotes/*`, `packed-refs` |
| `tagList` | `tag --sort=-creatordate` | Tag create/delete | `refs/tags/*`, `packed-refs` |
| `stashList` | `stash list --format=%gd%x00%gs%x00%aI` | Stash save/apply/drop/rename | `refs/stash` |
| `log(refs:)` | `log --topo-order --format=… -n <count>` | Any ref moves (decorations are baked into rows) | `HEAD`, `refs/heads/*`, `refs/remotes/*`, `refs/tags/*`, `packed-refs` |
| `diff(file:mode:compact:)` | `diff [--cached] [--unified=<all>] -- <file>` | File saved, staged | Working-tree change to that file (index-vs-working-tree mode only) |
| `repoValidation(path:)` | — | — | Defined but currently unused: nothing reads or writes it |

### 2.2 FSEvents → Invalidation Map

We don't re-run everything on every file change. `InvalidationEngine.keysToInvalidate`
maps specific paths to specific keys (paths shown relative to the git dir;
`log` means `.log(refs: "__current__")`, which the coordinator widens to every
cached log — §5.3):

```
Changed path                    → Invalidated keys
─────────────────────────────────────────────────────────────────────
.git/HEAD                       → currentBranch, log
.git/index                      → fileStatus, trackedFiles, assumeUnchangedFiles
.git/refs/heads/*               → branchList, log
.git/refs/remotes/*             → remoteBranches, branchList, log
.git/refs/tags/*                → tagList, log
.git/refs/stash*                → stashList
.git/MERGE_HEAD, REBASE_HEAD    → fileStatus
.git/packed-refs                → branchList, remoteBranches, tagList, log
.git/<anything else>            → (nothing) — COMMIT_EDITMSG, config, ORIG_HEAD,
                                  FETCH_HEAD, index.lock, worktrees/<name>/, …
<working-tree file>             → fileStatus,
                                  diff(file, .indexVsWorkingTree, compact: true/false)
<work-tree root itself>         → fileStatus
```

Notes:

- `.git/index` does **not** invalidate diffs. Stage/unstage invalidates and
  purges diffs through the action path (§6.2), not the watcher.
- Remote-ref moves retire the log because `git log`'s `%D` bakes the
  `origin/<branch>` chip into the cached rows, and retire `branchList` because
  ahead/behind is measured against the upstream.
- `packed-refs` is treated as a ref change: `gc`, `pack-refs`, and fetch/push
  on a repo whose refs are packed move refs there instead of under `refs/`.
- **Working-tree changes do NOT invalidate branchList, log, tags, stash, or
  remoteBranches.**

**Linked worktrees and submodules.** The engine works on a `RepoLayout`
(`Models/RepoLayout.swift`: `workTree`, `gitDir`, `commonDir`). Paths under
`gitDir` or `commonDir` are restated as `.git/<rest>` before the rules above
apply. In a linked worktree, only `refs/` and `packed-refs` from the shared
`commonDir` count — `HEAD`, `index` and operation markers there belong to the
main checkout, so a sibling worktree staging a file maps to nothing here. The
`repoRoot:` overloads assume an ordinary `<root>/.git` layout via
`RepoLayout.assumed(workTree:)`.

---

## 3. Cache Key Design

### 3.1 CacheKey Enum

`Cache/CacheKey.swift` — `enum CacheKey: Hashable, Codable, Sendable`.

Cases: `fileStatus`, `trackedFiles`, `assumeUnchangedFiles`, `currentBranch`,
`branchList`, `remoteBranches`, `tagList`, `stashList`,
`log(refs: String)`, `diff(file: String, mode: DiffCompareMode, compact: Bool)`,
`repoValidation(path: String)`.

- Per-repo keys carry no repo path; the repo is implicit via
  `CacheCoordinator.activeRepoPath`.
- `log(refs:)` carries `JournalRefSelection.cacheToken`
  (`Models/JournalRefSelection.swift`): the sentinel
  `CacheKey.currentBranchSentinel` (`"__current__"`) for the default HEAD-only
  graph, `"__none__"` for an empty selection, or `"refs_<hash>"` for any wider
  selection of refs. Two selections never share an entry.
- `diff` is keyed per file, per `DiffCompareMode` (`.headVsIndex`,
  `.indexVsWorkingTree`, in `Models/DiffHunk.swift`), and per compact
  (limited context) vs. full-file (`--unified=<all>`) view — four entries per
  file.
- `isLog` is `true` for any `.log` case; `logDiskFilePrefix` is `"log_"`.
- `diskFileName` gives the L2 filename: `file_status.json`,
  `tracked_files.json`, `assume_unchanged_files.json`, `current_branch.json`,
  `branch_list.json`, `remote_branches.json`, `tag_list.json`,
  `stash_list.json`, `log_<refs>.json`, `diff_<mode>_<c|full>_<file>.json`,
  `repo_<hash>.json`.

Filename helpers live in `Utilities/StringExtensions.swift`:
`safeFileName` replaces every character outside alphanumerics and `._-` with
`_` and truncates to 80 characters; `stableHash` is a 64-bit FNV-1a hash
rendered in hex (used for per-repo directory names and ref-selection tokens).

### 3.2 CacheEntry Wrapper

`Cache/CacheEntry.swift` — `struct CacheEntry<T: Codable & Sendable>: Codable, Sendable`
with `value`, `timestamp` (defaults to now) and `gitRef: String?` (HEAD SHA from
`git rev-parse HEAD` at fetch time), plus a computed `age`. `gitRef` is
recorded but nothing currently compares it — staleness is decided by `age`
and invalidation only.

---

## 4. Layer Implementations

### 4.1 Layer 1 — Memory Cache

`Cache/MemoryCache.swift` — `@MainActor final class MemoryCache` (not
`@Observable`; observation happens on the coordinator and the view-models).

- Storage is a type-erased `[CacheKey: any AnyMemoryEntry]`.
- **LRU cap:** `init(maxEntries: Int = 120)`. `get` and `setEntry` touch the
  key; when the count exceeds the cap, the least-recently-used entries are
  evicted. The cap exists because `diff` keys accumulate one per file per mode
  while browsing; it counts entries, not bytes.
- API: `get(_:as:)`, `set(_:value:gitRef:)`, `setEntry(_:entry:)`,
  `invalidate(_ key)`, `invalidate(_ keys: Set)`, `invalidateLogs()` (drops
  every `.log` entry regardless of selection), `invalidateAll()`, `has`, `age`,
  `keys`, `count`.

Covered by `CacheEvictionTests` (cap, LRU order, reads protect entries,
overwrite doesn't consume capacity, invalidation frees capacity).

### 4.2 Layer 2 — Disk Cache

`Cache/DiskCache.swift` — `actor DiskCache`, with a `static let shared`.

- Location: `~/Library/Caches/SmallGit/<repoPath.stableHash>/<key.diskFileName>`
  (falls back to `~/Library/Caches` under the home directory if the system
  lookup fails). Being under Caches, macOS may purge it.
- JSON with ISO-8601 dates; writes are `.atomic`.
- API: `load(key:repoPath:as:)`, `save(key:repoPath:entry:)`,
  `remove(key:repoPath:)`, `removeLogs(repoPath:)` (deletes every `log_*`
  file for the repo), `removeAll(repoPath:)`, `evictStale(maxAge:)`.
- Every operation is recorded in the diagnostics log (`Logging/Log.swift`,
  `Log.disk`): `cache.hit`, `cache.miss`, `cache.corrupt`, `cache.save`,
  `cache.remove`, `cache.removeLogs`, `cache.removeAll`, `cache.evictStale`.
  Hits and misses are separate operation names so the hit rate reads straight
  off the log summary.
- `evictStale(maxAge:)` (default 7 days, by directory modification date)
  exists but **is not called anywhere** — there is currently no automatic
  eviction of old repo directories beyond what macOS does to Caches.

### 4.3 Layer 3 — Real Data (Git)

Layer 3 is `GitService` + `ProcessRunner` (`Services/`). The cache never calls
git on its own behalf except `currentHeadSHA` for `CacheEntry.gitRef`; every
read passes a `fetcher: @Sendable (String) async throws -> T` closure that
receives the repo path.

---

## 5. CacheCoordinator — The Brain

`Cache/CacheCoordinator.swift` — `@MainActor @Observable final class CacheCoordinator`.
One instance, owned by `AppState` and shared by every panel view-model.
Dependencies are injectable: `init(memoryCache:diskCache:gitService:)`
(defaults `MemoryCache()`, `DiskCache.shared`, `GitService.shared`).

### 5.1 Reads

- **`get(_:as:maxAge:fetcher:) async -> T?`** — the read-through accessor:
  1. **L1 hit** → return it; if `maxAge` is given and exceeded, schedule a
     background refresh.
  2. **L2 hit** → copy the entry into L1, return it, and *always* schedule a
     background refresh (the disk entry may be from a previous session).
  3. **Full miss** → fetch from L3 (awaited), write L1 and L2, return.
- **`forceRefresh(_:as:fetcher:) async -> T?`** — bypass both caches, fetch,
  write L1 and L2 (the L2 write is fire-and-forget).
- Both return `nil` when there is no active repo or the fetcher throws.
- Background refreshes are de-duplicated per key (`inFlight`).

### 5.2 Background refresh → panels (`onBackgroundRefresh`)

When a background refresh lands *after* `get` already handed out the stale
value, the coordinator calls `onBackgroundRefresh(key)` — but only if the
active repo is still the one it was fetched for. `AppState` wires this to
`adoptBackgroundRefresh(of:)`, which re-reads the affected panel from cache
(no extra git): `.log` → journal, `.fileStatus` → files, `.branchList`/
`.remoteBranches`/`.tagList`/`.currentBranch` → branches, `.stashList` →
stash list, `.diff` → the diff pane only if it is the diff on screen, and so
on. Without this hook, the fresh value would sit in L1 with nobody reading it.

### 5.3 Invalidation API

- **`invalidate(_ keys: Set<CacheKey>)`** — drops the keys from L1 only; L2
  stays as a fallback and is overwritten on the next fetch. **Exception:** if
  the set contains any `.log` key, *every* cached log is dropped from L1
  (`invalidateLogs`) *and* from L2 (`removeLogs`). A log key carries a hash of
  its ref selection, so the ref that moved can't be mapped back to the entries
  it affects — and a stale disk log would be served the moment the user ticks
  that selection.
- **`invalidate(_ key: CacheKey)`** — single-key L1 drop.
- **`invalidateAll()`** — clears L1.
- **`purge(_ keys:) async`** — drops keys from L1 **and** L2. Used when a disk
  snapshot must not be served at all: after stage/unstage for the diff modes
  not on screen (`DiffViewModel.reloadAfterStaging`), and after
  assume-unchanged.
- **`purgeDiskCache(forRepoPath:) async`** — wipes a repo's whole L2 directory
  (used by the init-repo flow).
- **`after(_ action: GitAction)`** — `invalidate(InvalidationEngine.keysAfter(action))`.
- **`onFileSystemChange(paths:layout:) -> Bool`** — ignores batches for a repo
  that is no longer active; maps the paths via the engine, invalidates, and
  returns `true` only if at least one key was affected.

### 5.4 Repo context

`switchRepo(to: String?)` sets `activeRepoPath` and clears L1 (no-op if the
path is unchanged). L2 is per-repo on disk and is left alone. Passing `nil`
(unavailable repo) makes every read return `nil`.

---

## 6. Invalidation Engine

`Cache/InvalidationEngine.swift` — a caseless `enum InvalidationEngine` with
pure static functions. It is the single source of truth for
"what changed → what's now stale".

### 6.1 FSEvents → Cache Invalidation

- `keysToInvalidate(changedPath:layout:)` / `(changedPath:repoRoot:)` — one
  path → keys, per the table in §2.2.
- `keysToInvalidate(changedPaths:layout:)` / `(changedPaths:repoRoot:)` — a
  batch, unioned into one deduplicated set.

### 6.2 Action → Cache Invalidation

`keysAfter(_ action: GitAction) -> Set<CacheKey>`. `GitAction` is defined in
the same file. `log` below means `.log(refs: "__current__")`, which retires
every cached log (§5.3); "all diff modes" means both `DiffCompareMode`s ×
compact/full for each file.

| GitAction | Invalidated keys |
|-----------|------------------|
| `.stage(files:)`, `.unstage(files:)` | `fileStatus`, all diff modes for each file |
| `.discard(files:)` | `fileStatus`, `diff(.indexVsWorkingTree)` compact + full for each file |
| `.assumeUnchanged(files:)` | `fileStatus`, `assumeUnchangedFiles`, all diff modes for each file |
| `.commit` | `fileStatus`, `log`, `branchList`, `stashList` |
| `.pull` | `fileStatus`, `log`, `branchList`, `remoteBranches`, `tagList` |
| `.push` | `remoteBranches`, `branchList`, `log` |
| `.fetch` | `remoteBranches`, `branchList`, `tagList`, `log` |
| `.checkout` | `currentBranch`, `fileStatus`, `trackedFiles`, `assumeUnchangedFiles`, `branchList`, `log` |
| `.merge` | `fileStatus`, `log`, `branchList` |
| `.rebase` | `fileStatus`, `log`, `currentBranch`, `branchList` |
| `.reset` | `fileStatus`, `log`, `currentBranch`, `branchList` |
| `.stashSave`, `.stashApply`, `.stashDrop` | `stashList`, `fileStatus` |
| `.branchCreate`, `.branchDelete`, `.branchRename` | `branchList`, `log` |
| `.tagChange` | `tagList`, `log` |

There is no separate stash-rename action: `AppState.stashRename` calls
`after(.stashDrop)` (on success and on failure), since only the list changed.
The assume-unchanged path calls `keysAfter(.assumeUnchanged(files:))` directly
and `purge`s the result (minus `fileStatus`, which `runGit` has just re-read).

`GitAction.everyKind` lists one instance of each of the 19 kinds. It is
hand-written because the cases carry associated values (no `CaseIterable`).

### 6.3 Invariants the tests enforce

`Tests/SmallGitTests/InvalidationInvariantTests.swift` asserts these over
every action and every watched ref path, so a new action or rule can't
silently break them:

1. **A ref that moves retires the log.** Every ref-moving action (`commit`,
   `pull`, `push`, `fetch`, `checkout`, `merge`, `rebase`, `reset`,
   `branchCreate`/`Delete`/`Rename`, `tagChange`) includes a `.log` key.
   Conversely, ref-neutral actions (`stage`, `unstage`, `discard`,
   `assumeUnchanged`, `stashSave`/`Apply`/`Drop`) must **not** retire the log.
2. **Upstream distance is measured, not stored.** Every action that changes
   where a branch stands relative to its upstream (`commit`, `push`, `pull`,
   `fetch`, `merge`, `rebase`, `reset`, `checkout`, `branchCreate`/`Delete`/
   `Rename`) includes `.branchList`.
3. **Tripwire:** `GitAction.everyKind.count == 19`; adding an action without
   listing it fails.
4. **No action invalidates nothing.**
5. **Every ref path retires the log:** `HEAD`, `refs/heads/*`,
   `refs/remotes/*`, `refs/tags/*`, `packed-refs`.
6. **Each ref namespace retires its own list** (heads → `branchList`,
   remotes → `remoteBranches` + `branchList`, tags → `tagList`, stash →
   `stashList`, `HEAD` → `currentBranch`, `index` → `fileStatus`).
7. **Git internals map to nothing:** `COMMIT_EDITMSG`, `config`, `ORIG_HEAD`,
   `FETCH_HEAD`, `index.lock`.

`CacheTests.swift` covers individual mappings, disk filenames (every log file
carries the `log_` prefix) and `removeLogs` dropping every selection and
nothing else.

---

## 7. ViewModel Integration Pattern

### 7.1 Rule

View-models (`FilesViewModel`, `BranchesViewModel`, `JournalViewModel`,
`DiffViewModel`, plus `AppState` for the stash list) receive the shared
`CacheCoordinator` and a `GitService` in their initializers, and read only
through `coordinator.get` / `coordinator.forceRefresh`, passing a fetcher that
calls `GitService`. They never call git directly for cached data.

Most expose two entry points:

- **`load()`** — `get` with the key's `maxAge` (§10): cheap, may return stale
  data and refresh in the background.
- **`forceRefresh()`** — `forceRefresh`: exact, always runs git.

`BranchesViewModel` reads its four keys (`branchList`, `remoteBranches`,
`currentBranch`, `tagList`) concurrently with `async let`. `JournalViewModel`
keys the log by the current `JournalRefSelection.cacheToken` and fetches
`max(pageSize, loaded count)` commits (`pageSize` = 100). `FilesViewModel`
loads `trackedFiles` only when a filter needs it and `assumeUnchangedFiles`
only when that view is switched on.

### 7.2 Why refreshes after changes use `forceRefresh`

Invalidation clears L1 but leaves L2 (logs aside). A plain `load()` right
after an action would therefore fall through to the pre-change disk snapshot
and only schedule a background refresh. So `AppState.refreshPanels()` — run
after every action by `runGit`, after a relevant FSEvents batch, and on repo
switch — calls:

- `filesVM.forceRefresh()` and `journalVM.forceRefresh()` (always exact),
- branches via `load()` by default, or `forceRefresh()` when the caller passes
  `forceBranches: true` (branch-mutating actions),
- the stash list via `get(.stashList, maxAge: 30)`,
- plus the in-progress-operation and submodule probes (submodules are not
  cached at all).

Anything served stale by the `load()` paths is corrected by the background
refresh plus `onBackgroundRefresh` (§5.2).

---

## 8. App Launch and Repo Switch

### 8.1 Sequence

`MainWindow` calls `AppState.bootstrap()`:

1. Load app config, repository list and UI state; probe repository
   availability.
2. Apply persisted preferences (diagnostics logging, git path, diff mode, …).
3. Select the last-opened repo (or the first one) via `selectRepo(_:)`.
4. Fire-and-forget: refresh the branch label of every repo in the sidebar.

`selectRepo(_:)`:

1. Re-check availability; an unavailable repo gets `switchRepo(to: nil)`, the
   watcher is stopped, and the panels show an empty state.
2. `coordinator.switchRepo(to: path)` — clears L1.
3. Clear per-repo panel state (diff, selection, journal commits, branch
   lists, …) so the previous repo doesn't flash through.
4. Resolve `git.layout(repoPath:)` and start the file watcher on
   `layout.watchRoots` (§9).
5. Persist it as last-opened.
6. `refreshPanels()` (§7.2).

### 8.2 What the user sees first

Because `refreshPanels()` force-refreshes file status and the journal, those
two panels come from git, not from L2, even on launch. The branch list,
remote branches, tags, current branch and stash list are served from L2 when
a disk entry exists and are then refreshed in the background. The design-time
goal of "every panel shows last-session data within a few milliseconds" is
therefore only met for those panels; nothing measures launch-to-data time.

---

## 9. FSEvents Integration with Cache

`Services/FileWatcherService.swift` — `final class FileWatcherService: @unchecked Sendable`,
owned by `AppState`.

- One FSEvents stream at a time, over `RepoLayout.watchRoots` (the work tree,
  plus the git and common dirs when they live outside it — linked worktrees,
  submodules).
- Flags: `UseCFTypes | FileEvents | NoDefer | WatchRoot`. Runs on its own
  serial dispatch queue.
- **Coalescing:** there is no separate debounce timer. FSEvents' own latency
  (`init(latency: 0.4)`, i.e. 400 ms) batches events; each batch is delivered
  as `[String]` absolute paths.
- Each batch is logged as `fsevents.batch` — a steady stream of them while the
  app is idle is the signature of a self-feeding loop.

`AppState.startWatching(layout:)` wires it up. For every batch, on the main
actor:

1. `coordinator.onFileSystemChange(paths:layout:)` maps and invalidates.
2. If it returned `true` **and** the active repo hasn't changed meanwhile,
   `refreshPanels()` runs. Batches that map to no key (lock files,
   `COMMIT_EDITMSG`, …) cause no refresh and no git process.

Note the refresh is panel-wide, not per-key: the precision is in *whether* to
refresh and in which L1 entries are dropped, while `refreshPanels()` decides
what actually re-runs git (§7.2).

---

## 10. MaxAge Values

The `maxAge` values passed to `get` in the code today:

| Cache key | maxAge | Where |
|-----------|--------|-------|
| `fileStatus` | 5 s | `FilesViewModel.load` |
| `trackedFiles` | 60 s | `FilesViewModel` |
| `assumeUnchangedFiles` | 30 s | `FilesViewModel.loadAssumeUnchanged` |
| `currentBranch` | 10 s | `BranchesViewModel` |
| `branchList` | 30 s | `BranchesViewModel` |
| `remoteBranches` | 60 s | `BranchesViewModel` |
| `tagList` | 300 s | `BranchesViewModel` |
| `stashList` | 30 s | `AppState.refreshStashList` |
| `log(refs:)` | 10 s | `JournalViewModel` |
| `diff(...)` | 2 s | `DiffViewModel` |
| `repoValidation` | — | unused |

These are "consider stale" thresholds, NOT expiration. Stale data is still
returned immediately — it just triggers a background refresh. `maxAge` only
matters for L1 hits; an L2 hit always triggers a refresh, and `forceRefresh`
ignores it.

---

## 11. Performance Targets

These are design targets. Nothing in the code or tests measures or enforces
them. To observe the real numbers, use the diagnostics log (`Logging/`:
`cache.hit` / `cache.miss` timings, `fsevents.batch` rate) and
`Services/PerformanceSampler.swift` (process CPU, memory footprint, disk I/O).

| Metric | Target |
|--------|--------|
| Idle CPU (no user action, no external changes) | < 1% |
| Git processes per minute while idle | ~0 (no FSEvents batch → no git) |
| Disk cache per repo | < 2 MB |

Memory is bounded by entry count (L1 cap of 120, §4.1), not by bytes. Disk
usage is unbounded in principle: `evictStale` is not wired up (§4.2), so old
repo directories remain until macOS purges Caches.

---

## 12. Edge Cases

### 12.1 External Git Operations

User runs `git commit` in Terminal (outside SmallGit):
- FSEvents reports `.git/refs/heads/<branch>` and `.git/index`; reflog writes
  under `.git/logs/` map to nothing.
- `InvalidationEngine` maps it to `branchList` + log; the coordinator retires
  every cached log from L1 and L2.
- `refreshPanels()` re-reads the journal and files with git; the branch list
  is re-read (stale L2 first, corrected by the background refresh).
- The UI updates after the ~400 ms FSEvents latency plus git time.

### 12.2 Large Repo (100k+ files)

`git status` can take seconds. File status is force-refreshed on repo switch
and after every change batch, so a slow `status` is felt there; the cache
mainly saves the reads that don't change (branches, tags, stash, diffs,
tracked files). `trackedFiles` and `assumeUnchangedFiles` are loaded only on
demand for this reason. (The design idea of an initial
`--untracked-files=no` scan is not implemented; the status call always uses
`--untracked-files=all`.)

### 12.3 Network Operations (Pull/Push/Fetch)

The cache doesn't speed up the operation itself, but:
- BEFORE: panels keep showing their current data.
- DURING: the command and its result are recorded in the Output panel.
- AFTER: `after(.pull / .push / .fetch)` invalidates precisely (including the
  log, because remote-tracking chips moved), then `refreshPanels()`.

### 12.4 App Crash Recovery

L2 survives crashes (writes are atomic). On next launch, disk entries are
served where `get` is used and refreshed in the background.

### 12.5 Cache Corruption

If a disk file fails to decode, `DiskCache.load` logs `cache.corrupt` to the
diagnostics log and returns `nil`. It does **not** delete the file; the
coordinator falls through to L3, and the successful fetch overwrites it.

### 12.6 Repo switch mid-flight

A background refresh that completes after the user switched repos still
writes its result, but `onBackgroundRefresh` is not called. FSEvents batches
for a repo that is no longer active are dropped by `onFileSystemChange`
(it compares `layout.workTree` with `activeRepoPath`), so they trigger no
refresh.

---

## 13. Project Structure

```
SmallGit/Sources/SmallGit/
├── Cache/
│   ├── CacheKey.swift              // CacheKey enum + diskFileName, isLog
│   ├── CacheEntry.swift            // CacheEntry<T> wrapper
│   ├── MemoryCache.swift           // Layer 1: @MainActor LRU store (cap 120)
│   ├── DiskCache.swift             // Layer 2: JSON files actor
│   ├── CacheCoordinator.swift      // Layer orchestrator (L1→L2→L3)
│   └── InvalidationEngine.swift    // FS path / GitAction → CacheKey; GitAction enum
├── Models/RepoLayout.swift         // workTree / gitDir / commonDir, watchRoots
├── Models/JournalRefSelection.swift// cacheToken for log keys
├── Services/FileWatcherService.swift // FSEvents stream
└── Utilities/StringExtensions.swift  // safeFileName, stableHash

SmallGit/Tests/SmallGitTests/
├── CacheTests.swift
├── CacheEvictionTests.swift
├── InvalidationInvariantTests.swift
└── FileWatcherServiceTests.swift
```

---

## 14. Summary

The 3-layer cache is what lets SmallGit stay quiet while idle: git runs only
when a watched path that some cache depends on changes, when the user acts, or
when a stale entry is read — never on a timer and never on git's own internal
bookkeeping. The invariant tests in §6.3 are the guardrail that keeps "what an
action changed" and "what the panels show" in step.
