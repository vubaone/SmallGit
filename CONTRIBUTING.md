# Contributing to SmallGit

Thanks for your interest in SmallGit. This document explains how the project
is run, how to build it, and how to submit changes.

## Who works on this

SmallGit is currently maintained by:

- **VUBA** &mdash; `dev@vuba.one` &mdash; primary maintainer
- **Anthropic Claude** &mdash; AI collaborator (architecture, refactors, tests)
- **OpenAI Codex** &mdash; AI collaborator (feature work, parsers, UI)

We treat human and AI contributions equally: the bar is correctness, tests,
and a clear "why" in the commit message. AI-assisted PRs are welcome but the
human submitter is the one accountable for the change — please read what you
ship, run the tests, and confirm it does what you intend.

## Ground rules

1. **One concern per PR.** Refactor or feature, not both.
2. **Tests required for behavior changes.** Unit tests for parsers / cache /
   diff math. Integration tests (spawning a real `git`) for anything that
   touches the working tree, index, or refs.
3. **Avoid force-unwraps, `try!`, and `fatalError`.** Handle input and runtime
   failures explicitly. Any exception for a fixed invariant needs a clear reason.
4. **Stay platform-honest.** If your change adds AppKit / CoreServices /
   FSEvents usage, route it through a platform protocol (see
   `Services/PlatformServices.swift`) rather than `#if os(macOS)`
   scattered across views.
5. **Don't break strict concurrency.** The package builds with
   `StrictConcurrency` enabled. New types crossing actor boundaries need to
   be `Sendable`.

## Building

```sh
cd SmallGit
swift build           # compile
swift run SmallGit    # launch the dev binary
scripts/test-ui.sh    # UI interactions + rendering without opening windows
swift test           # full suite; includes native window-ordering tests
```

Full build / signing / icon docs: [SmallGit/README.md](SmallGit/README.md).
Use a dedicated macOS runner/session for the full suite. See
[Testing](docs/testing.md) for the suite that can run while you work on
your main desktop, its stable button IDs, and how to add UI coverage.

If `swift test` reports `XCTSkip: git not available`, install Git (e.g.
`brew install git`) and re-run.

## Coding style

- Swift 5.10, four-space indentation, no trailing whitespace.
- One type per file when the file would otherwise exceed ~400 lines.
- Public-facing types get a one-line doc comment; internal helpers usually
  don't need any.
- Group view-model state under `// MARK:` sections by feature, not by access
  level.
- View files: keep `body` short. If a subview hits ~30 lines, lift it out.

The repository ships an [`.editorconfig`](.editorconfig) (universal) and a
[`.swiftformat`](.swiftformat) config (optional but recommended). To format
before pushing:

```sh
brew install swiftformat   # one-time
swiftformat .              # formats in place per the project config
```

CI doesn't enforce swiftformat yet — the config exists so contributors who
opt in produce diffs that match the project style, and so we can add an
enforcement step later without surprising anyone.

## Architecture rules

- Views must not call `GitService` directly — go through `CacheCoordinator`.
- `GitService` must not import SwiftUI or AppKit.
- `ProcessRunner` is the only place that spawns subprocesses.
- Cache invalidation is centralized in `InvalidationEngine`; new mutating
  operations declare which keys they invalidate, not which views to refresh.

See [ARCHITECTURE.md](ARCHITECTURE.md) for a two-page tour, and
[docs/architecture/](docs/architecture/) for the full design specs.

## Submitting a pull request

1. Fork and create a topic branch (`git checkout -b feature/cherry-pick-ui`).
2. Make your change. Add tests.
3. Run `SmallGit/scripts/test-ui.sh` for UI changes, and relevant unit and
   integration tests. Run the full suite on a dedicated macOS runner/session.
4. Open a PR against `main`. Fill in the PR template.
5. CI currently runs manually via **Actions → CI → Run workflow**. It has
   separate general-test, UI-test, and release-build jobs. The UI job uploads
   XML results, logs, and rendered PNGs, including on failure. Automatic
   push/PR runs remain disabled until maintainers choose to enable them.
6. Maintainers will review within a week. Be patient — this is a side
   project for everyone involved.

## Reporting bugs

Use the **Bug report** issue template. Include the SmallGit version, macOS
version, the exact git version (`git --version`), and the steps to reproduce
on a small temporary repository. Include the commands needed to create it;
use fictional filenames, authors, and remotes instead of private project data.
The automated suites create their own fixtures; see [Testing](docs/testing.md).

## Proposing features

Use the **Feature request** issue template. For anything bigger than a small
UI tweak, please open an issue *before* you start coding — alignment first
saves rework later. Linking the proposal to the relevant SmartGit feature
helps frame the scope.

## Security

If you find a security issue (e.g. a path the app might execute attacker-
controlled shell), please **do not open a public issue**. Email
`dev@vuba.one` directly with reproduction steps. See [SECURITY.md](SECURITY.md)
for what to include and what to omit.

## Releases

Releases are tagged `v<marketing-version>` on `main`, following
[MAKE_VERSION_GUIDE.MD](MAKE_VERSION_GUIDE.MD). Maintainers cut releases — see
`SmallGit/scripts/build-app.sh` for the packaging flow and
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) for the public release checklist.

## Authorship

When you submit your first pull request, please add your name to the
Contributors section of [AUTHORS](AUTHORS) in the same PR. We track AI
collaborators (Claude, Codex) separately under their own section.

## License

By submitting a contribution you agree that it will be licensed under the
MIT License (the same license as the project — see [LICENSE](LICENSE)).
