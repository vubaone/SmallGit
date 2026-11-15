# Testing SmallGit

For the desktop-free release checks (release-tooling tests, selected core
regressions, and this UI suite), run `SmallGit/scripts/test-release.sh`.
`./release.sh --local` additionally builds and verifies the app and ZIP.
See [Release workflow](releasing.md) for the exact coverage and artifacts.

## Run the UI suite

Requires macOS 14+, an Xcode toolchain with Swift 5.10+, and Git. From the
repository root:

```sh
SmallGit/scripts/test-ui.sh
SmallGit/scripts/test-ui.sh --case RepositoryUITests
SmallGit/scripts/test-ui.sh --case ToolbarUITests/testStageAndUnstageButtonsChangeTheRealIndex
```

`--case` accepts an exact class name and optionally a method name. A filter
matching no tests fails the command. The script propagates build/test
failures and runs one test worker at a time. SwiftPM downloads pinned
dependencies on the first run; the test scenarios themselves use only local
repositories, including a local origin for pull tests.

The target is `SmallGitUITests`, in `SmallGit/Tests/SmallGitUITests/`.
It is an in-process XCTest target, **not an XCUITest application target**.
It does not launch SmallGit, post mouse/keyboard events, show windows,
request Accessibility permissions, or create simulators/VMs. Each fixture
also checks that the test process did not show a window or become active.

The rest of the project still has unit/integration tests and several native
window tests. `swift test` runs all of them and can show windows. Run that
command on a dedicated macOS runner/session. The UI script's anchored target
filter excludes those tests. Use SwiftPM for this suite; running an
app-hosted test target from Xcode is a different execution environment.

## What is exercised

| Area | Assertions |
| --- | --- |
| Repository menu | Actual button callbacks open the correct dialog or call the scripted picker; cancel preserves the active repo |
| Multiple folders | Valid repos are persisted in order, duplicates are skipped, the last new repo becomes active, group destinations are honored |
| Toolbar availability | Repository-dependent buttons are disabled without a repo; invoking a disabled button fails; conflicts cannot be unstaged |
| Stage / unstage | Selected file moves into and out of a real Git index; its working-tree contents remain |
| Refresh | External file changes reach the file list and count |
| Pull | Primary menu action fetches a local origin, preserves untracked work, and exposes rebase conflicts and the operation marker |
| File controls | Text binding filters rows; type buttons hide/show rows while retaining conflicts; ignored and assume-unchanged paths load on demand |
| Status bar | Message, file count, cursor information, and progress visibility |
| GitHub sign-in | Actual button shows the device code; missing CLI leaves an actionable error; cancel stops login; successful auth retries a local fetch only in the original repo |
| Workflow authorization | GitHub's exact missing-scope rejection opens the authorization dialog; approval retries the same push, while cancellation or failed approval does not |
| Rendering | Rename dots retain both colors in light/dark modes; status strips render at compact/wide widths; long diff text cannot spill into the other column |

Existing `FileRefreshDuringActionTests` in `SmallGitTests` additionally cover
file-list freezing during a long action, cancellation, late reads, overlapping
actions, and switching repositories. Those are model/integration tests;
the UI suite checks that real controls reach the intended behavior.

This suite does **not** prove native hit-testing, window focus, drag/drop,
keyboard delivery, actual file-picker behavior, full-window layout, or every
dialog. Those require separate desktop tests on a dedicated macOS environment.
There is no full-app screenshot baseline or percentage-coverage claim.

## How button activation works

Production controls have stable `accessibilityIdentifier` values.
[ViewInspector](https://github.com/nalexn/ViewInspector) is pinned in
`Package.swift` and `Package.resolved`, and linked only to the UI test target.
`UIDriver` looks up the real SwiftUI control and invokes its stored callback;
there is no separate ID-to-handler switch that could drift from the UI.
For a split menu, `primaryAction` invokes its primary callback.

```swift
let fixture = try UIFixture()
defer { fixture.cleanup() }

let first = try await fixture.makeRepo("first")
let last = try await fixture.makeRepo("last")
fixture.platform.folders = [first, last]

let ui = UIDriver(view: RepositoryAddMenu(appState: fixture.app))
try ui.fire("repositories.add")
try await awaitUI("last repo loaded") {
    fixture.app.activeRepo?.path == last.path
        && fixture.app.journalVM.commits.first?.subject == "initial"
}
XCTAssertEqual(fixture.app.allRepositories.map(\.path), [first.path, last.path])
```

Toolbar sections are inspected individually because the inspector does not
flatten the app's nested custom `ToolbarContent`. They are the same sections
used by `ToolbarView.body`, with the same buttons, modifiers, and callbacks.
Model-backed view state is inspected directly. Tests do not mount views to
exercise view-local `@State`, focus, or appearance callbacks. SwiftUI may emit
an unmounted-environment warning when inspection reaches a font modifier;
these inspections use its default value. Render tests supply their rendering
environment explicitly.

### Identifier conventions

Use semantic names, not labels or view indices. Keep existing identifiers
stable when changing copy or layout, and ensure uniqueness within a component.

| Controls | IDs |
| --- | --- |
| Repository menu | `repositories.add`, `repositories.addGroup`, `repositories.clone` |
| Group context button | `repositories.addToGroup.<group name>`; `ungrouped` for Other |
| Toolbar | `toolbar.sidebar`, `toolbar.refresh`, `toolbar.pull`, `toolbar.fetch`, `toolbar.sync`, `toolbar.commit`, `toolbar.stage`, `toolbar.unstage`, `toolbar.discard`, `toolbar.merge`, `toolbar.rebase`, `toolbar.settings` |
| File controls | `files.filter`, `files.showStaged`, `files.showUnstaged`, `files.showUntracked`, `files.showIgnored`, `files.showAssumeUnchanged` |
| Status bar | `status.message`, `status.fileCount`, `status.progress`, `status.cursor` |
| Credentials | `credentials.github`, `credentials.githubCode`, `credentials.copyGitHubCode`, `credentials.openGitHub`, `credentials.githubProgress`, `credentials.githubError`, `credentials.username`, `credentials.password`, `credentials.submit`, `credentials.cancel` |
| GitHub CLI installation | `credentials.installGitHubCLI` opens the embedded terminal and prefills `terminal.input` without executing a command |

An ID being present does not mean its entire workflow has coverage; use the
coverage table above and the test cases as the source of truth.

## Isolation and artifacts

The runner keeps temporary files, Git configuration, build caches, repositories,
and output under `SmallGit/.build/`. `UIFixture` injects its own `ConfigService`,
`DiskCache`, `GitService`, and `UIPlatform`. The Git runner does not load the
user's shell startup files. System/global Git config and hooks are excluded
by the script. Picker answers are scripted, and unexpected Finder, editor,
Terminal, or pasteboard requests fail a test.

Each run replaces the generated `SmallGit/.build/ui-tests/results/` directory:

| Artifact | Purpose |
| --- | --- |
| `test.log` | Build and test output |
| `results.xml` | Native SwiftPM XCTest xUnit report |
| `environment.txt` | macOS, Xcode, Swift, and Git versions for reproduction |
| `snapshots/*.png` | Rendered components for review |

Render assertions compare pixels/regions produced in the same run, or check
dimensions and visible content. PNGs are diagnostic artifacts, not committed
golden files tied to one OS/font renderer. [ImageRenderer](https://developer.apple.com/documentation/swiftui/imagerenderer)
only renders supported SwiftUI drawing content; native windows, tables, and
progress animations are not covered by these PNGs. Progress is checked through
the view hierarchy instead.

Do not commit `.build/`, generated fixtures, logs, or PNG artifacts. Do commit
test sources and dependency lockfile changes.

## Adding a case

1. Add a stable ID to the production control if it has none.
2. Use a small production component or toolbar section as the test subject.
3. Create a `UIFixture`; always `defer { fixture.cleanup() }`.
4. Use `UIDriver.fire`, `primaryAction`, or `element` to interact with the
   control. Assert an observable outcome, including the real index/working
   tree for Git actions, rather than merely checking that a callback ran.
5. Await a specific completion condition with `awaitUI`. Do not use an
   unconditional sleep or assume a newly scheduled task has already started.
6. Run the case, then `SmallGit/scripts/test-ui.sh`.

Never call `ViewHosting.host`, `NSWindow.orderFront`, `makeKeyAndOrderFront`,
application activation, `runModal`, or desktop automation from this target.
ViewInspector's macOS hosting helper creates a visible window. New system
interactions must be injected through `PlatformServices` and answered by the
test double. Use a dedicated environment for tests requiring a real window.

GitHub authentication tests inject a fake service or execute a temporary fake
`gh`. They never sign in, open a browser, read tokens, or change the user's
Git configuration. `GitHubCLIAuthTests` covers command ordering, an existing
login, device-code output, missing CLI, setup failure, cancellation, and timeout.
It also checks workflow scope refresh for an existing login, scoped sign-in
without a login, refresh failure, and cancellation before credential setup.
Live browser approval and Keychain storage remain a manual acceptance check.

## CI

`.github/workflows/ci.yml` contains a separate `ui-tests` job using the same
script, and uploads reports/snapshots even on failure. The general test job
excludes this target so it is not run twice; release packaging depends on
both jobs. CI remains `workflow_dispatch` only, respecting the repository's
existing choice to pause automatic runs. This change does not enable push or
pull-request triggers or publish the repository.
