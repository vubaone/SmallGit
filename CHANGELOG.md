# Changelog

All notable changes to SmallGit are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and app releases use the calendar-style versioning described in
[MAKE_VERSION_GUIDE.MD](MAKE_VERSION_GUIDE.MD).

## [Unreleased]

### Added

- **Align two lines by hand in the compare window.** Beyond Compare's
  "Align With": right-click a line → "Align HEAD Line 34 With…", then click
  (or right-click) the line on the other side that belongs beside it. The
  compare runs again above and below the pin, so the two lines share a row
  and everything else falls into place around them. A banner says what the
  next click will do and Esc cancels; pinned rows carry a pin in the gutter,
  "Remove Alignment" on the row menu takes one back, and the "N aligned"
  button in the toolbar clears them all. A pin that crosses an earlier one
  replaces it, and pins outlive a save as long as both lines still say what
  they said when pinned.

- **Keep a folder out of git from the sidebar, without touching
  `.gitignore`.** Right-click a file or folder in a repository's tree →
  "Exclude Locally" adds it to `info/exclude`: ignored the way `.gitignore`
  would, but on this machine only, since that file is never committed. The
  pattern is anchored, so excluding `.notes` at the top does not also hide a
  `.notes` deeper down. "Assume Unchanged" / "Stop Assuming Unchanged" set the
  flag on every tracked file in the folder — the Files panel can only reach a
  file once git reports it, and never a whole folder. The flag needs a tracked
  file to sit on, so on a folder git has never tracked it says so and points
  to Exclude Locally instead.

- **A stash can be saved as a patch.** Right-click a stash in the Branches
  panel → "Create Patch…" opens the same sheet as Files and Journal, named
  after what was typed for the stash (`stash-wip-avatar.patch`). The patch
  holds everything the entry does, untracked files included: `stash push -u`
  keeps those in a third parent, and a patch built from the entry alone would
  leave out every new file. It is built with `git diff-tree` rather than `git
  stash show -p`, which with `stash.showIncludeUntracked` set lists the
  untracked files itself — on top of the third parent, each new file would
  appear twice and `git apply` would refuse the patch.

- **A stash you can take without losing your place.** Save Stash has always
  done two things at once — write the entry, then roll the working tree back
  to HEAD — and no git flag asks for only the first half. The Save Stash menu
  now offers "Save Snapshot (keeps your changes)", and the dialog a checkbox
  for the same thing: the entry appears in the stash list while every staged,
  unstaged and untracked file stays exactly where it was. A stash can now be a
  point to come back to rather than only a way to clear the decks.

  It is assembled the way git assembles one internally: `git stash create`
  writes the stash commit and prints it without touching anything, and `git
  stash store` files that commit under `refs/stash`. `create` parses no
  options at all — everything after the word is joined into the message, so
  `-u` would be *recorded* rather than obeyed — so the untracked half is built
  here: the parentless commit holding the untracked files, grafted on as the
  third parent exactly as `stash push -u` records it. When the only changes
  are untracked ones `create` prints nothing at all, and the entry is built
  from HEAD instead.

  A snapshot is always the whole working tree, because `create` accepts no
  pathspec either, so the dialog disables it for a "Stash Selected…" scope —
  and disables `--keep-index`, which has nothing to keep when nothing is
  reverted.

- **Discard works on a selection that isn't all the same kind of file.** It
  ran one `git checkout --` over every selected path, and git validates every
  pathspec before it touches the working tree — so one untracked file ("did
  not match any file(s) known to git") or one conflicted file ("path … is
  unmerged") aborted the whole command and *nothing* was discarded, including
  the files that were perfectly discardable. The selection is now split and
  each kind goes through the command that can actually discard it: tracked
  files to `checkout --`, conflicted files to `checkout HEAD --` (the only
  source that clears the unmerged stages), untracked files to `clean`.

  They run in order of increasing irreversibility and stop at the first
  failure, so a repo that refuses the earlier steps hasn't already deleted the
  files git isn't storing anywhere. The confirmation names each consequence
  separately, because reverting a tracked file and deleting an untracked one
  are not the same promise.

- **A stash apply that stops in conflict can be abandoned.** Git records
  nothing for it — no `MERGE_HEAD`, no sequencer, just unmerged index
  entries — so there was no banner, no Abort, and no Continue that would ever
  arrive. The Files panel now shows the conflict banner for unmerged files
  with no operation behind them, saying plainly that no merge or rebase is
  running, and offers "Abort Stash Apply" when SmallGit is the one that
  applied the stash, and confirms before restoring.

  The Abort appears whether or not SmallGit is the one that ran the apply.
  Remembering the stash only helps the session that got stuck, and by then
  most people have restarted the app looking for the way out — so a conflict
  with no operation behind it is matched against the stash list, and the entry
  whose files cover every conflicted path is the one that was applied.

  Abort restores the files the stash touched and stops there. `git reset
  --hard` would be one line and would take every other uncommitted change
  with it, including work staged before the apply. Files the stash would have
  *added* are unstaged but left on disk: HEAD has no version to restore, and
  deleting them would destroy content git has never held a copy of. The stash
  itself is kept, so the apply can be retried.

- **Start an interactive rebase from a commit in the Journal.** The log's
  right-click menu had "Rebase Interactive From Here" wired to the
  not-implemented placeholder, even though the planner sheet behind it has
  shipped since the branch menu got it. It now opens that same sheet: the
  clicked commit becomes the base and everything after it arrives as a plan
  you can reorder and set pick / squash / fixup / drop on, per commit.

  The clicked commit is the base, so it is *not* in the list — it is what the
  rest replays onto, which is what `git rebase -i <commit>` means. The row
  goes disabled, saying why, for the three ranges git would mishandle without
  complaining: a commit that isn't on HEAD (the range would quietly resolve to
  everything since the merge-base), HEAD itself (nothing to replay), and a
  range containing a merge — plain `rebase -i` leaves merges out of the todo
  and replays their side branch inline, flattening history silently. It also
  stands down while search results are shown, like the fixup pair, since a
  rewrite strands the hashes on screen.
- **Revert a line straight from the diff, without opening a menu.** Hovering a
  row in the Changes panel's side-by-side layout puts an arrow on the divider
  between the two panes: click it and the left pane's version of that line
  wins. What that costs depends on which two trees are being compared, so the
  tooltip names both and the consequence — HEAD ↔ Index unstages the line and
  the working file keeps it, Index ↔ Working discards the edit and nothing
  else holds it.

  The arrow points right in both modes, because both are the same sentence:
  the right pane is downstream of the left either way. A row with no change
  doesn't get one — the two sides already hold the same text, so copying
  across would write back what is there. A modification is both halves of one
  row and travels as a pair: reverting has to take the `+` away *and* put the
  `-` back, or the line ends up neither version. Unified is unchanged; its
  row menu already carries the same commands.

- **Copy more than one line out of a diff.** Drag down a diff to select the
  rows you want — or click, ⌘-click and ⇧-click them — then take them with the
  Copy button that appears in the diff toolbar, ⌘C, or the row menu's "Copy
  Selection (N lines)". Selecting rows works in the read-only compare windows
  now too — the commit compare, File History and the Stash window — which had
  no selection at all and so no way to get their contents out.

  SwiftUI scopes text selection to a single `Text`, and a diff row is one, so
  a drag can never select *characters* across rows; whole rows is what there
  is. In side-by-side a drag stays in the column it started in, since a
  selection crossing the divider would interleave the two sides line by line
  on the pasteboard. What lands there is the content alone — no `+`/`-` marker
  and no line number — because a copied diff is nearly always on its way into
  an editor. ⌘C steps aside while a text field is being typed in, so it still
  copies from the file filter and the find bar.

- **A stash opens as files and a diff, not one long patch.** "Show Diff" on a
  stash — from the Branches panel, a double-click on the row, or the Stashes
  window — now opens a window shaped like the Log window: the files the entry
  holds on the left at a fifth of the window — so side-by-side reads 20/40/40 —
  the diff of whichever one you click on the right, and "All Files" to go back
  to the whole entry. Double-click a row (or "Compare…") to
  open that file's stashed version against what it was stashed on top of, in
  the configured external diff tool or the built-in compare window.

  It used to drop every file of the stash into the main Diff panel as one
  unbroken run of hunks, with no file headers and no way to ask what the stash
  did to a particular file.

  Files that were untracked when the stash was made are in the list too. `git
  stash push --include-untracked` keeps them in a third parent of the entry
  rather than in the entry itself, so `git stash show` alone never mentioned
  them — a stash of nothing but new files read as empty.

- **Name the side that deleted the file in a modify/delete conflict.** The
  State column now reads "Deleted by us" or "Deleted by them" — and "Added by
  us", "Added by them", "Both added", "Both deleted" — instead of flattening
  every unmerged path to "Conflict". `git status --porcelain=v2` carries this
  in the `XY` of a `u` record, which the parser had been discarding in favour
  of a hardcoded `UU`. An ordinary content clash still reads "Conflict".

  This is the difference between two edits to reconcile and one side removing
  the file, and until now the UI had no way to say which you were looking at.

- **Compare every selected file in one tabbed window.** Right-click a
  multi-selection in Files and "Compare N Files…" opens one native macOS tab
  per file, in the same order as the table. Each tab keeps its own editor,
  search and unsaved-work guard, and reopening a file raises its existing tab
  instead of duplicating it. External diff-tool preferences remain honoured.

- **A performance badge in the status bar.** Settings › Diagnostics has "Show
  performance badge": tick it and the status bar carries CPU, memory, disk I/O
  and network I/O, refreshed once a second. Off by default, and nothing
  samples anything while it is off — the loop belongs to the badge, so a
  measuring tool nobody is looking at costs nothing, which is the first thing
  to get right about one.

  Two of the four numbers mean something narrower than their labels, and the
  badge says so on hover. CPU and memory are SmallGit's own, not the git
  processes it spawns, and CPU is a percentage of one core, so more than 100%
  is normal on a machine with more than one. Network is machine-wide: macOS
  has no public per-process counter, and SmallGit's transfers happen inside
  git, so a per-process number would sit at zero through a fetch.

- **The conflict resolver says what each line becomes.** Click any line in the
  Ours / Base / Theirs panes and the strip below shows that one line four
  ways: what ours has, what the ancestor had, what theirs has, and — the
  point of it — what the merged file will hold there. A side with no line at
  that row says so rather than showing a blank that could be an empty line,
  and a chunk nobody has decided says that instead of showing a result that
  is not true yet. Beyond Compare's merge strip reads this way, and it is the
  question a conflict is read line by line to answer: is anything changing
  here, and to what. What it replaces — two blocks of Ours and Theirs text —
  only answered the whole-side question the Take buttons above already
  answer.

  FINAL is read out of the merged pane, not deduced from the button that was
  pressed. That pane is editable, so the two part company the moment anyone
  types in it, and the answer worth showing is the file's: a line edited by
  hand appears as it now stands, marked as edited. Add or remove a line and
  every index past it is a guess about which line the row became, so the row
  says it no longer lines up rather than pointing at the wrong one.

  Clicking a conflict line also focuses its chunk, so the Take buttons act on
  the line being looked at; moving to a chunk with Next, or from the chunk
  list, points the inspector at that chunk's first line so the strip is never
  blank. A pane's text becomes selectable only once its row is selected — a
  selectable text view swallows the click that lands on it, which left
  clicking a line doing nothing unless the pointer missed the glyphs.

- **"Open as Repository" scrolls the list to what it just opened.** Handing a
  submodule over to the main window left its row wherever it happened to be —
  a hundred rows down a long list, or newly added to the end of one — so the
  repository was open while the row that carries its branch, its tree and
  every right-click action was off screen. The list now brings it into view.
  Only that flow does: scrolling on every change of active repository would
  move the list under someone who is reading it, and clicking a row you can
  already see should not move it.

- **A click in the Repositories list can select instead of open.** Settings ›
  Interface has "Single click opens a repository", on by default — which is
  how SmallGit has always behaved. Turn it off and the list reads the way
  SmartGit's does: a click selects the row and nothing else moves, and it
  takes a double-click to make that repository the active one. Both readings
  of a click are reasonable, but they do not cost the same — opening reloads
  the Files, Diff and Journal panels around a repository you may have hit by
  accident, while selecting costs a second click. A selected row is drawn in
  the list-selection grey rather than the accent blue that means "this is the
  active repository", so a click never looks like it did more than it did.

- **Uncommitted changes are a row in the log now.** Every repository's journal
  starts with the working tree when it is not clean — "Uncommitted changes,
  N files" above the history it is not part of yet, drawn with an open dashed
  circle where a commit's filled dot goes. A log that looks the same clean or
  dirty is a log that lets someone forget they have not committed. In the Log
  window the row behaves like any other: the Files column lists what is
  uncommitted, selecting one puts its working-tree diff below, and the detail
  pane says how much is staged and how much is not.

  It is deliberately not part of the commit selection. Uncommitted work has no
  hash, and letting it into that set would offer it to every range operation
  the journal has — squash, cherry-pick, reset — each of which would then need
  to special-case a row with nothing to operate on.

- **Double-click a submodule and see what moved it.** A submodule row is a
  directory, not a file, so the file compare double-click used to open asked
  git for `HEAD:<submodule>` and got `fatal: bad object` — the window opened
  empty. What a moved pointer actually raises is "what changed in there", and
  the answer is a log: the commits between the commit this repository records
  and the one the submodule is checked out at, marked `>` and `<` the way
  `git diff --submodule=log` marks them. Selecting the row shows the same
  commits in the Changes panel, which until now showed two bare
  `Subproject commit` SHAs and told nobody anything.

  Double-clicking opens the submodule in a window of its own — its history,
  its files, its diff, and a commit box for the work inside it — with a
  repository context that is genuinely separate from the main window's. That
  separation is the feature: you are working in A, you look into B, and A is
  exactly where you left it. An earlier version made B the *active*
  repository instead, which moved the main window off A and then put B's
  commit dialog over A's window, since that dialog belongs to whatever is
  active. Switching the main window to a submodule is still available, as the
  explicit action that says so.

  Double-clicking a file in that window opens the app's compare on it — the
  editable two-pane one for uncommitted work, the read-only commit compare for
  a file inside a commit — pointed at the submodule. Everything about a
  compare is repository-scoped: which file is read, which commit the other
  side comes from, and where a save is written. Windows are keyed per
  repository too, so a submodule's `src/main.swift` and the parent's are two
  windows rather than one that raises the wrong file.

  Committing there commits in the submodule and stops. The parent goes on
  recording the old commit, which is correct and is exactly when "Record in
  Parent" appears: it stages the submodule so the parent's next commit
  records it, and leaves that commit — with its own message — to be made in
  the parent. The log marks which commit the parent records and which are
  past it. The diff pane in that window cannot stage, because staging runs
  against the active repository and the diff there belongs to a different
  one.

  The panel leads with the two ends, the way SmartGit's does: the recorded
  commit and the checked-out one side by side, each with its author, date and
  subject, and a Compare between them that opens the log. A moved pointer is
  not a text diff, so the controls that describe one — Unified, Side by Side,
  change navigation — are not shown for it. A submodule with uncommitted work
  inside lists those files under it, with the sentence that actually resolves
  the confusion: they belong to the submodule, and the parent can only record
  a commit, never an edit.

  The Files panel can finally tell the two kinds of "Modified" apart. Git
  reports both a moved pointer and a dirty checkout as `.M`, and separates
  them in a field of `--porcelain=v2` that SmallGit had been discarding; rows
  now read "Submodule moved" or "Submodule dirty", which are opposite
  situations — one is ready to commit here, the other has to be committed in
  there first.

- **Fold the Journal and Output away (⌃⌘J).** An arrow in front of the Journal's
  title collapses the whole bottom row to a single bar naming what is down
  there, and the arrow on that bar brings it back — the height goes to the
  Changes / Terminal panel above, which is the point. The arrows point the way
  the panels move, down to put them away and up to pull them out, rather than
  the sideways triangle of a tree, which would say nothing about where the
  content went. Only the arrow reopens the row — the bar sits between the
  terminal's input and the status bar, and a full-width target there would
  spring the panels open on a click aimed at either — so the arrow carries a
  hit area far larger than the glyph. Remembered across launches like the
  other layout choices, and an older `ui-state.json` without the key still
  loads rather than being thrown away over a missing boolean.

- **Tab completes in the terminal.** All three things Tab does in a shell:
  finish the word when there is one answer, extend it as far as the answers
  agree when there are several, and show them when it cannot get further —
  candidates appear above the input, and clicking one takes it. Paths complete
  against the directory the next command would actually run in, so completion
  and execution can never disagree about where "here" is; directories finish
  with a slash so the next Tab carries on into them, files with a space. Dot
  files stay hidden until the dot is typed, spaces in names come back escaped,
  and `~` expands without losing a trailing slash. The first word completes
  commands — what is on PATH, plus `cd` and `clear`, which no PATH lookup
  would find — unless it looks like a path, because `./script` means the file.
  After `git`, it completes subcommands.

  Completion happens at the end of the line rather than at the cursor:
  SwiftUI's text field does not publish a cursor position, and Tab pressed
  mid-line is rare enough that this beats not offering it.

- **A terminal in the Changes panel, for when typing it is faster.** The switch
  sits beside the panel title — CHANGES becomes TERMINAL and back, ⌃⌘T either
  way — and the choice is remembered, because preferring a command line is a
  standing preference rather than a per-session mood. Commands run in the
  active repository (and follow it when you switch), with up-arrow history,
  a stop button that reaches the process rather than merely stopping listening,
  and output streamed as it arrives instead of arriving all at once at the end.
  It renders at the same monospaced size as the diff and zooms with the same
  ⌘+ / ⌘-, since someone who sized the diff to be readable meant this too.

  It is a command runner, not a terminal emulator, and the difference is what
  makes it safe to put in a GUI: each command is one non-interactive shell
  with no tty. Anything that wants to *ask* something — an editor, `git rebase
  -i`, a passphrase prompt — fails immediately instead of hanging invisibly,
  because stdin is `/dev/null` rather than a handle that never answers.
  Everything that prints and exits, which is nearly all of git, behaves as it
  does in Terminal.app.

  `cd` and `clear` are handled in the app rather than passed to the shell: a
  shell that exits takes its answer with it, so `cd src` would otherwise change
  a directory in a process that immediately stops existing. `cd` as part of an
  expression (`cd src && make`) still goes to the shell, since treating that as
  the built-in would run half of it. Tools are asked not to colour their output
  (`TERM=dumb`), and any escape sequences that arrive anyway are stripped, so
  the transcript never shows `ESC[32m`.

- **A view for assume-unchanged files, and a tip that says what that means.**
  `git update-index --assume-unchanged` tells git to stop checking a file, so
  your local edit to a config file stays out of status, out of every diff, and
  out of every commit. It is also completely silent: a flagged file leaves
  nothing on screen, which is how people end up wondering for a week why their
  change won't commit.

  A fifth toggle in the Files header (⌘5) lists them. It can't be a filter over
  `git status` the way the other four are — status cannot see these files at
  all — so it's a second read of the index, `git ls-files -v`, made only while
  the view is on. The flag is encoded there as case: git lowercases the entry's
  usual tag when it is set, so a flagged skip-worktree file comes back as `s`
  and matching on `h` alone would have missed it. Flagged rows land after what
  changed, marked "Assume unchanged" in the State column, and a path that turns
  up in both this list and the filter's find-file results is still listed once.

  Right-click sets and clears the flag — "Assume Unchanged" on a selection that
  hasn't got it, "Stop Assuming Unchanged" when every file in the selection
  has, so a mixed selection can't silently unflag half of it. The item switches
  off for untracked and conflicted files, because `update-index` refuses those
  and fails the whole call over one of them, tracked paths in the same
  selection included.

  The button itself gets what a button like this needs: hover text that
  explains the flag rather than restating the label, and — while the view is
  on — a quiet one-line tip under the panel header saying what git is now
  ignoring, or that nothing here is flagged, which is the reading of an empty
  list that would otherwise look like a broken button. It closes for the
  session.

- **Drop several stashes at once.** The stash browser takes a multiple
  selection — shift-click a run, ⌘-click to pick them out. Drop is the only
  action that works on more than one: applying two stashes is two operations
  with two outcomes, and the diff of two of them at once means nothing, so
  Show Diff, Apply and Pop stay on a single selection.

  The confirmation lists what is about to go — index and message, up to eight
  of them and a count for the rest — because "Drop 4 stashes?" asks you to
  trust a selection you made by shift-clicking, and nothing undoes this one.

  Dropping runs from the highest index down. Each drop renumbers the entries
  above it, so a list of indices read off the screen goes stale the moment the
  first one lands; taken in the other order, dropping @{1} and @{3} would take
  @{1} and @{4}. A drop that fails stops the run rather than continuing down a
  list whose meaning has changed.

- **The stash browser is a window you can resize.** It was a SwiftUI sheet,
  which sizes itself to its content and then stays there — no edge to drag, and
  a list of ninety stashes showing seven of them. It now opens the same way
  File History does: window-modal, but a real window underneath, so the height
  is yours to choose and it starts at a size worth reading. A close button sits
  in its top corner, since a window-modal sheet has no title bar to close from
  and Escape is not something you can see.

- **Branches sort the way you'd number them.** git orders branches as plain
  text, so `ZSOC-1056` came before `ZSOC-153` and a ticket number you were
  looking for could sit anywhere. Runs of digits now compare by value, in the
  sidebar tree and in every branch picker: 153, 306, 345, … 1056, 1183. Names
  with several numbers in them sort by each in turn, so `release-9.10.1`
  precedes `release-10.2.9`. Letters compare exactly as before.

- **A confirmation dialog for deleting a branch.** "Delete…" used to run
  `git branch -d` on the spot, so an unmerged branch produced nothing but a red
  row in the command log with git's "not fully merged" hint folded up inside
  it — after the fact, and easy to miss.

  SmallGit now asks git first whether the branch is contained anywhere, and
  says so: "Already merged into main — deleting it loses no work", or "Not
  merged anywhere: 3 commits on this branch are not on main". A branch that was
  pushed but never merged into your current branch is reported as both — safe
  to delete, but still carrying work `main` has never seen. If its upstream is
  gone from the remote, the dialog says that too, since that is precisely why
  git will not vouch for the commits.

  Deleting an unmerged branch needs the "Delete anyway, discarding 3 commits"
  box ticked before Force Delete unlocks. If git refuses a delete SmallGit
  expected to succeed, the dialog stays open and offers the force path rather
  than reporting a bare failure.

- **Submodules.** A Submodules section in the Branches panel — alongside Local
  Branches, Tags and Stashes — listing each submodule with its commit and
  state: up to date, not initialized, moved, or conflicted. Hidden entirely
  when the repository has none, which is most of them.

  Double-click a submodule to open it as a repository of its own, which is the
  point: everything SmallGit already does to a repository then applies to it,
  with no new concepts to learn. Right-click for Update / Initialize, Open as
  Repository, Sync URLs, Remove Working Tree, Reveal in Finder and Copy
  Path / URL.

  Repository ▸ Submodules… opens the full browser, which is where Add lives —
  it needs a URL and a path, which a sidebar row has no room for. Removing a
  working tree that has uncommitted work asks first.

- **Double-click a commit in File History to open the full compare.** The
  history window's own diff pane is a preview; double-clicking any row now
  opens that revision in the same large compare window the Log window uses —
  with syntax colouring, ⌘F and the rest. The row's context menu carries the
  same action, plus Copy Hash and Copy Subject.

- **⌘F search in the compare and conflict windows.** A find bar under the
  header, with a live match count, Next / Previous (⌘G, ⇧⌘G, or Return and
  ⇧Return), and Match Case. Every hit is highlighted amber and the one you're
  on is highlighted brighter, so stepping through a screen with a dozen hits is
  followable; the view scrolls to each in turn. Escape closes the bar rather
  than the window.

  The search runs across *both* panes of a side-by-side compare, stepping down
  the file and taking HEAD before WORKING on any row they share — rather than
  walking all of one pane and then all of the other. A hit inside a region you
  have collapsed expands that region rather than being unreachable. Queries are
  literal, not regular expressions, because source is full of characters a
  regex engine would treat as syntax.

  The conflict resolver's MERGED pane is an editor, so ⌘F there brings up
  AppKit's own find bar, which offers replace as well.

- **Selectable text in the compare and commit-compare windows.** Selection is
  per line — SwiftUI scopes it to one row, so a drag can't run across lines —
  and the row context menu gains Copy HEAD Line, Copy WORKING Line and Copy
  Both Sides for what a multi-line drag would otherwise be for. The cost is
  that clicking directly on a line's text now places a caret instead of
  opening the bottom inspector; the inspector is still reached by clicking the
  row's gutter, by ⌘J / ⌘K, or from that context menu.

- **Browse a repository's files from the sidebar.** Every repository row now
  has a twist-down that opens its folder tree, nested as deep as you care to
  go — the SmartGit arrangement. Right-click any file or folder for Open,
  Reveal in Finder, Open in Editor / Terminal, Copy Path, Copy Relative Path
  and Refresh. Clicking a folder toggles it; clicking a file opens it.

  Directories are read only when first expanded and then cached, so a
  collapsed repository costs nothing however large it is, and the read happens
  off the main thread. Folders sort before files, then case-insensitively by
  name. `.git` is hidden — it is the repository's own plumbing and expanding it
  buries the tree in loose objects — while `.github`, `.agents` and other
  dotfiles are ordinary project content and stay.

  The tree is a snapshot of the disk, not a live view, so Refresh is there for
  after a build or a branch switch.

- **Diagnostics: I/O and network logging, readable in Settings.** SmallGit now
  records what it actually does — every git invocation, every disk-cache and
  config read/write, and every file-watcher batch — to
  `~/Library/Logs/SmallGit/`, capped at 5 MB total.

  Settings › Diagnostics reads it back in three views. **Findings** names the
  patterns that usually mean a bug: an operation running on a loop, anything
  that failed, a remote call that took unusually long, a disk cache that has
  stopped serving. **Summary** gives per-operation count, calls/min, average,
  slowest and error count, sorted by whichever of those you're chasing.
  **Records** is the raw stream, filterable by category and text.

  The Findings view exists because the two bug shapes look nothing alike in a
  raw log. Something slow shows up in a single record — if you happen to
  scroll past it. Something running 100 times a minute shows up in no record
  at all: each one is fast and successful, and only the arithmetic gives it
  away. That second shape is the one this app has already had once, when
  `git status` polling kept rewriting the index the file watcher was watching.

  git is also the only thing here that touches the network, so every git call
  is filed as **Network** or **Git** by what its subcommand actually does —
  `git remote update` is a connection, `git remote -v` is a config file read.
  Without that split, "is it the network or the disk?" can't be answered after
  the fact.

  Credentials are stripped before anything is written: an HTTPS remote carries
  its token in the URL, and a log you're invited to read is one you might
  paste into a bug report. Home directories are abbreviated to `~` for the
  same reason.

  Conflict resolution is recorded too — which chunks were taken from which
  side, bulk resolves, per-file take-ours/take-theirs, saves, and aborts with
  their outcome. Those choices live in memory until Save & Stage, so nothing
  else in the log showed what had been clicked before something went wrong.

  Findings also names the operation that dominates total time when it does so
  across hundreds of cheap calls — bursty work averages out below any rate
  threshold while still being most of what the app did.

  Rates are measured against time the app was *active*, with the gaps between
  launches removed. The log survives across sessions, and dividing by the
  hours it spent closed buries the finding: measured on the first real log,
  two bursts totalling 141 seconds nine hours apart made a `git rev-parse`
  storm running at 123/min read as 0.5/min.

  Recording is on by default and costs one buffered write roughly per second —
  a logger that writes synchronously would add a disk write to every operation
  it times, including the disk ones, and end up measuring itself. It can be
  turned off at the top of the tab.

- **Syntax colouring in the main Diff panel and File History.** Both now
  colour source the same way the compare windows do: syntax on the
  foreground, add/delete carried by the row background and the `+`/`-`
  marker.

  A stash or commit diff is several files in one stream, so the parser now
  records each hunk's path from its `diff --git` header and every row is
  coloured by *its own* file's language. Without that, a commit touching both
  Swift and Markdown would light the prose up with keywords.

- **"Base" resolution for a conflict chunk.** Restores the common ancestor,
  discarding both sides' changes — Beyond Compare's "Take Center", KDiff3's
  "A". The resolver showed a BASE pane the whole time while offering no way
  to take it.

  It is deliberately distinct from "Neither", which deletes the conflicting
  lines outright: the two are easy to confuse and produce opposite results,
  so the tooltips now say so. ("Neither" matches KDiff3, where deselecting
  every source saves an empty region, and VS Code's merge editor, where
  unchecking both does the same.)

  Never a dead end. git's default `merge.conflictStyle` writes only ours and
  theirs into the markers, so most conflicts have no ancestor in the file —
  even though the BASE pane can show it from the index. Choosing Base there
  offers to rewrite that file's markers to include it
  (`git checkout --conflict=diff3`), then applies the choice you were making.
  The file stays conflicted and unstaged. A greyed-out button next to a
  visible BASE pane reads as a broken feature rather than a missing input.

- **Syntax colouring in the conflict resolver.** All five panes: OURS, BASE
  and THEIRS across the top, the chunk inspector's Ours/Theirs previews, and
  the editable MERGED result. The conflict wash stays a background and syntax
  stays a foreground, so a conflicted region still reads as conflicted.

  The merged pane changed from SwiftUI's `TextEditor` to an `NSTextView` to
  make this possible — `TextEditor` binds to a plain `String` on macOS 14, so
  colour is not expressible through it. That swap fixes a latent hazard too:
  `TextEditor` inherits AppKit's automatic substitutions, so the system was
  free to rewrite a `"` in merged source as a typographic quote. All
  substitutions are now off, and undo still works.

- **Syntax colouring in both compare windows.** Keywords, types, strings,
  numbers, comments, directives and function calls are coloured in the
  HEAD↔WORKING compare and in the Log window's commit compare, on top of the
  existing red/green. 18 languages: Swift, Objective-C, C, C++, Java, Kotlin,
  C#, JavaScript, TypeScript, Go, Rust, Python, Ruby, shell, SQL, JSON, YAML
  and CSS, chosen by file extension (or by name, for `Podfile` and friends).
  A file whose language isn't in that list is left plain rather than guessed
  at — a wrong keyword colour in a diff reads as meaning.

  The two layers stay separate: syntax owns the *foreground*, the diff owns
  the *background*. So an edited region still shows which characters changed,
  and now shows what they are.

  No new dependency. The alternative was Highlightr, which wraps highlight.js
  in JavaScriptCore — ~190 languages for the price of a JS engine in-process
  and a bridge crossing per line, on a view that renders thousands of them.
  The scanner here is a few hundred lines of Swift and needs no runtime.

  Where the whole file is on hand — the HEAD↔WORKING compare — both versions
  are scanned end to end, so a block comment or a Python docstring is coloured
  across every line it spans. The commit compare only ever holds hunks, so it
  colours each line on its own; a `/* … */` opened above the hunk reads as
  ordinary code there. The main Diff panel is deliberately untouched: solid
  red/green lines are what make a long unified diff scannable.

### Fixed

- **Pushes containing GitHub Actions workflows can recover from missing
  permission.** When GitHub rejects an HTTPS push for a missing `workflow`
  scope, SmallGit explains the missing permission and offers **Authorize
  Workflow Access**. GitHub CLI refreshes the active account's authorization;
  the pending push retries after approval. Cancel or failed approval leaves
  it unpushed, and ordinary sign-in does not request the extra scope.
- **A changed line in a compare sits beside its own replacement.** Two
  declarations that each gained a parameter came out with the second old line
  beside the first new one and the other two beside nothing: only the last
  removed line of a block was ever paired, with the first added one. Every
  line of the shorter side now gets a partner, in order, and when the sides
  differ in length the spare lines go wherever that pairs the most similar
  lines (Beyond Compare's closeness matching). The conflict resolver's panes
  pair lines the same way.

- **Ticking the checked-out branch by name graphs it as HEAD.** Rebase a
  branch, tick it in the Branches panel beside another one, and the Journal
  showed neither the orange "not pushed" markers nor the commits still on its
  remote — both were only worked out when the HEAD box itself was ticked. The
  branch HEAD has checked out is HEAD's history under another name, so it now
  counts the same: outgoing commits are marked, the diverged upstream is drawn
  as a fork, and the "N here, M on origin/…" banner says how far apart they
  are.

- **A compare block opened for typing stays where its lines are.** Click into
  the WORKING side of a split compare and the block's editor could open far
  off to the right, half out of the pane: the gaps it keeps for lines only
  HEAD has were drawn with spacers as wide as whatever they were offered, and
  the pane offers the width of its longest line. The block also ran 2pt per
  line shorter than HEAD's rows beside it — its lines were a line of text
  tall, the rows a line plus padding — so a 26-line block ended 50pt early,
  and every row below it was out of step with the other pane. Each line of
  the block is now a row tall, with its text mid-row like the rows' own.

- **Double-clicking a file in the commit dialog shows what will be
  committed.** Stage one hunk of a file with three changes and commit that
  file: the dialog commits the index, so only that hunk goes in — but the
  double-click compared HEAD with the working tree and showed all three.
  A staged file now opens HEAD against the index, read-only, in the external
  diff tool too when one is set (both sides are temp copies there, since the
  working file is not what is being committed). A file with nothing staged,
  which the dialog stages whole, still compares against the working tree.

- **The rebase plan no longer lists commits the base already has.** Branch B
  off A, let someone rewrite A's history and add to it, then rebase B onto A:
  the planner listed A's original commits alongside your own, so a six-row plan
  appeared where three were expected and the user had to set A1, A2, A3 to
  `drop` by hand — and replayed work A already had if they didn't.

  The range was built with `git log <base>..HEAD`, which compares by commit.
  git's sequencer compares by *patch*: a rewritten upstream carries the same
  changes under new SHAs, and git drops them with "skipped previously applied
  commit …". That difference never showed up as an error because SmallGit
  overwrites git's todo wholesale rather than editing it — the plan simply won,
  and replayed the wrong commits. The listing is now the sequencer's own walk
  (`--cherry-mark --right-only <base>...HEAD`, `--no-merges`, `--topo-order
  --reverse`), checked against git's generated todo by a test that builds the
  force-pushed-upstream shape. The planner says how many commits were skipped
  and names them on hover, so they don't just vanish; a branch whose every
  commit is already upstream — a squash-merged PR — now says so instead of
  offering an empty plan.
- **Interactive rebase onto another branch is offered again.** Right-clicking a
  commit the current branch does not descend from — a branch tip graphed beside
  HEAD, an updated upstream — drew a disabled "Rebase Interactive — this commit
  isn't on HEAD". The reasoning was that `<commit>..HEAD` would then resolve to
  everything since the merge-base rather than to the commits after the clicked
  one. It does, and that range is not a mistake: it is exactly what `git rebase
  -i <commit>` replays, and "take that branch as the base and put my commits on
  its end" is the ordinary way to move a branch onto a newer base. Verified
  against git — the plan SmallGit writes matches git's own todo commit for
  commit, which matters because the todo is overwritten wholesale rather than
  edited.

  The menu now names which of the two directions it means: **Rebase Interactive
  From Here…** for a commit on HEAD (reorder, squash or drop what came after
  it), **Rebase Interactive Onto Here…** for one anywhere else, and the planner
  is titled with the branch the commit carries rather than its short hash. The
  two checks that were doing real work moved to where they can still answer for
  a range reaching past the journal's loaded window: an empty range now says
  "HEAD is already on top of X" instead of opening an empty planner, and a merge
  in the range is named and refused instead of being flattened — git leaves
  merges out of its todo and replays their side branch inline, and SmallGit
  would otherwise have written a `pick <merge>` line git never generates. Both
  also now cover the Branches panel's "Rebase Interactively onto Here…", which
  had neither.
- **A rebase that conflicts can no longer lose its conflict to an Unstage.**
  Unstage ran `git reset HEAD -- <path>` over whatever was selected, and on a
  conflicted path that does not take a staged change back — there was never one
  to take. It collapses the three merge stages into a single entry matching
  HEAD and leaves the working tree untouched, markers and all. What was left
  looked like ordinary work: the Files panel showed "Modified", the resolver
  and "Resolve Conflict…" were gone with the stages they read, and the banner
  counted no conflicts and said "all conflicts resolved" over a Continue button
  git then refused — `rebase --continue` stops at the unstaged change while
  telling the user to go resolve a conflict nothing on screen was showing.
  There was no way forward and no way back short of aborting the rebase.

  Unstage now leaves conflicted paths alone and takes the rest of the selection
  back as before; the menu item and toolbar button grey out when a conflict is
  all that is selected, and the commit dialog no longer unstages one when it is
  unticked. For a repository already in that state — a terminal can still make
  it — the banner names it ("1 file still holds conflict markers") and offers
  **Restore Conflicts**, which re-runs the merge with `git checkout -m` to
  bring both sides and the unmerged stages back so the file can be resolved
  normally.
- **Continue says why it cannot run instead of failing when pressed.** The
  button was disabled only while files were still conflicted, but `rebase`,
  `cherry-pick` and `revert` all continue through git's sequencer, which bails
  on *any* unstaged change — including one in a file the conflict never
  touched. The banner now reads "N files with unstaged changes" and the button
  explains that git refuses to continue with them. A merge finishes with `git
  commit`, which has no such rule, so nothing there changed.
- **Discarding or unstaging one line of a multi-line hunk no longer fails with
  "patch does not apply".** `git apply` matches a patch against the target by
  one side only — the preimage going forward, the postimage in reverse — so
  the lines the user did not pick have to be collapsed into whichever side is
  doing the matching. The builder only ever collapsed the forward way, and the
  four reverse operations (Discard Line, Discard Selection, Unstage Line,
  Unstage Selection) handed that result to `--reverse`: the dropped `+` lines
  were sitting in the target file in between the kept ones and the demoted `-`
  lines were not in it at all, so the postimage described a file nobody had.
  Any hunk holding more than one changed line was affected.

  The reverse collapse is now the exact mirror — untargeted `+` lines become
  context, untargeted `-` lines go — and it re-pairs each run the way the
  side-by-side view pairs it before emitting, because a hunk lists every `-`
  before every `+` and a restored line dropped in at that point lands at the
  top of the run instead of where the line it replaces sits. Covered by tests
  that run real git, which is the only thing that could see this.
- **One binary file no longer hides every text change beside it.** A commit or
  stash diff is several files in one stream, and a single `Binary files … differ`
  anywhere in it used to make the parser call the whole thing binary and return
  one "preview not available" line. The notice is now recorded against the file
  it belongs to, and the text diffs around it are parsed as usual.
- **Take Ours / Take Theirs no longer fail on a modify/delete conflict.** Both
  ran `git checkout --ours|--theirs`, which git refuses with "path 'x' does not
  have our version" when that side has no blob — the exact case the buttons
  were most needed for. They now check which index stages exist and, when the
  chosen side is the one that deleted the file, resolve with `git rm` instead.

  The buttons say what they will do, too: on a delete conflict they read "Keep
  File" and "Delete File" rather than "Take Ours" and "Take Theirs", which name
  a side but not an outcome. "Mark Resolved" is hidden there — a delete
  conflict has no markers to hand-edit, so staging what happens to be on disk
  would quietly mean "keep the file".

  The Conflict Solver keeps its full three-way view here rather than opening on
  four blank panes. One column is empty — its header says which branch deleted
  the file, instead of leaving it looking like a failed load — and the other two
  are the ones worth reading: BASE against the side that survived is exactly
  what that branch changed in the file someone else deleted, which is what the
  decision turns on.

- **Checking out a remote branch left you on no branch at all.** "Check Out"
  on a row under Remotes ran `git checkout origin/topic`. A remote branch is a
  pointer to read, not a place to stand, so git moved HEAD straight to that
  commit and detached it — and said so with exit code 0, which the app read as
  plain success and drew green. The first thing anyone does next is pull, and
  pull answers "You are not currently on a branch. Please specify which branch
  you want to rebase against."

  Checking out now lands on a branch wherever there is one to land on: a local
  branch of that name is switched to, and a remote one without a local
  counterpart creates it with `--track`, so pull and push have an upstream
  immediately. Every question is put to git — `rev-parse` on the ref — rather
  than to the cached branch list, which is empty before the panel first loads
  and stale after anything changes a ref outside the app; either would put the
  detaching case straight back. Only a tag or a bare commit still detaches,
  because for those there is nothing else git can do, and the status bar says
  so instead of reporting a bare success.

  The same detached HEAD is why the Repositories sidebar kept showing the
  branch the repo used to be on: `symbolic-ref HEAD` fails when detached, and
  both the branches view-model and the sidebar label treated that empty answer
  as "keep what you had" rather than "there is no branch". They now say the
  true thing, and the active repository's row reads `(detached)`.

- **Remove now handles tracked, untracked and ignored files in one
  selection.** Index-backed paths go through `git rm`; paths that have never
  been in the index go through a selection-scoped `git clean`, including
  ignored paths only when one was explicitly selected. A failed `git rm` now
  reports failure instead of refreshing the UI as though it succeeded, and
  index-only actions are disabled for selections they cannot operate on.

- **Turning diagnostics recording off did not survive a relaunch.** The
  Settings › Diagnostics switch changed the running app and was never written
  to disk, so the next launch went back to recording — which is the one way a
  switch like that is worse than not having one. It is saved now. Off has
  always meant off in the running app: no file is written, and nothing is held
  in memory waiting to be.

- **The Submodule window's Files list showed no selection.** Clicking a file
  loaded its diff into the pane below and left the list looking exactly as it
  did before, so the only way to tell which file you were reading was to read
  the diff. The row is marked now, in the same colours the journal beside it
  uses, and the mark follows what the pane is actually showing — moving to
  another commit clears it, because the pane holds a whole commit again.

- **Every git command parked a high-priority thread on a slower one.** Waiting
  for a command's output blocked a `.userInitiated` thread on a semaphore only
  the pipe's own default-QoS reader queue could signal — a priority inversion,
  and the runtime says so by name. The three things a result depends on
  (stdout's EOF, stderr's EOF, the exit) are counted now rather than waited
  for, and whichever lands last assembles the result on the thread that
  delivered it. Nothing blocks, so there is nothing left to invert. The
  streamed path behind the Terminal panel had the same shape and got the same
  treatment. What both were written to guarantee is unchanged: output still
  sitting in the pipe when the process has already exited is never dropped,
  which is why the end of a command is its pipe closing and not its exit.

- **Expanding a collapsed region in a compare no longer opens the whole gap.**
  The marker between two changes carries two arrows now: down brings ten more
  lines below the block above, up brings ten more above the block below, and
  pressing either again keeps walking. In a real file a fold is often hundreds
  of lines, and opening all of them to see three was a redraw of the entire
  document — a visible stall on a large one. "Show all" is still offered, and
  now says what it costs; a gap no bigger than one press shows a single arrow,
  since two that do the same thing is a choice with no meaning.

  The model underneath had to change for this to be possible at all: collapse
  took a set of fold *ids*, and a fold's id comes from its start and length,
  so a fold could only be open or shut. It now takes the set of revealed line
  indices, and revealing ten of four hundred simply leaves a shorter fold
  behind. Finding a search match hidden inside a fold got simpler with it —
  the line is revealed and the fold splits around it, rather than the display
  being rebuilt to hunt for the marker that was hiding it.

- **Selecting every row in a filtered large repository hung the app.** The
  filter lists tracked-but-unchanged files so it can be used as a finder, and
  in a repository with a hundred thousand tracked paths that meant a table of
  seventeen thousand rows — then ⌘A. Two things were wrong. The row list was a
  computed property: every read re-filtered the changed set, re-folded every
  tracked path to lower case and re-sorted the result, and a selection change
  causes many reads. And `hiddenCount`, which the panel header reads on every
  pass, unioned every tracked path into a set each time. Both are now computed
  once per change to their inputs, tracked by a version counter that every
  input bumps.

  The rows themselves are capped: the filter lists the first 500 unchanged
  matches and says how many more there are, because a finder's job is to put
  the file you meant near the top rather than to hand a table seventeen
  thousand rows to build. Everything that *changed* is always listed in full —
  that part is the panel's actual job, and it is never large.

  Selecting several files no longer loads a diff at all. It used to preview
  `Set.first`, which is an arbitrary member rather than a meaningful one, so a
  select-all also fetched a diff for a row nobody asked about.

- **The Journal could stay a commit behind.** Committing refreshes every
  panel, but the journal's reload is a read-through cache: post-action
  invalidation only clears the in-memory layer, so the reload fell through to
  the disk snapshot — the log as it was *before* the commit — and merely
  scheduled a background refresh the view never re-read. The new row appeared
  only when a file-watcher tick happened to reload the journal a second time,
  which is a race, not a refresh. It now bypasses the cache the way the Files
  panel already does, so the commit is on screen when the commit finishes.

- **Clone over HTTPS asked for a password it had nowhere to ask for.** A `.app`
  has no terminal, so git's prompt fails outright — `could not read Username
  for 'https://…': Device not configured` — and clone was the one network
  operation that let that stand as "Clone — failed". Fetch, pull and push have
  turned it into a sign-in sheet for a while; clone now does too, and re-runs
  itself once the password is saved. git removes the half-made directory when a
  clone fails this early, so the retry starts from clean ground. The answer is
  stored through the repository that asked — nil for a clone, which has none
  yet, rather than through whichever repository happened to be selected behind
  the dialog.

- **SSH failures said nothing about SSH.** The status line read "Clone —
  failed" while git's own words hid what went wrong: GitHub answers `ERROR:
  Repository not found` to a key that authenticated perfectly well but belongs
  to an account without access, which reads as "the repo is gone" when it means
  "wrong key" — the usual cause being a URL that says `github.com` where
  `~/.ssh/config` has an alias with the right `IdentityFile`. That, a rejected
  key, an unknown host key ssh cannot ask about with nowhere to ask, and an
  alias with no `Host` entry behind it now each get a line saying what to
  check. Only the SSH-side wording is claimed: over HTTPS "Repository not
  found" means what it says, and blaming a key would send you to the wrong
  file.

- **Two in-memory caches grew without limit within a session.** The git cache
  holds one entry per file per diff mode, so browsing a large repository's
  files accumulated a diff in memory for each of them, and the sidebar's file
  tree kept a listing for every directory ever expanded across every
  repository. Both are cleared eventually — on repository switch and removal —
  but neither was reclaimed while working. Both are now bounded, evicting
  least-recently-used entries; a directory that is still expanded is never
  evicted, since its listing is what draws the rows on screen.

- **Output rows still said "(starting)" after the command had finished.** That
  text was a placeholder written into the command column when the entry was
  opened — most operations don't know their argument list until they run — and
  nothing ever replaced it. Finishing now fills in the command that actually
  ran, so the panel reports what it executed rather than a stale placeholder,
  and each row shows how long it took. A row still in flight says "running…".

- **Clicking a branch, stash or submodule in the sidebar felt sticky.** Each
  row carried a double-click action as a competing tap recogniser, so SwiftUI
  held the first click for the system double-click interval to see whether a
  second was coming — selection lagged, and a quick click could be dropped
  altogether. The double-click actions are simultaneous gestures now, so the
  row highlights on the first click and a second still checks out, opens the
  stash diff, or opens the submodule.

- **Only branches could be selected in the Branches panel.** Tags, stashes and
  submodules never highlighted when clicked — the panel's selection was typed
  as a branch name, and only branch rows were tagged with one. All four kinds
  select now, and a branch and a tag that happen to share a name stay distinct.

- **Sidebar rows were only clickable on their text.** The empty space to the
  right of a truncated name was dead, which is most of the row's width in a
  narrow panel. The whole row is a target now.

- **Truncated names had no way to read them in full.** A stash message or a
  long branch name is cut off at exactly the part that identifies it. Hovering
  a branch, tag or stash now shows the full name, plus its upstream, worktree
  or date.

- **Compare and conflict panes centred their text.** A two-axis `ScrollView`
  centres content smaller than its viewport, and only the vertical case had
  been fixed — so any file whose longest line was narrower than the pane had
  its text floating in the middle of the column instead of starting at the
  left edge. Both axes are pinned now.

- **The conflict resolver's three panes could end up different widths.** The
  `HStack` divided the row by what each pane's content wanted, so a side with
  long lines claimed more room than the others — and three columns of
  different widths cannot be read across. They are explicit thirds now, the
  same way the compare view splits its two.

- **⌘= / ⌘- / ⌘0 didn't reach the compare or conflict windows.** Two separate
  causes. The compare windows read the zoom level once, when the window was
  built, so they stayed at whatever size they opened with while the main
  window rescaled around them. The conflict resolver never applied the setting
  at all and always rendered at 12pt. Every window now follows the setting
  live.

  **⌘+ works too.** On a US layout ⌘+ is physically ⇧⌘=, which the menu's ⌘=
  shortcut does not match — so the key combination most people reach for did
  nothing at all.

- **The conflict resolver's panes floated their content in mid-air.** A
  two-axis `ScrollView` centres content smaller than its viewport, unlike a
  single-axis one, so a short file's lines sat halfway down the OURS / BASE /
  THEIRS panes as though the view had scrolled somewhere odd. They pin to the
  top now, the same fix the compare view's split panes already carried.

- **An empty merged result looked like a broken pane.** Taking "Neither" on a
  file that is nothing but one conflict block legitimately leaves nothing
  behind — but a blank pane says nothing about whether that was the outcome or
  a failure. The MERGED header now reports the result's line count, and an
  empty result says so in the pane itself.

- **The conflict resolver offered "Abort Merge", which belongs to the whole
  repository rather than to one file.** Aborting undoes the entire merge
  across every conflicted file — so a button doing that, sat in a row with
  per-file actions, read like "cancel out of this dialog" right up until it
  wasn't. It also ran `git merge --abort` regardless of what caused the
  conflict, which fails outright during a rebase or cherry-pick, and the
  error was discarded so the window closed as though it had worked.

  It is gone from the resolver. Aborting lives on the "in progress" banner in
  the main window, next to Continue, which already detected the right
  operation and surfaced failures. In its place the resolver has **Close
  Without Saving**: leave the conflict exactly as it is and come back later.
  Nothing in the window writes to disk before Save & Stage, so that is always
  safe; it asks first only when there are resolutions to lose, and Escape and
  the header's Close go through the same check.

- **Resizing the main window snapped it back to its old size.** The window
  restorer tells a user resize apart from SwiftUI's own placement by checking
  whether a mouse button is held. That test can never pass for a resize:
  AppKit collapses any frame change that alters the size into `didResize`
  alone — it posts no `didMove`, however far the origin travels — so the only
  signal left was `didEndLiveResize`, which arrives after the button is
  already up. Every resize therefore read as SwiftUI's placement and was
  reverted, up to the restorer's five-correction budget, which is why it
  stopped happening after a few tries and looked intermittent. A live resize
  is now recognised from `willStartLiveResize`, which only ever comes from
  the user and lands before the frame changes. Maximising with the green zoom
  button is also recorded now — it posts `didResize` on its own, so it went
  unsaved and reopened at the previous, smaller size.

- **Branches panel kept a stale ahead/behind count.** Every operation that
  moves the branch tip — commit, amend, fixup, merge, fast-forward, rebase,
  autosquash, squash, reset, cherry-pick, revert — changes its ahead/behind
  vs. upstream, but the panel reloaded from the cached branch list and kept
  showing the pre-operation count until the next unrelated interaction. All
  of them now invalidate the branch list *and* bypass the on-disk snapshot,
  so the count updates immediately. Adding a worktree with a new branch
  likewise makes the branch appear at once.
- **Commands failed when the app was launched from Finder or Xcode.** A
  `.app` inherits only the bare macOS `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`),
  without the Homebrew/MacPorts directories. git itself is resolved by
  absolute path, but the hooks git spawns are not — the Git LFS
  `post-checkout` hook does `command -v git-lfs || exit 2`, so on an LFS
  repository checkout and other hook-running commands reported failure even
  though they had succeeded. The common package-manager bin directories are
  now appended to the subprocess `PATH` (appended, so a user's own `PATH`
  still wins).
- **Staging a hunk/line failed on files with no trailing newline.** When a
  file's last line had no newline, git's "\ No newline at end of file"
  marker was dropped while parsing the diff and never written back into the
  patch, so `git apply --cached` rejected it ("patch does not apply"). The
  marker is now preserved through parse → patch, so Stage/Unstage/Discard
  Hunk works on such files. Per-line staging across the newline boundary is
  also handled: staging an appended line now pulls in the newline-adding
  change it depends on, instead of producing an inconsistent patch that git
  rejected (or, on some git versions, silently glued two lines together).
- **Diff panel went stale after staging/unstaging.** Stage/Unstage/Discard —
  whether by file, hunk, line, or selection — now refresh the diff. The
  on-screen compare mode reloads immediately, and the other two modes
  (HEAD↔Index / Index↔Working / HEAD↔Working) are purged from both cache
  layers so switching to them re-runs the diff fresh instead of serving the
  pre-change disk snapshot. Previously you had to toggle modes to force a
  refresh, and the stale hunks also caused a follow-up line action to build
  its patch against state that had already moved — which git rejected
  ("patch does not apply"), e.g. staging line 7 right after line 6.

### Changed
- **Release version is now 26.11.01 (261101).** Version constants live in
  Swift and `make_version.sh` syncs the plist and Xcode build settings.
  Packaging syncs automatically, and CI checks for stale metadata.

- **The compare window has no Edit mode any more, and edits a block at a
  time.** The tick-box is gone. Click a WORKING line and the whole block it
  belongs to — the run of rows the aligner grouped as one change — opens for
  typing where it sits, caret on the line clicked, with the diff around it
  exactly where it was. HEAD is never editable: it is a committed revision,
  and there is nothing there to write to. A file that is missing from the
  working tree or isn't UTF-8 text can't be typed into at all, and the pane
  says so rather than offering an editor that could not save.

  A block, rather than a line, because a block is what the window is already
  showing, and because it is the smallest unit in which adding and removing
  lines is ordinary typing: inside a block's own text Return and Backspace
  mean what they mean anywhere else. Only the block changes height, and the
  pane across the divider is padded by the difference, so the two columns stay
  row-for-row and the panes stay scrolled together while lines are added under
  the caret. A block that exists only on the HEAD side — a deletion — is a
  place to type rather than lines to replace, which is how a deleted line is
  put back.

  Clearing a block deletes its lines rather than leaving a blank one behind,
  and Backspace in a block with nothing left in it takes the block out and
  carries on at the end of the block above — the move a text editor makes when
  Backspace runs out of line, and the only way to say "these lines go". The
  cost is that a block cannot be edited into a single blank line, which is not
  a thing anyone has wanted a block to become.

  Typing re-colours nothing and moves nothing outside the block. Drafts are
  held against the diff on screen, drawn plain with an amber gutter, and Save
  applies them all at once and re-runs the compare — that is when line numbers
  move and colour comes back. The status line counts what is waiting:
  "2 blocks edited, +3 lines · unsaved".

  Escape steps out one level at a time: the first press leaves the block
  editor and keeps what was typed, the next closes the window. It used to do
  both at once, because three separate things take Escape before a view in one
  of these windows can see it — the window's own key monitor, its `sendEvent`,
  and the main window's app-wide monitor, which closes any key window that
  isn't the main one. That reach is how Escape closes a compare at all, and
  the order local monitors run in is not defined, so none of them could be the
  one to decide: a view now registers a claim on `AppState` and all three ask
  it first. Throwing a draft away is "Discard Block Edit" on the row menu, or
  Revert Edits for the lot; a key that both exits and destroys is a key people
  stop pressing.

  What this replaces was a diff that re-aligned on every committed keystroke,
  and the machinery needed to survive that: line numbers re-derived after each
  commit, a shift count for multi-line pastes, a caret parked for the next
  rebuild, and Return-to-open-the-next-line, Backspace-to-join-the-previous
  and Insert/Delete Line reimplemented by hand because a per-line field cannot
  express them. None of it is needed once the unit being edited is the one the
  view already draws.

- **Refresh leads the toolbar now, and a gear closes it.** Refresh is the one
  button in the row that only re-reads — everything between it and the end
  changes the repository — so it sits ahead of Pull rather than trailing
  Rebase, where it read as the last of the branch operations. The far end is
  Settings, opening the same sheet as the app menu's "Settings…", which until
  now was reachable only from that menu or ⌘,. The shortcut stays bound in
  the menu alone: the button repeats the menu item rather than competing with
  it for the key.

- **The intra-line change highlight is a darker patch instead of a pale
  wash.** It used to be a light tint of the add/delete colour, which forced
  the text on top to white to stay legible — and white is the one colour
  syntax highlighting can't use, so every keyword and string inside an edited
  region would have lost its colour exactly where you're looking hardest. The
  patch is now dark and saturated: same "this bit changed" signal, foreground
  left free. A whole-line deletion also stops drawing the patch across its
  entire text, which insertions never did — on a line that is wholly gone,
  every character changed, so it said nothing the row tint didn't.

- **File Compare opens in its own window, sized to the display.** It was a
  sheet: window-modal, singleton, and pinned to 1100x720 — so it blocked the
  repo behind it, only one file could be compared at a time, and long source
  lines were truncated on a display with room to spare. Compares are now
  ordinary windows that open at ~92% of the screen, cascade so consecutive
  opens stay separable, and can be moved to another display or left open
  while you keep working. Opening a file that is already being compared
  raises its window instead of opening a second copy. Applies to all three
  entry points: the Files panel, the commit dialog, and the Log window's
  commit compare.

- **Dropped the "HEAD ↔ Working" compare mode.** The diff toolbar now offers
  just HEAD↔Index (staged) and Index↔Working (unstaged), matching SmartGit.
  The combined view was read-only — staging a line/hunk from it is ambiguous
  — which only confused users about why "Stage Line" was disabled. Both
  remaining modes support staging.

- **File Compare: the two panes scroll as one.** With "Wrap" off, HEAD and
  WORKING are separate scrollable panes (no more per-line scrollbars or "…"
  truncation) — and dragging either one now moves the other with it, on both
  axes, so a line stays level with its counterpart and scrolling out to read
  a long line shows the same columns on both sides. Previously only ⌘J / ⌘K
  change-jumping moved the panes together; scrolling by hand drifted them
  apart, which defeated the point of a side-by-side view. SwiftUI exposes no
  scroll offset on macOS 14, so the panes are synchronised through the
  `NSScrollView` backing each one.
- **File Compare: Beyond Compare-style line alignment.** A modified
  line now renders as a single row with the old text on the left
  (red) and the new text on the right (green) at the same Y, instead
  of as two rows (removed, then added). Lines that match across HEAD
  and WORKING stay vertically aligned across the divider.

### Added
- **The window reopens where you left it.** Position and size are saved as you
  move and resize, and restored on the next launch — on the *same display* in a
  multi-monitor setup, matched by display ID and falling back to screen
  geometry when macOS renumbers displays after a reboot or re-plug. If that
  display is gone (undocked, monitor unplugged) the window keeps its size and
  centres on the primary screen instead of reopening off-screen where you
  can't reach it. A frame saved on a large monitor shrinks to fit a smaller
  one, and a window left hanging over an edge slides back into view. Dragging
  to another display is written out synchronously, so the new position survives
  even a force-quit rather than only a clean exit. A window left in full screen
  keeps its last windowed frame instead of reopening as a display-sized window.
- **Closing the window quits SmallGit.** The red close button now quits rather
  than leaving the app running window-less in the Dock. Turn it off with
  Settings → Interface → "Closing the window quits SmallGit". Closing a
  secondary window (Log, Resolve Conflict) never quits; closing the main window
  does, even with those open. The window frame is saved before the app exits.
- **Clean Up.** Right-click a repo → "Clean Up…" shrinks the repository
  and drops dead bookkeeping: `git remote prune` on every remote
  (removes remote-tracking refs whose upstream branch is gone),
  `git worktree prune`, then `git gc --prune=now` to repack and delete
  unreachable objects. Objects reachable from any branch, tag, or
  reflog entry survive, so Undo/reflog recovery still works. Reports
  the object-database size before → after in a toast.
- **Partial stash + --keep-index.** Right-click files in the Files table →
  "Stash Selected…" stashes only those files (`git stash push -- <paths>`),
  leaving every other change in the working tree; renames expand to old +
  new path so the move stashes as one unit, and "Include untracked" is
  pre-checked when the selection contains untracked files (git otherwise
  skips them silently). The Save Stash dialog also gained a "Keep staged
  changes in the index" toggle (`--keep-index`) — stash the noise, keep
  what you're about to commit.
- **Worktrees.** Repository menu → "Worktrees…" (⌘⇧T) or right-click a
  repo → "Worktrees…". Lists every linked working tree with its branch,
  HEAD and main/locked/prunable badges. Add a worktree by creating a new
  branch (optional start point) or checking out an existing one — the
  branch picker only offers branches not already checked out elsewhere,
  since git refuses those. Remove (with confirmation; git still refuses
  to delete dirty worktrees), Prune stale bookkeeping, Reveal in Finder,
  and "Open as Repository" — which registers the worktree in the sidebar
  next to its parent so you can switch into it like any other repo.
- **One-click Undo.** Repository menu → "Undo Last Operation…" (⌥⌘Z)
  reads the reflog and reverses the last operation with the safest
  matching inverse: single-commit ops (commit, amend, cherry-pick,
  revert) reset to `HEAD@{1}`; merges, rebases, pulls and resets go back
  to `ORIG_HEAD` (so a whole rebase unwinds in one step); a checkout is
  undone by checking the previous ref back out. History moves use
  `git reset --keep`, which keeps uncommitted changes and aborts rather
  than overwrite them. A confirmation spells out exactly what will run,
  and the undone state stays reachable from the reflog browser.
- **Fixup workflow.** Right-click a commit in the Journal →
  "Commit Staged as Fixup of <hash>" commits the staged changes as
  `fixup! <target>` (`git commit --fixup`); later, "Autosquash Fixups
  from Here" runs `git rebase -i --autosquash` from that commit's parent,
  folding every fixup into its target with no editor and no prompts.
  Conflicts pause into the standard continue/abort banner. Offered only
  on HEAD's own log, since both actions rewrite/extend HEAD.
- **Journal: whole-history search.** The filter field gained a scope menu
  (funnel icon): "Filter (loaded)" keeps the classic live filter over the
  loaded pages, while Message (`--grep`), Author (`--author`), Content
  (`-S`, pickaxe — "when did this string appear/disappear") and Content
  regex (`-G`) run a real git search across the *entire* history on ⏎.
  Results replace the journal list under a banner showing the query and
  hit count, with one click back to the loaded log. Searches respect a
  pinned branch log; range squash is disabled while results are showing
  (adjacent hits are rarely adjacent in history).
- **Journal: multi-select + range squash.** Cmd-click toggles commits in
  and out of the selection; shift-click extends a range from the last
  click. Right-click a contiguous run of two or more selected commits →
  "Squash N Commits…" opens a dialog pre-filled with every selected
  commit's message stacked oldest-first, editable, with a "Select" menu to
  drop any single commit's message in and an authorship dropdown to pick
  which commit's identity + date the result inherits. Confirming folds the
  range into one commit (via interactive rebase) and replays any newer
  commits on top. Offered only on HEAD's own log, not a pinned branch's.
- **File Compare: line inspector panel.** Click any diff row to open
  a bottom panel that shows that line's full HEAD and WORKING text,
  wrapped to the dialog width with the same word-diff tinting from
  the main view. Lets you read a long line without dragging
  horizontally. Click the ✕ on the panel (or another row) to dismiss.
- **Interactive rebase UI.** Right-click any branch → "Rebase Interactively
  onto Here…" opens a planner sheet listing every commit between that
  branch and HEAD. Drag rows to reorder; per-row picker chooses
  pick / squash / fixup / drop. Conflicts route into the existing
  four-pane conflict resolver. Reword and edit are not yet supported.
- **Reflog browser.** Repository menu → "Browse Reflog…" (⌘⇧G) or
  right-click any repo → "Browse Reflog…". Shows every move HEAD has
  made — commits, checkouts, resets, rebases, merges — with action
  bucketing, a filter box, and a Reset-HEAD-to-Selected submenu
  (Soft / Mixed / Hard) for recovery. Hard reset prompts a
  confirmation that reminds you the reflog itself remains, so the
  operation stays reversible from the previous entry.

### Planned
- Cherry-pick UI
- Worktrees panel
- Bisect wizard
- Reword / edit actions in interactive rebase
- GPG signed commits
- Git LFS surface
- PR integration (GitHub / GitLab)

## 0.1.0 - 2026-05-24

Initial development baseline, before the public history reset.

### Added
- Repository discovery, clone, init, grouping, SmartGit config import
- Branches: create, switch, rename, delete, upstream tracking
- File status v2 with stage / unstage by file, hunk, or line
- Commit, push, pull, fetch with branch picker
- Merge with built-in four-pane conflict resolver
- Rebase (basic), stash (save / pop / apply / drop)
- Side-by-side and three-way diff (HEAD&harr;Index, Index&harr;Working, HEAD&harr;Working)
- Double-click to stage / unstage lines
- Ignore-whitespace toggle
- Journal / log view with commit graph layout and pagination
- Blame, tags, remote management, submodule detection
- FSEvents-driven cache invalidation across a three-layer cache
- External editor / diff tool integration
- Double-tap to open the output log window

### Tested
- 29 test files (~2.8k LOC) covering parsers, cache, staging, conflicts, rebase

[Unreleased]: https://github.com/vubaone/SmallGit/commits/main
