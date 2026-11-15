# SmallGit — Context Menus Specification

> Reconciled with the code on 2026-09-28. The code is the source of truth; if this document and the code disagree, the code wins.

## Addendum to SMALLGIT_SPEC.md

---

## 1. Overview

Every interactive panel has a right-click menu (`.contextMenu` in SwiftUI). Most live as their own view in `SmallGit/Sources/SmallGit/Views/ContextMenus/`; a few small ones are written inline in the view that owns the rows. Each menu item maps to an `AppState` method (and through it to a git command or a system action), and may carry a displayed keyboard shortcut, an enabled/disabled condition, and a cache invalidation.

| Panel / surface | Menu type | Defined in | Attached in |
|---|---|---|---|
| Repositories — repository row | `RepositoryContextMenu` | `Views/ContextMenus/RepositoryContextMenu.swift` | `Views/Sidebar/RepositoriesPanel.swift` (grouped and flat rows) |
| Repositories — group header | inline | `Views/Sidebar/RepositoriesPanel.swift` (`groupHeader`) | same |
| Repositories — repository tree (files/folders) | `RepoTreeContextMenu` | `Views/ContextMenus/RepoTreeContextMenu.swift` | `Views/Sidebar/RepositoriesPanel.swift` |
| Branches — local / remote branch | `BranchContextMenu` | `Views/ContextMenus/BranchContextMenu.swift` | `Views/Sidebar/BranchesPanel.swift` (`menu(for:)`) |
| Branches — HEAD row | inline | `Views/Sidebar/BranchesPanel.swift` (`menu(for:)`) | same |
| Branches — tag | `TagContextMenu` | `Views/ContextMenus/TagContextMenu.swift` | `Views/Sidebar/BranchesPanel.swift` |
| Branches — stash | `StashContextMenu` (private) | `Views/Sidebar/BranchesPanel.swift` | same |
| Branches — submodule | `SubmoduleContextMenu` | `Views/ContextMenus/SubmoduleContextMenu.swift` | `Views/Sidebar/BranchesPanel.swift`, `Views/Dialogs/SubmodulesView.swift` |
| Branches — folder, or several rows | `SidebarSelectionContextMenu` | `Views/ContextMenus/SidebarSelectionContextMenu.swift` | `Views/Sidebar/BranchesPanel.swift` |
| Files panel | `FileContextMenu` | `Views/ContextMenus/FileContextMenu.swift` | `Views/Content/FilesTableView.swift` |
| Diff panel | `DiffContextMenu` (+ `DiffRowCopyMenu`) | `Views/ContextMenus/DiffContextMenu.swift`, `Views/Components/DiffCopy.swift` | `Views/Content/DiffView.swift` (unified and both side-by-side columns) |
| Journal (main window and Log window) | `JournalContextMenu` | `Views/ContextMenus/JournalContextMenu.swift` | `Views/Bottom/JournalView.swift` |
| Log window — Files pane | inline `fileContextMenu` | `Views/LogWindow.swift` | same |
| Stash window, File History, compare windows | inline | see §7 | — |

### Convention Used in This Spec

```
[Menu Item Label]          ⌘X        ← keyboard shortcut displayed on the item (if any)
  action: ...                         ← AppState method (or system action) the item calls
  git command: ...                    ← CLI command(s) the method ends up running
  invalidates: ...                    ← GitAction passed to coordinator.after(...), or direct invalidate
  shown when: ...                     ← item is omitted from the menu otherwise
  enabled when: ...                   ← item is drawn but disabled otherwise
  confirms: ...                       ← asks before running
  dialog: ...                         ← sheet/window opened before executing
  notes: ...
```

### Mechanics common to every git action

- Git-running `AppState` methods go through the private `runGit(action:…)` helper. On success it calls the method's `onSuccess` (normally `coordinator.after(<GitAction>)`) and then `refreshPanels(forceBranches:)`, so every successful action refreshes the panels even when it names no cache key. Several history-changing actions (pull, merge, rebase, cherry-pick, revert, squash, reword, autosquash, interactive rebase) also call `coordinator.invalidateAll()` when git fails, since a failed run may have left the repository half-changed.
- `GitAction` → cache keys is defined in one place, `InvalidationEngine.keysAfter(_:)` in `Cache/InvalidationEngine.swift`; see §9.
- Copy items all go through `appState.copyToPasteboard(_:)`, which also puts "Copied: …" on the status line.
- "Open" goes through `appState.openInFinder(path:)` (`NSWorkspace.open`, i.e. the default app); "Reveal in Finder" through `revealInFinder(path:)`; "Open in Terminal" through `openInTerminal(path:)` (Terminal.app); "Open in Editor" through `openInEditor(path:)`, which uses the editor picked in Preferences ▸ General (`appConfig.externalEditor`, or a custom app path) and falls back to the system default opener.

---

## 2. Repositories Panel

### 2.1 Repository row

**Trigger:** Right-click a repository row (grouped or flat layout).
**Type:** `RepositoryContextMenu(repo:appState:)`.

Most git items are only enabled for the **active** repository (`appState.activeRepo?.id == repo.id`); right-clicking another repository does not switch to it, except for Log.

```
┌──────────────────────────────────────────┐
│  Init Git Here              (see below)   │
├──────────────────────────────────────────┤
│  Open Repository                          │
├──────────────────────────────────────────┤
│  Open                            ▸       │
│    Reveal in Finder                       │
│    Open in Terminal                       │
│    Open in Editor                         │
│  Close Repository                         │
├──────────────────────────────────────────┤
│  Commit…                         ⌘K      │
│  Pull (Merge)                             │
│  Pull (Rebase)                            │
│  Push                                     │
│  Synchronize                     ⌘Y      │
├──────────────────────────────────────────┤
│  Log                             ⌘L      │
│  Refresh                                  │
│  Browse Reflog…                           │
│  Worktrees…                               │
│  Clean Up…                                │
│  Move To                         ▸       │
│  Mark as Favorite / Unmark Favorite       │
│  Rename…                         ↩       │
├──────────────────────────────────────────┤
│  Remove…                                  │
├──────────────────────────────────────────┤
│  Copy Path                                │
├──────────────────────────────────────────┤
│  Settings…                                │
└──────────────────────────────────────────┘
```

```
[Init Git Here]
  shown when: appState.availability(for: repo) == .notRepository (the folder is not a git repo)
  action: appState.initRepositoryInPlace(repo)
  git command: git init --initial-branch=main <path>
  notes: Checks the folder is now its own repository root (not an enclosing repo), purges the
         cache for the path, then selects the repo. Followed by a divider.

[Open Repository]
  action: appState.selectRepo(repo)
  git command: none directly (repo switch reloads every panel)

[Open ▸ Reveal in Finder]   action: appState.revealInFinder(path: repo.path)
[Open ▸ Open in Terminal]   action: appState.openInTerminal(path: repo.path)
[Open ▸ Open in Editor]     action: appState.openInEditor(path: repo.path)
  notes: A folder goes to the configured editor; with "System Default" it goes to the first
         installed editor from AppConfig's folder-editor list rather than to Finder.

[Close Repository]
  action: appState.closeActiveRepo()
  enabled when: repo is the active repository
  notes: Clears the active repo and panel state; the entry stays in the sidebar.

[Commit…]                                                      ⌘K
  action: appState.showCommitDialog = true   → CommitDialog sheet
  enabled when: repo is the active repository

[Pull (Merge)]
  action: appState.pull(rebase: false)
  git command: git pull --autostash
  invalidates: .pull  (invalidateAll on failure)
  enabled when: repo is the active repository

[Pull (Rebase)]
  action: appState.pull(rebase: true)
  git command: git pull --rebase --autostash
  invalidates: .pull  (invalidateAll on failure)
  enabled when: repo is the active repository

[Push]
  action: appState.push()
  git command: git push
    → if git reports no upstream: git push --set-upstream <preferred remote> <current branch>
  invalidates: .push
  enabled when: repo is the active repository

[Synchronize]                                                  ⌘Y
  action: appState.sync()
  git command: git pull --rebase --autostash, then git push
  invalidates: .pull, then .push
  enabled when: repo is the active repository
  notes: Stops before pushing if the pull failed, left an operation in progress, or left
         conflicted files (e.g. an autostash that would not reapply).

[Log]                                                          ⌘L
  action: selects the clicked repo first if it is not active, then openWindow(id: "log")
  enabled when: the repository is available on disk (availability.isAvailable)

[Refresh]
  action: appState.refreshAllForced()
  invalidates: coordinator.invalidateAll(), then refreshPanels() and diffVM.reloadIfLive()
  enabled when: repo is the active repository

[Browse Reflog…]
  action: appState.showReflogSheet = true   → ReflogBrowserView sheet
  enabled when: repo is the active repository

[Worktrees…]
  action: appState.showWorktreesSheet = true   → WorktreesView sheet
  enabled when: repo is the active repository

[Clean Up…]
  action: appState.cleanUpRepository()
  git command: git remote prune <remote> (each remote), git worktree prune, git gc --prune=now
  invalidates: coordinator.invalidateAll() after gc
  enabled when: repo is the active repository
  confirms: yes — "Clean up repository?"; reports object-database size before → after

[Move To ▸]
  Submenu:
    [Group ‘<name>’]  one per group     → appState.moveRepository(repo, toGroup: name)
                      disabled for the group the repo is already in
    [No Group]                          → appState.moveRepository(repo, toGroup: nil)
                      disabled when the repo is already ungrouped
    ──
    [New Group…]                        → pendingMoveRepoId = repo.id; AddGroupSheet
  git command: none (repositories config)

[Mark as Favorite] / [Unmark Favorite]
  action: appState.toggleFavorite(repo)
  notes: Label follows repo.isFavorite.

[Rename…]                                                      ↩ (Return)
  action: appState.pendingRepoRename = RepoRenameTarget(...)   → RenameRepositorySheet
  notes: Alias only — changes the sidebar label, not the folder name.

[Remove…]
  action: appState.removeRepository(repo)   → RepositoryRemovalSheet
  notes: The sheet offers removing the entry from the list, or moving the folder to the
         Trash (RepositoryRemovalChoice .removeFromList / .moveFolderToTrash / .cancel).

[Copy Path]
  action: appState.copyToPasteboard(repo.path)

[Settings…]
  action: appState.pendingRepoSettings = repo   → RepositorySettingsSheet
```

### 2.2 Group header

**Trigger:** Right-click a group header ("Other" is the unnamed catch-all).
**Type:** inline in `RepositoriesPanel.groupHeader(...)`.

```
┌──────────────────────────────────────────┐
│  Add Existing Folder…                     │
│  Clone…                                   │
├──────────────────────────────────────────┤  ← named groups only
│  Rename Group…                            │
├──────────────────────────────────────────┤
│  Delete Group                 (destructive)│
└──────────────────────────────────────────┘
```

```
[Add Existing Folder…]  action: appState.presentOpenRepository(targetGroup: <group>)
[Clone…]                action: pendingCloneGroup = <group>; showCloneSheet = true → CloneRepositorySheet
[Rename Group…]         shown when: named group; action: pendingGroupRename → RenameGroupSheet
[Delete Group]          shown when: named group; action: pendingGroupDelete → confirmation alert
                        "Delete group "<name>"?" in MainWindow
```

---

## 3. Branches Panel

### 3.1 How the panel picks a menu

The Branches panel attaches **one** menu to the whole list, `.contextMenu(forSelectionType: SidebarSelection.self)`, rather than one per row. SwiftUI hands it the rows the click applies to — the selection when the click landed inside it, otherwise just the clicked row. `BranchesPanel.menu(for:)` then routes:

| Items the click applies to | Menu |
|---|---|
| one `.head` | inline Add to Graph / Remove from Graph (§3.3) |
| one `.branch` | `BranchContextMenu` (§3.2) |
| one `.tag` | `TagContextMenu` (§3.4) |
| one `.stash` | `StashContextMenu` (§3.5) |
| one `.submodule` | `SubmoduleContextMenu` (§3.6) |
| one `.folder` | `SidebarSelectionContextMenu` (§3.7) |
| two or more of anything | `SidebarSelectionContextMenu` (§3.7) |

### 3.2 Branch (local or remote)

**Type:** `BranchContextMenu(branch:appState:)`. "Current" means `branch.name == branchesVM.currentBranch`.

```
┌──────────────────────────────────────────┐
│  Check Out…                               │
│  Fast-Forward to <upstream>  (see below)  │
├──────────────────────────────────────────┤
│  Merge…                                   │
│  Rebase…                                  │
│  Rebase Interactively onto Here…          │
├──────────────────────────────────────────┤
│  Push                                     │
│  Push To…                                 │
├──────────────────────────────────────────┤
│  Log                                      │
├──────────────────────────────────────────┤
│  Reset Current Branch To Here    ▸       │
│    Soft / Mixed / Hard                    │
├──────────────────────────────────────────┤
│  New Branch from Here…                    │
│  Rename…                                  │
│  Delete… / Delete from Remote…            │
├──────────────────────────────────────────┤
│  Set Tracked Branch…                      │
│  Stop Tracking                            │
├──────────────────────────────────────────┤
│  Copy Name                                │
└──────────────────────────────────────────┘
```

```
[Check Out…]
  action: appState.checkout(branch: name, offerFastForward: true)
  git command: git checkout <name>
    → remote branch <remote>/<b>: git checkout <b> if that local branch exists,
      otherwise git checkout --track <remote>/<b>
  invalidates: .branchCreate and .checkout
  enabled when: branch is not current
  confirms: when a local branch is behind its upstream (and has no commits of its own, or only
            holds an old state of a rewritten upstream), a prompt offers
            check out and fast-forward / check out only / cancel
            (platform.resolveBehindCheckout). The fast-forward runs before the checkout.
  notes: Double-clicking a local branch does the same. Checking out something that leaves HEAD
         detached is reported on the status line.

[Fast-Forward to <upstream>]
  shown when: local branch with an upstream (label shows the upstream, e.g. "origin/main")
  enabled when: branch is not current AND not checked out in another worktree
                (branch.worktreePath == nil) AND the upstream is not gone
  action: appState.fastForwardToUpstream(branch: name)
  git command: git fetch <remote> <merge>:refs/heads/<branch>
    → retried as git fetch <remote> +<merge>:refs/heads/<branch> only when refused as
      non-fast-forward AND the branch holds nothing but a former upstream state
  invalidates: .fetch
  notes: Moves THIS branch without leaving the current one (e.g. bring main up to origin/main
         before rebasing onto it). The current branch uses Pull for this.

[Merge…]
  action: appState.merge(branch: name)
  git command: git merge --autostash <name>
  invalidates: .merge  (invalidateAll on failure)
  enabled when: branch is not current
  notes: Runs straight away — no dialog despite the ellipsis. Conflicts surface through the
         in-progress operation banner.

[Rebase…]
  action: appState.rebase(onto: name)
  git command: git rebase --autostash <name>
    → or git rebase --autostash --onto <name> <fork-point>
  invalidates: .rebase  (invalidateAll on failure)
  enabled when: branch is not current
  confirms: only when <name> was rewritten after HEAD branched from it: a prompt names the stale
            commits and offers replaying only your own commits (--onto), all of them, or cancel.

[Rebase Interactively onto Here…]
  action: appState.startInteractiveRebase(onto: name)
  dialog: InteractiveRebaseSheet (pick / squash / fixup / drop per commit)
  git command: git rebase -i --autostash <name>, todo supplied through GIT_SEQUENCE_EDITOR
               (runInteractiveRebase)
  invalidates: .rebase  (invalidateAll on failure)
  enabled when: branch is not current

[Push]
  action: appState.push()   (same as the repository menu's Push)
  enabled when: branch is current AND local
  notes: Pushes the current branch, which is the only branch it is enabled for.

[Push To…]
  action: appState.branchPendingPushTo = branch   → PushToSheet
  git command: git push [--set-upstream] [--force-with-lease] <remote> <branch>[:<remoteBranch>]
               (appState.pushTo(localBranch:remote:remoteBranch:force:setUpstream:))
  invalidates: .push
  enabled when: branch is local

[Log]
  action: appState.journalVM.setBranchFilter(name)
  notes: Sets the Journal's ref selection to this branch only (HEAD unticked).

[Reset Current Branch To Here ▸ Soft | Mixed | Hard]
  action: appState.resetCurrent(to: name, mode: .soft | .mixed | .hard)
  git command: git reset --soft|--mixed|--hard <name>
  invalidates: .reset
  confirms: Hard only — "Hard reset current branch?"

[New Branch from Here…]
  action: appState.branchPendingNewFrom = branch   → NewBranchSheet(initialFrom: name)
  git command: git checkout -b <new> <name>   (or git branch <new> <name> without checkout)
  invalidates: .branchCreate (+ .checkout when checking out)

[Rename…]
  action: appState.branchPendingRename = branch   → RenameBranchSheet
  git command: git branch -m <old> <new>
  invalidates: .branchRename (+ .currentBranch when renaming the checked-out branch)
  enabled when: branch is local

[Delete…]                         (local branch)
[Delete from Remote…]             (remote branch — label changes)
  action: appState.requestBranchDeletion(branch)
  enabled when: branch is not current
  local:  dialog: DeleteBranchSheet (built from a merged/contained check per branch)
          git command: git branch -d <name>; the sheet offers git branch -D for branches git
                       refuses as not fully merged
          invalidates: .branchDelete
  remote: confirms: alert "Delete <b> from <remote>?" saying how many commits would stop being
                    reachable there
          git command: git push <remote> --delete <b>
          invalidates: .branchDelete

[Set Tracked Branch…]
  action: appState.branchPendingSetUpstream = branch   → SetTrackedBranchSheet
  git command: git branch --set-upstream-to=<upstream> <branch>
  invalidates: coordinator.invalidate(.branchList)
  enabled when: branch is local

[Stop Tracking]
  action: appState.unsetUpstream(branch: name)
  git command: git branch --unset-upstream <branch>
  invalidates: coordinator.invalidate(.branchList)
  enabled when: branch is local AND has an upstream
  confirms: no

[Copy Name]
  action: appState.copyToPasteboard(branch.name)
```

### 3.3 HEAD row

A single item, labelled from the Journal's current ref selection:

```
[Add to Graph] / [Remove from Graph]
  action: appState.setJournalHeadSelected(!refSelection.head)
  notes: Toggles HEAD in the Journal graph; persisted with the ref selection. No git command.
```

### 3.4 Tag

**Type:** `TagContextMenu(tag:appState:)`.

```
┌──────────────────────────────────────────┐
│  Push Tag                                 │
│  Delete…                                  │
├──────────────────────────────────────────┤
│  Copy Name                                │
└──────────────────────────────────────────┘
```

```
[Push Tag]
  action: appState.pushTag(tag)
  git command: git push <first configured remote, else "origin"> refs/tags/<tag>
  invalidates: none named (panels refresh via runGit)

[Delete…]
  action: appState.deleteTag(tag)
  git command: git tag -d <tag>
  invalidates: .tagChange
  confirms: yes — "Delete tag <tag>?" (local only; the remote copy is left alone)

[Copy Name]
  action: appState.copyToPasteboard(tag)
```

### 3.5 Stash

**Type:** `StashContextMenu` (private, in `Views/Sidebar/BranchesPanel.swift`). Mirrors the common operations of the Browse Stashes window.

```
┌──────────────────────────────────────────┐
│  Show Diff                                │
├──────────────────────────────────────────┤
│  Apply                                    │
│  Pop                        (stash@{0})   │
├──────────────────────────────────────────┤
│  Rename…                                  │
│  Drop…                      (destructive) │
├──────────────────────────────────────────┤
│  Browse Stashes…                          │
└──────────────────────────────────────────┘
```

```
[Show Diff]
  action: appState.showStashDiff(index:)  → stash files-and-diff window
          (CompareWindowPresenter.presentStash)
  notes: Double-clicking a stash row does the same.

[Apply]
  action: appState.stashApply(index:), then appState.refreshPanels()
  git command: git stash apply stash@{n}
  invalidates: .stashApply

[Pop]
  shown when: stash.index == 0
  action: appState.stashPop()
  git command: git stash pop
  invalidates: .stashApply

[Rename…]
  action: appState.stashPendingRename = stash   → RenameStashSheet
  git command: git has no rename — GitService.stashRename drops and re-stores the entries from
               stash@{0} down to stash@{n} with the new message, keeping the order
  invalidates: .stashDrop (on success and on failure)

[Drop…]
  action: appState.pendingStashDrop = [index]   → confirmation alert in MainWindow
  git command: git stash drop stash@{n}
  invalidates: .stashDrop
  confirms: yes (StashDropConfirmation title/message)

[Browse Stashes…]
  action: appState.showStashesSheet = true   → Stashes window
```

### 3.6 Submodule

**Type:** `SubmoduleContextMenu(submodule:appState:)`. Used for a submodule row in the Branches panel and for a row in the Submodules window (`SubmodulesView`, whose double-click is Open as Repository).

```
┌──────────────────────────────────────────┐
│  Update / Initialize and Clone            │
│  Open as Repository                       │
├──────────────────────────────────────────┤
│  Sync URLs from .gitmodules               │
│  Remove Working Tree…       (destructive) │
├──────────────────────────────────────────┤
│  Reveal in Finder                         │
│  Copy Path                                │
│  Copy URL                   (if known)    │
└──────────────────────────────────────────┘
```

```
[Update] / [Initialize and Clone]   (label: "Initialize and Clone" when uninitialized)
  action: appState.updateSubmodules(paths: [path])
  git command: git submodule update --init --recursive -- <path>
  invalidates: coordinator.invalidateAll()

[Open as Repository]
  action: appState.openSubmoduleAsRepository(submodule)  → adds it to the sidebar
  enabled when: submodule.isCloned

[Sync URLs from .gitmodules]
  action: appState.syncSubmodules()
  git command: git submodule sync --recursive
  invalidates: none named (submodule list re-read)

[Remove Working Tree…]
  action: appState.deinitSubmodule(submodule)
  git command: git submodule deinit [--force] -- <path>   (--force when it has local work)
  invalidates: coordinator.invalidateAll()
  enabled when: submodule.isCloned
  confirms: only when the submodule is modified — "Discard changes in <name>?"

[Reveal in Finder]   enabled when: submodule.isCloned
[Copy Path]          copies the submodule's path relative to the repository
[Copy URL]           shown when: the submodule has a URL
```

### 3.7 Folder or multi-row selection

**Type:** `SidebarSelectionContextMenu(items:appState:)`. Shown for a single folder row (standing for every branch under it) and for any selection of two or more rows. Only actions that still mean something done many times over are offered.

The first section is titled with what the batch covers, e.g. "3 branches, 1 tag selected" (or "N rows selected" when none of those apply).

**Selection containing only stashes:**

```
┌──────────────────────────────────────────┐
│  N stashes selected                       │
│  Drop N Stashes…            (destructive) │
└──────────────────────────────────────────┘
```

**Any other selection:**

```
┌──────────────────────────────────────────┐
│  <N branches, M tags, K stashes> selected │
│  Add to Graph                             │
│  Remove from Graph                        │
├──────────────────────────────────────────┤
│  Delete Branch… / Delete N Branches…      │
│  Drop N Stashes…            (if stashes)  │
├──────────────────────────────────────────┤
│  Copy Names                               │
└──────────────────────────────────────────┘
```

```
[Add to Graph] / [Remove from Graph]
  action: appState.setJournalRefs(<branch + tag names>, checked: true|false),
          plus appState.setJournalHeadSelected(...) when HEAD is in the selection
  enabled when: the selection covers at least one branch or tag, or includes HEAD

[Delete Branch…] / [Delete N Branches…]   ("Delete Branches…" when there is nothing to delete)
  action: appState.requestBranchDeletion(deletable)  → DeleteBranchSheet
  git command: git branch -d <name>, one invocation per branch (-D offered for unmerged ones)
  invalidates: .branchDelete per deleted branch
  enabled when: at least one local, non-current branch is covered
  notes: Remote branches and the checked-out branch are silently left out.

[Drop…] / [Drop N Stashes…]
  shown when: the selection includes stashes (label from StashDropConfirmation.buttonLabel)
  action: appState.pendingStashDrop = <indices>  → confirmation alert listing the stashes
  git command: git stash drop stash@{n}, highest index first; stops at the first failure
  invalidates: .stashDrop per drop

[Copy Names]
  action: copies branch and tag names, one per line
  enabled when: the selection covers at least one branch or tag
```

---

## 4. Files Panel

**Trigger:** Right-click a row in the Files table.
**Type:** `FileContextMenu(files:appState:)`. `files` is the table selection when the clicked row is part of it, otherwise just the clicked row (`FilesTableView.contextFiles(focused:)`). Items marked *(first)* act on the first file of that list only.

```
┌──────────────────────────────────────────┐
│  Log                                      │
│  Compare…                        ⇧⌘D     │  one of these three
│  Compare N Files…                ⇧⌘D     │
│  Resolve Conflict…               ⇧⌘R     │
│  Blame…                                   │
├──────────────────────────────────────────┤
│  Open                                     │
│  Reveal in Finder                         │
│  Open in Editor                           │
├──────────────────────────────────────────┤
│  Stage                           ⌘↩      │
│  Unstage                         ⌘⌫      │
│  Stash Selected…                          │
├──────────────────────────────────────────┤
│  Discard…                                 │
│  Delete Untracked…          (if untracked)│
│  Ignore                                   │
│  Create Patch…                            │
├──────────────────────────────────────────┤
│  Assume Unchanged / Stop Assuming Unchanged│
├──────────────────────────────────────────┤
│  Remove                          ▸       │
│    From Index Only (keep file)            │
│    From Index and Disk                    │
├──────────────────────────────────────────┤
│  Copy Name                                │
│  Copy Path                                │
│  Copy Relative Path                       │
└──────────────────────────────────────────┘
```

The first two groups (Log … Open in Editor) and the Copy group are only built when there is a file and an active repository.

```
[Log]                                                          (first)
  action: appState.fileHistoryTarget = .init(path:)  → File History window (FileHistoryView)

[Compare…]                                                     ⇧⌘D   (single, non-conflicted)
  action: appState.openCompareOrMerge(path:, isConflict: false)
  notes: Configured external diff tool first, built-in compare window otherwise.

[Compare N Files…]                                             ⇧⌘D   (multi-selection)
  action: appState.openCompares(paths:)  → one tabbed compare window
  enabled when: no selected file is a submodule

[Resolve Conflict…]                                            ⇧⌘R   (single, conflicted)
  action: appState.openCompareOrMerge(path:, isConflict: true)
  notes: Configured external merge tool first, built-in conflict resolver otherwise.

[Blame…]                                                       (first)
  shown when: file is not untracked
  action: appState.blameTarget = .init(path:)  → BlameView sheet

[Open]               (first)  action: appState.openInFinder(path:)   — default application
[Reveal in Finder]   (first)  action: appState.revealInFinder(path:)
[Open in Editor]     (first)  action: appState.openInEditor(path:)

[Stage]                                                        ⌘↩
  action: appState.stage(files: stagePaths)   (renames expanded to both paths)
  git command: git add -- <paths>
  invalidates: .stage(files:)
  confirms: only if a file still contains conflict markers

[Unstage]                                                      ⌘⌫
  action: appState.unstage(files: unstagePaths)   (conflicted files excluded)
  git command: git reset HEAD -- <paths>
  invalidates: .unstage(files:)
  enabled when: at least one selected file is not conflicted

[Stash Selected…]
  action: appState.pendingStashScope = (paths, includesUntracked); showStashSaveDialog = true
  dialog: StashMessageSheet
  git command: git stash push [--include-untracked] [--keep-index] [-m <msg>] -- <paths>
  invalidates: .stashSave

[Discard…]
  action: appState.confirmDiscard = true  → "Discard changes?" alert in MainWindow
          → appState.discard(plan: filesVM.selectedDiscardPlan)
  git command: tracked:    git checkout -- <paths>
               conflicted: git checkout HEAD -- <paths>
               untracked/ignored: git clean -f -d -- <paths>
  invalidates: .discard(files:)
  confirms: yes — message names each kind of file
  notes: The plan is built from the Files table selection (filesVM.selectedFileIDs).

[Delete Untracked…]
  shown when: the selection contains untracked files
  action: appState.discardUntracked(paths: <untracked>)
  git command: git clean -f -d -- <paths>
  invalidates: .discard(files:)
  confirms: yes — "Delete untracked file(s)?"

[Ignore]
  action: appState.addToGitignore(patterns: <paths>)
  git command: none — appends each selected path to <repo>/.gitignore
  invalidates: coordinator.invalidate(.fileStatus)
  confirms: no

[Create Patch…]
  action: appState.patchSource = .files(paths:, suggestedName:)  → CreatePatchSheet
  git command: git diff HEAD --binary --no-color -- <tracked>;
               git diff --no-index --binary --no-color -- /dev/null <untracked>

[Assume Unchanged] / [Stop Assuming Unchanged]
  action: appState.setAssumeUnchanged(files:, on:)
  git command: git update-index --assume-unchanged | --no-assume-unchanged -- <paths>
  invalidates: .assumeUnchanged(files:)  (purged from L1 and L2)
  enabled when: every selected file has an index entry and none is conflicted
  notes: "Stop …" is offered only when every selected file is already flagged.

[Remove ▸ From Index Only (keep file)]
  action: appState.removeFiles(files:, deleteFromDisk: false)
  git command: git rm --cached -- <path>, per tracked file
  invalidates: .stage(files: [path]) per file
  enabled when: at least one selected file is in the index
  confirms: yes — "Remove file(s) from Git?"

[Remove ▸ From Index and Disk]
  action: appState.removeFiles(files:, deleteFromDisk: true)
  git command: git rm -- <path> per tracked file; git clean -f -d [-x] -- <paths> for files
               with no index entry
  invalidates: .stage(files: [path]) per tracked file; .discard(files:) for the rest
  confirms: yes — "Delete file(s) from disk?"

[Copy Name]            (first)  file name
[Copy Path]            (first)  absolute path
[Copy Relative Path]   (first)  path relative to the repository root
```

---

## 5. Diff Panel

**Trigger:** Right-click a line in the Diff panel (unified layout, or either side of side-by-side).
**Type:** `DiffContextMenu(line:hunk:source:appState:viewModel:)`.

Which block is shown depends on the diff source: a HEAD-vs-Index diff (`source.staged`) gets the unstage items, anything else the stage/discard items. Line and hunk items are only enabled when the source is a single file's working-tree/index diff (`source.isStageable && source.file != nil`); for stash, commit, conflict, untracked and submodule diffs they are drawn disabled. "Selection" items appear only when more than one +/- line is selected.

**Working-tree (unstaged) diff:**

```
┌──────────────────────────────────────────┐
│  Stage Inner-line Change    (disabled)    │
│  Stage Line                               │
│  Stage Selection (N)        (if selected) │
│  Stage Hunk                               │
├──────────────────────────────────────────┤
│  Discard Line                             │
│  Discard Selection (N)      (if selected) │
│  Discard Hunk                             │
├──────────────────────────────────────────┤
│  Copy Selection (N lines)   (if selected) │
├──────────────────────────────────────────┤
│  Copy Line                                │
│  Edit in Index Editor       (disabled)    │
└──────────────────────────────────────────┘
```

**Staged (HEAD-vs-Index) diff:**

```
┌──────────────────────────────────────────┐
│  Unstage Line                             │
│  Unstage Selection (N)      (if selected) │
│  Unstage Hunk                             │
├──────────────────────────────────────────┤
│  Copy Selection (N lines)   (if selected) │
├──────────────────────────────────────────┤
│  Copy Line                                │
│  Edit in Index Editor       (disabled)    │
└──────────────────────────────────────────┘
```

All line/hunk actions build a patch with `DiffPatchBuilder` and pipe it to `git apply --whitespace=nowarn … -`. None of them asks for confirmation, including the discards.

```
[Stage Inner-line Change]
  Shown disabled — not implemented. (Help text "Not yet implemented"; kept for parity with
  SmartGit's menu layout.)

[Stage Line]
  action: appState.stageLine(line, in: hunk, file:)
  git command: git apply --whitespace=nowarn --cached -
  invalidates: .stage(files: [file])
  enabled when: clicked line is + or − AND the source is stageable

[Stage Selection (N)]
  action: appState.stageLines(ids, in: hunks, file:)
  git command: git apply --whitespace=nowarn --cached -
  invalidates: .stage(files: [file])

[Stage Hunk]
  action: appState.stageHunk(hunk, file:)
  git command: git apply --whitespace=nowarn --cached -
  invalidates: .stage(files: [file])
  enabled when: the line belongs to a hunk AND the source is stageable

[Discard Line] / [Discard Selection (N)] / [Discard Hunk]
  action: appState.discardLine / discardLines / discardHunk
  git command: git apply --whitespace=nowarn --reverse -   (against the working tree)
  invalidates: .discard(files: [file])
  enabled when: as for the matching Stage item

[Unstage Line] / [Unstage Selection (N)] / [Unstage Hunk]
  action: appState.unstageLine / unstageLines / unstageHunk
  git command: git apply --whitespace=nowarn --cached --reverse -
  invalidates: .unstage(files: [file])
  enabled when: as for the matching Stage item

[Copy Selection (N lines)]   (DiffRowCopyMenu)
  shown when: more than one row is selected
  action: copies the selected rows' text, in display order

[Copy Line]                  (DiffRowCopyMenu)
  action: copies line.content (no +/- prefix, no line numbers)
  enabled when: there is a line and it is not an empty filler row

[Edit in Index Editor]
  Shown disabled — not implemented. (Would call appState.notImplemented("Index Editor").)
```

Double-clicking a diff line is a separate path (`DiffView.activateLine`) and is not part of the menu.

---

## 6. Journal Panel

**Trigger:** Right-click a commit row in the Journal. The Log window embeds the same `JournalView`, so the menu is identical there.
**Type:** `JournalContextMenu(commit:appState:)`. Several items depend on `JournalViewModel` checks run against the loaded graph.

```
┌──────────────────────────────────────────┐
│  Log                             ⌘L      │
├──────────────────────────────────────────┤  ← multi-selection only
│  Squash N Commits…   or a disabled reason │
├──────────────────────────────────────────┤  ← when canChangeMessage
│  Change Message…                          │
├──────────────────────────────────────────┤
│  Cherry-Pick                              │
│  Revert                                   │
├──────────────────────────────────────────┤  ← when canFixup
│  Commit Staged as Fixup of <short>        │
│  Autosquash Fixups from Here              │
├──────────────────────────────────────────┤
│  Reset Current Branch To Here    ▸       │
│    Soft / Mixed / Hard                    │
├──────────────────────────────────────────┤
│  Create Patch…                            │
├──────────────────────────────────────────┤
│  Add Tag Here…                            │
│  Rebase Interactive From Here…            │  one of these three
│  Rebase Interactive Onto Here…            │
│  (disabled reason)                        │
├──────────────────────────────────────────┤
│  Use Message for Commit                   │
│  Copy ID                                  │
└──────────────────────────────────────────┘
```

```
[Log]                                                          ⌘L
  action: journalVM.selectedCommitID = commit.id; openWindow(id: "log")
  notes: Opens the Log window focused on this commit. Double-clicking a row does the same.

[Squash N Commits…]
  shown when: journalVM.squashAvailability(rightClicked:) == .ready(range) — two or more
              commits selected, the clicked row among them (or inside their span)
  action: appState.prepareSquash(range)  → SquashCommitsSheet → performSquash
  git command: git rebase -i --autostash <onto> with a generated todo and an
               `exec git commit --amend --file=… [--author=…] [--date=…]` step
  invalidates: .rebase  (invalidateAll on failure)
  notes: When the selection cannot be squashed the slot is a disabled row stating why:
           "Squash — not while search results are shown"
           "Squash — select an unbroken run of commits"
           "Squash — a merge commit can't be folded in"
           "Squash — the selection isn't one run of history"
           "Squash — these commits aren't on HEAD"
         Published commits are not a blocker; the sheet warns instead.

[Change Message…]
  shown when: journalVM.canChangeMessage(of:) — no git-backed search results showing, and the
              commit is on HEAD's history (HEAD-only graph) or is an unpushed HEAD commit
              (wider graph)
  action: appState.prepareReword(commit)  → RewordCommitSheet → performReword
  git command: git rebase -i --autostash <onto> with an `exec git commit --amend --file=…`
               after the commit (GIT_SEQUENCE_EDITOR)
  invalidates: .rebase  (invalidateAll on failure)

[Cherry-Pick]
  action: appState.cherryPick(hash)
  git command: git cherry-pick <hash>
  invalidates: .commit  (invalidateAll on failure)
  confirms: no

[Revert]
  action: appState.revertCommit(hash)
  git command: git revert <hash>
  invalidates: .commit  (invalidateAll on failure)
  confirms: no

[Commit Staged as Fixup of <short>]
  shown when: journalVM.canFixup(commit) — HEAD-only graph, no search results, commit on
              HEAD's history
  action: appState.commitFixup(of: hash)
  git command: git commit --fixup=<hash>
  invalidates: .commit

[Autosquash Fixups from Here]
  shown when: as above
  action: appState.autosquashFixups(from: commit)
  git command: git rebase -i --autosquash --autostash <hash>^   (--root for a root commit)
  invalidates: .rebase  (invalidateAll on failure)

[Reset Current Branch To Here ▸ Soft | Mixed | Hard]
  action: appState.resetCurrent(to: hash, mode:)
  git command: git reset --soft|--mixed|--hard <hash>
  invalidates: .reset
  confirms: Hard only — "Hard reset current branch?"

[Create Patch…]
  action: appState.patchSource = .commit(hash:, subject:)  → CreatePatchSheet
  git command: git format-patch -1 --stdout <hash>

[Add Tag Here…]
  action: appState.pendingTagTarget = TagTarget(hash:, subject:)  → AddTagSheet
  git command: git tag <name> <hash>   or   git tag -a <name> -m <message> <hash>
  invalidates: .tagChange

[Rebase Interactive From Here…]
  shown when: interactiveRebaseAvailability(from:) == .fromHere — commit is on HEAD's history
  action: appState.startInteractiveRebase(onto: hash, display: shortHash)
  dialog: InteractiveRebaseSheet
  git command: git rebase -i --autostash <hash>, todo via GIT_SEQUENCE_EDITOR
  invalidates: .rebase  (invalidateAll on failure)
  notes: Keeps this commit as the base and replays everything after it.

[Rebase Interactive Onto Here…]
  shown when: interactiveRebaseAvailability(from:) == .onto — commit is not on HEAD's history
  action: appState.startInteractiveRebase(onto: hash, display: <branch label or short hash>)
  dialog / git command / invalidates: as above
  notes: Takes this commit as the base and replays HEAD's commits since the two lines
         diverged on top of it.

  When neither applies the slot is a disabled row stating why:
    "Rebase Interactive — not while search results are shown"
    "Rebase Interactive — nothing comes after this commit"
    "Rebase Interactive — merge <short> would be flattened"

[Use Message for Commit]
  action: appState.copyToPasteboard(commit.subject)
  notes: Copies the subject line only; it does not open the Commit dialog.

[Copy ID]
  action: appState.copyToPasteboard(commit.hash)   — full SHA
```

---

## 7. Other Menus

### 7.1 Repository tree (sidebar file/folder tree)

**Type:** `RepoTreeContextMenu(node:appState:onRefresh:)`. Deliberately short — no git operations, since the tree has no staging state.

```
[Open]                  appState.openInFinder(path:)  — folder in Finder, file in its default app
[Reveal in Finder]      appState.revealInFinder(path:)
──
[Open in Editor]        appState.openInEditor(path:)
[Open in Terminal]      shown when: node is a directory
──
[Copy Path]             absolute path
[Copy Relative Path]    shown when: the node is inside the active repository
──
[Refresh] / [Refresh Folder]   re-reads the directory (a file's menu refreshes its parent folder)
```

### 7.2 Log window — Files pane

**Type:** inline `fileContextMenu(_:)` in `Views/LogWindow.swift`, for the files of the selected commit.

```
[Compare…]              external diff tool for this commit vs. its first parent, else the
                        built-in commit compare window
──
[Log]                   File History window
[Blame]                 BlameView sheet; disabled for a deleted file
──                      (following items only when the repository path is known)
[Open]                  disabled for a deleted file
[Reveal in Finder]
[Open in Editor]        disabled for a deleted file
──
[Copy Name] [Copy Path] [Copy Relative Path]
```

### 7.3 Smaller read-only menus

| Surface | File | Items |
|---|---|---|
| Stash window — file row | `Views/Dialogs/StashDiffView.swift` (`fileMenu`) | Compare… · Copy Name · Copy Relative Path |
| File History — commit row | `Views/Dialogs/FileHistoryView.swift` | Compare This Version… (also the double-click) · Copy Hash · Copy Subject |
| Read-only diff rows (compare windows) | `Views/Components/DiffCopy.swift` (`DiffRowCopyMenu`) | Copy Selection (N lines) · Copy Line |
| Built-in compare window — row | `Views/Dialogs/FileCompareView.swift` (`rowCopyMenu`) | Copy Selection (N lines) · Copy HEAD Line · Copy WORKING Line · Copy Both Sides; when the working side is editable: Copy Section from HEAD / Copy N Sections from HEAD, Edit This Section, Discard Section Edit; then Inspect Line |

---

## 8. Keyboard Shortcuts Shown in Context Menus

These are the only `.keyboardShortcut` modifiers inside context menus. The right-hand column lists the binding of the same key elsewhere in the app (menu bar in `SmallGitApp.swift`, toolbar in `Views/ToolbarView.swift`), where one exists.

| Menu | Item | Shortcut | Same key bound elsewhere |
|---|---|---|---|
| Repository | Commit… | ⌘K | Toolbar Commit (⌘K) |
| Repository | Synchronize | ⌘Y | Toolbar Sync (⌘Y) |
| Repository | Log | ⌘L | Repository ▸ Log (⌘L) |
| Repository | Rename… | ↩ | — |
| Files | Compare… / Compare N Files… | ⇧⌘D | — |
| Files | Resolve Conflict… | ⇧⌘R | — |
| Files | Stage | ⌘↩ | Toolbar Stage (⌘↩, Files selection) |
| Files | Unstage | ⌘⌫ | Toolbar Unstage (⌘⌫, Files selection) |
| Journal | Log | ⌘L | Repository ▸ Log (⌘L) |

Menu items that have a global shortcut but show none in the context menu:

| Context-menu item | Global binding |
|---|---|
| Refresh (repository menu) | Repository ▸ Refresh, ⌘R |
| Close Repository | Repository ▸ Close Repository, ⇧⌘W |
| Browse Reflog… | Repository ▸ Browse Reflog…, ⇧⌘G |
| Worktrees… | Repository ▸ Worktrees…, ⇧⌘T |
| Browse Stashes… (stash menu) | Repository ▸ Browse Stashes…, ⇧⌘S |
| New Branch from Here… (branch menu) | Repository ▸ New Branch…, ⇧⌘B (from HEAD) |
| Push (repository / branch menu) | Toolbar Push menu, ⇧⌘K |

---

## 9. Cache Invalidation Summary

### 9.1 Keys per `GitAction` (`InvalidationEngine.keysAfter`)

"log" is `.log(refs: CacheKey.currentBranchSentinel)`; the coordinator treats any log key as "retire every cached log". "diff (all)" means every `DiffCompareMode`, compact and full, for the affected paths; "diff (WT)" means only `.indexVsWorkingTree`.

| GitAction | fileStatus | trackedFiles | assumeUnchangedFiles | currentBranch | branchList | remoteBranches | tagList | stashList | log | diff |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `.stage`, `.unstage` | ✓ | | | | | | | | | all |
| `.discard` | ✓ | | | | | | | | | WT |
| `.assumeUnchanged` | ✓ | | ✓ | | | | | | | all |
| `.commit` | ✓ | | | | ✓ | | | ✓ | ✓ | |
| `.pull` | ✓ | | | | ✓ | ✓ | ✓ | | ✓ | |
| `.push` | | | | | ✓ | ✓ | | | ✓ | |
| `.fetch` | | | | | ✓ | ✓ | ✓ | | ✓ | |
| `.checkout` | ✓ | ✓ | ✓ | ✓ | ✓ | | | | ✓ | |
| `.merge` | ✓ | | | | ✓ | | | | ✓ | |
| `.rebase` | ✓ | | | ✓ | ✓ | | | | ✓ | |
| `.reset` | ✓ | | | ✓ | ✓ | | | | ✓ | |
| `.stashSave`, `.stashApply`, `.stashDrop` | ✓ | | | | | | | ✓ | | |
| `.branchCreate`, `.branchDelete`, `.branchRename` | | | | | ✓ | | | | ✓ | |
| `.tagChange` | | | | | | | ✓ | | ✓ | |

### 9.2 Menu item → invalidation

| Menu item(s) | Invalidation |
|---|---|
| Stage, Stage Line / Selection / Hunk | `.stage(files:)` |
| Unstage, Unstage Line / Selection / Hunk | `.unstage(files:)` |
| Discard…, Delete Untracked…, Discard Line / Selection / Hunk | `.discard(files:)` |
| Remove ▸ … | `.stage(files: [path])` per tracked file; `.discard` for unindexed files |
| Assume Unchanged / Stop Assuming Unchanged | `.assumeUnchanged(files:)` (purged) |
| Ignore | `invalidate(.fileStatus)` |
| Stash Selected… | `.stashSave` |
| Apply, Pop (stash) | `.stashApply` |
| Rename… (stash), Drop…, Drop N Stashes… | `.stashDrop` |
| Pull (Merge), Pull (Rebase) | `.pull` (invalidateAll on failure) |
| Push, Push To… | `.push` |
| Synchronize | `.pull`, then `.push` |
| Fast-Forward to <upstream> | `.fetch` |
| Check Out… | `.branchCreate` + `.checkout` |
| Merge… | `.merge` (invalidateAll on failure) |
| Rebase…, Rebase Interactively onto Here…, Rebase Interactive From/Onto Here…, Squash N Commits…, Change Message…, Autosquash Fixups from Here | `.rebase` (invalidateAll on failure) |
| Reset Current Branch To Here ▸ … | `.reset` |
| Cherry-Pick, Revert | `.commit` (invalidateAll on failure) |
| Commit Staged as Fixup of … | `.commit` |
| New Branch from Here… | `.branchCreate` (+ `.checkout` if checked out) |
| Rename… (branch) | `.branchRename` (+ `.currentBranch` for the checked-out branch) |
| Delete…, Delete from Remote…, Delete N Branches… | `.branchDelete` |
| Set Tracked Branch…, Stop Tracking | `invalidate(.branchList)` |
| Add Tag Here…, Delete… (tag) | `.tagChange` |
| Refresh, Clean Up…, Update / Initialize and Clone, Remove Working Tree… | `invalidateAll()` |
| Push Tag, Sync URLs from .gitmodules | none named — panels refresh through `runGit` / submodule refresh |
| Graph toggles, Log, Show Diff, copy / open / reveal items | none (no repository change) |

---

## 10. Disabled and Hidden State Rules

Items are **disabled** (drawn gray) when the condition fails:

| Condition | Disabled items |
|---|---|
| Clicked repository is not the active one | Close Repository, Commit…, Pull (Merge), Pull (Rebase), Push, Synchronize, Refresh, Browse Reflog…, Worktrees…, Clean Up… |
| Repository not available on disk | Log (repository menu) |
| Branch is the current branch | Check Out…, Fast-Forward to <upstream>, Merge…, Rebase…, Rebase Interactively onto Here…, Delete… |
| Branch is not the current branch | Push (branch menu) |
| Branch is remote | Push, Push To…, Rename…, Set Tracked Branch…, Stop Tracking |
| Branch checked out in another worktree, or upstream gone | Fast-Forward to <upstream> |
| Branch has no upstream | Stop Tracking |
| Repository is already in that group / already ungrouped | Move To ▸ Group ‘<name>’ / No Group |
| Submodule not cloned | Open as Repository, Remove Working Tree…, Reveal in Finder |
| Every selected file is conflicted | Unstage |
| A selected file has no index entry, or is conflicted | Assume Unchanged / Stop Assuming Unchanged |
| No selected file is in the index | Remove ▸ From Index Only (keep file) |
| A selected file is a submodule | Compare N Files… |
| Clicked diff line is not + or −, or diff source not stageable | Stage / Discard / Unstage Line |
| No hunk, or diff source not stageable | Stage / Discard / Unstage Hunk |
| Diff source not stageable | Stage / Discard / Unstage Selection (N) |
| No line, or an empty filler row | Copy Line |
| Always (not implemented) | Stage Inner-line Change, Edit in Index Editor |
| Always (explanatory) | the Squash and Rebase Interactive reason rows in the Journal menu |
| Selection covers no branch/tag and not HEAD | Add to Graph, Remove from Graph (multi-selection) |
| No local, non-current branch in the selection | Delete Branch… / Delete N Branches… |
| No branch or tag in the selection | Copy Names |
| File deleted in the commit | Log window Files pane: Blame, Open, Open in Editor |

Items are **hidden** (left out of the menu) when the condition fails:

| Item | Shown only when |
|---|---|
| Init Git Here | the folder is not a git repository |
| Fast-Forward to <upstream> | local branch with an upstream |
| Pop | stash is stash@{0} |
| Copy URL | submodule has a URL |
| Blame… (Files) | file is not untracked |
| Compare… / Compare N Files… / Resolve Conflict… | one of the three, by selection size and conflict state |
| Delete Untracked… | selection contains untracked files |
| Stage / Discard / Unstage Selection (N), Copy Selection (N lines) | more than one line selected |
| Stage… / Discard… items vs. Unstage… items | working-tree diff vs. HEAD-vs-Index diff |
| Squash N Commits… (or its reason row) | two or more commits selected, clicked row among them |
| Change Message… | `JournalViewModel.canChangeMessage(of:)` |
| Commit Staged as Fixup…, Autosquash Fixups from Here | `JournalViewModel.canFixup(_:)` |
| Rebase Interactive From Here… / Onto Here… | by `interactiveRebaseAvailability(from:)` |
| Rename Group…, Delete Group | named group (not "Other") |
| Open in Terminal (repository tree) | node is a directory |
| Copy Relative Path (repository tree) | node is inside the active repository |
| Drop N Stashes… (multi-selection) | selection includes stashes |
