# SmallGit Release Checklist

This file tracks public-safe release work. Keep private account details,
local reflog notes, certificates, passwords, and unpublished history out of
the repository.

## Standard command

Use `./release.sh --check` for a read-only readiness check. Use `./release.sh` to
run the release checks, build/verify/package the app, upload a GitHub draft and
verify its remote assets. Use `--publish` to publish after that verification, or
`--local` to validate without uploading. See [docs/releasing.md](docs/releasing.md).

## Before First Public Push

- Publish only the reviewed source snapshot and intended branch:
  `git push -u origin main`.
- Do not use `git push --mirror` for the first public push.
- Do not push tags until you have checked `git tag --list` and confirmed
  every tag is intended for the public repository.
- If this repository was rewritten locally, clean local-only history before
  publishing from the same clone, or publish from a fresh clone of the final
  branch.
- Keep private transcripts and recovery backups out of the published tree.
  The ignored `.private/` directory is local-only; do not upload the workspace
  itself as a source archive. Export tracked files with `git archive` instead.

## Repository Settings

- Default branch: `main`.
- Disable wikis if project docs stay in-tree.
- Enable Discussions if `.github/ISSUE_TEMPLATE/config.yml` links to them.
- Add branch protection for `main` requiring PR review and CI.

## Versioning

- The source is `AppVersion` in `SmallGit/Sources/SmallGit/Models/AppConfig.swift`.
- Run `./make_version.sh` to sync the marketing version and build number into
  `SmallGit/Info.plist`, `SmallGit/project.yml`, and any generated Xcode project.
- Run `./make_version.sh --check` before handing off a build. See
  [MAKE_VERSION_GUIDE.MD](MAKE_VERSION_GUIDE.MD).
- Build and packaging scripts sync automatically; verify the packaged bundle
  contains the expected `CFBundleShortVersionString` and `CFBundleVersion`.
- Avoid repeating the current app version in README prose.
- Changelog headings may contain historical release versions.

## Screenshots

- Capture screenshots from neutral fixture repositories, not private client
  repositories.
- Check sidebars, paths, recent-file lists, commit authors, and branch names
  before committing screenshots.
- Save README images under `screens/`.

## Distribution

- Source builds work with `cd SmallGit && swift run SmallGit`.
- Local app bundles work with `SmallGit/scripts/build-app.sh`.
- Public DMGs should be signed and notarized before release.
- Notarization credentials belong in GitHub secrets, never in this repo.
- Verify `LICENSE` and `THIRD_PARTY_NOTICES.txt` are included in the app's
  `Contents/Resources/` directory.

## Final Checks

- `SmallGit/scripts/test-release.sh` passes without opening desktop windows.
- Run the remaining native-window tests on a dedicated runner when required;
  do not run unfiltered `swift test` on the primary Mac.
- `swift build -c release` passes from `SmallGit/`.
- Secret scan finds no tokens, private keys, certificates, or private local paths.
- `git status --short` contains only intentional changes.
