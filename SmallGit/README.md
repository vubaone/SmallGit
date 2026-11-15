# SmallGit (Swift package)

This is the buildable Swift package for SmallGit. The repository root
holds the project-level docs:

- [../README.md](../README.md) — project overview, screenshots, status
- [../ARCHITECTURE.md](../ARCHITECTURE.md) — how the code is laid out
- [../CONTRIBUTING.md](../CONTRIBUTING.md) — how to submit PRs
- [../CHANGELOG.md](../CHANGELOG.md) — release notes

The rest of this file is the build / run / test reference.

---

Native macOS Git client in Swift / SwiftUI, intended as an open-source
replacement for SmartGit workflows. One runtime SPM dependency (Yams).
Targets macOS 14+. ViewInspector is a separate, test-only dependency.

## Build & run

Development run (debug, fast iteration):

```sh
swift run SmallGit
```

The binary embeds an Info.plist via linker flags, so macOS treats it as
a proper app even when launched directly from the SwiftPM build directory
(correct Dock identification, window focus, bundle identifier).

## App icon

A maintainer-supplied icon ships at `Resources/AppIcon.icns` and is
copied into the `.app` bundle's Contents/Resources. To regenerate after
design tweaks:

```sh
scripts/generate-icon.sh
```

The script reads the tracked master at `../resources/icon.png`, uses `sips`
to create the multi-resolution iconset, then `iconutil` to compile `.icns`.
See [icon provenance and license](../resources/README.md).

## Xcode signing

Generate a project without opening Xcode:

```sh
scripts/xcode.sh --no-open
DEVELOPMENT_TEAM=YOUR_TEAM_ID scripts/xcode.sh --no-open
```

The shared `project.yml` contains an environment placeholder for the signing
team. The actual value is written only to the ignored generated `.xcodeproj`.
A team selected there survives regeneration, including `--force`.
Use `DEVELOPMENT_TEAM='' scripts/xcode.sh --no-open` to clear the local team.

## Package as a `.app` bundle

```sh
scripts/build-app.sh            # optimized, stripped release (the default)
scripts/build-app.sh --release  # explicit release build
scripts/build-app.sh --debug    # packaged debug build with symbols
scripts/build-app.sh --open     # build then open the bundle
```

Output: `release/SmallGit.app` at the **repo root**, not inside this
package — a single obvious place to grab a build for review. See
[../release/README.md](../release/README.md). Ad-hoc signed for local use;
for distribution use `../release.sh`, which requires Developer ID signing,
Apple notarization, a stapled ticket and Gatekeeper verification.
For a signed local build, use `../release.sh --local --notarize`.

The app's `Contents/Resources/` includes the project license and
`THIRD_PARTY_NOTICES.txt` for its dependencies.

For a complete GitHub release, run `../release.sh` (draft),
`../release.sh --publish` (new published release), or `../release.sh --local`
(test/build/package without uploading). See [Release workflow](../docs/releasing.md).

Update the `AppVersion` constants in `Sources/SmallGit/Models/AppConfig.swift`,
then run `../make_version.sh`. The script syncs both version fields in
`Info.plist` and the Xcode build settings. Packaging runs it automatically;
`build-dmg.sh` reads the synced plist for its filename.
See [Versioning](../MAKE_VERSION_GUIDE.MD).

## Package as a release `.dmg`

```sh
scripts/build-dmg.sh              # release app + release/SmallGit-<version>.dmg
scripts/build-dmg.sh --skip-build # reuse release/SmallGit.app
scripts/build-dmg.sh --open       # build then open the disk image
```

For distribution signing, pass `--sign` and set
`SIGN_IDENTITY="Developer ID Application: <name>"`. Notarization is a
separate release step after the DMG is created.

### Why does macOS keep asking for Desktop / Documents access?

That's macOS TCC re-prompting because ad-hoc codesigning ties
permissions to the binary's **cdhash**, which changes on every
rebuild. The fix is a stable self-signed code-signing certificate:

```sh
scripts/create-dev-cert.sh       # one-time setup
scripts/build-app.sh --open      # picks the cert up automatically
```

After this, the first build prompts for keychain access once
("codesign wants to use your private key" — click **Always Allow**)
and TCC grants persist across rebuilds. `build-app.sh` falls back
to ad-hoc with a warning if the cert isn't installed, so the build
still works without it — you'll just keep seeing TCC prompts.

## Tests

Run SwiftUI interaction and render tests without opening the app:

```sh
scripts/test-ui.sh
scripts/test-ui.sh --case ToolbarUITests/testStageAndUnstageButtonsChangeTheRealIndex
```

The suite finds real SwiftUI controls by accessibility ID, triggers their
callbacks in-process, and checks UI state and real Git results. Logs, an
xUnit XML report, environment details, and rendered PNGs are written to
`.build/ui-tests/results/`. It does not request Accessibility permissions
or use XCUITest, mouse events, simulators, or visible windows.

The full suite is still available with `swift test`. It includes native
window-ordering tests, so use a dedicated macOS runner/session when running
it. The generated Xcode project remains a development/debugging workflow;
use the SwiftPM script above for the UI suite's no-desktop guarantee.

The suite includes unit tests (parsers, cache, patch builder, models)
and integration tests that spawn a real `git` process against a temp
repository (FSEvents, hunk staging, line staging, stash flows, branch
rename). Integration tests `XCTSkip` themselves if `git` is not on the
machine.

Coverage, limitations, and contributor examples: [../docs/testing.md](../docs/testing.md).

## Source layout

```
Sources/SmallGit/
  Models/         GitRepository / Branch / FileStatus / Commit / DiffHunk / OutputEntry / AppConfig
  Services/       ProcessRunner, GitService, GitOutputParser, DiffPatchBuilder,
                  FileWatcherService (FSEvents), SmartGitImporter, ConfigService
  Cache/          3-layer cache: MemoryCache (L1), DiskCache (L2),
                  CacheCoordinator, CacheKey, InvalidationEngine
  ViewModels/     AppState (root), FilesVM, BranchesVM, DiffVM, JournalVM,
                  RepositoryListVM, OutputLog
  Views/          MainWindow, ToolbarView, panels (Sidebar/Content/Bottom),
                  context menus, dialogs (Commit/Stash/Branch/Picker/Preferences),
                  Welcome + SmartGit sync
  Utilities/      DateFormatters, StringExtensions
```

Every git invocation routes through `ProcessRunner` (actor). Every UI
read routes through `CacheCoordinator.get` (read-through L1 -> L2 -> L3
with surgical post-action invalidation). Views never call `GitService`
directly.
