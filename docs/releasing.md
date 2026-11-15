# Release SmallGit with one command

From the repository root:

```sh
./release.sh
```

This runs the release checks, builds the optimized app with Developer ID, notarizes it with Apple,
staples the ticket, verifies Gatekeeper, and packages a ZIP, and creates a **draft GitHub Release** with the ZIP, checksum, and build
manifest attached. It uses the existing `gh` login and the repository configured
as `origin`. It never opens an application window or browser.

To publish a **new** release automatically after upload verification:

```sh
./release.sh --publish
```

For a quick readiness check before running the full pipeline:

```sh
./release.sh --check
```

This checks the clean/pushed checkout, version, required tools, GitHub access,
existing releases/tags, a valid Developer ID identity, and access to the stored
notarytool profile. It does not build, submit an app, or change anything on
GitHub. A successful check cannot guarantee a later network request will succeed;
the same checks run again during the actual release.

To exercise the entire local workflow without creating a release or uploading:

```sh
./release.sh --local
```

Local mode also accepts uncommitted changes, marks the manifest `dirty: true`,
and does not need `gh` or query remote refs. SwiftPM may still download dependencies
if they are not cached. This is the mode to use while developing the release tooling.
To test Apple signing/notarization without a GitHub upload, use
`./release.sh --local --notarize`. This sends the app to Apple.

## Before a release

1. Set the intended marketing version and build number in `AppVersion` as described
   in [MAKE_VERSION_GUIDE.MD](../MAKE_VERSION_GUIDE.MD). Run `./make_version.sh`.
   The release command checks the values; it never chooses a new version for you.
2. Commit the intended source and push its branch to `origin` normally. Upload
   modes require a clean checkout and exact equality between HEAD and that remote
   branch, so GitHub receives the same source that was tested and built.
3. Have macOS 14+, the Swift/Xcode command-line toolchain, Python 3.9+, and Git.
   Upload modes also need [GitHub CLI](https://cli.github.com/) authenticated for
   the repository. Use `gh auth status` to diagnose access issues.
4. Set up a Developer ID Application identity and stored notarytool profile as
   described below. Every GitHub release requires notarization.

The command works from any directory when invoked by its absolute path. Run
`./release.sh --help` for options. Optional custom notes:

```sh
./release.sh --notes path/to/release-notes.md
```

Without `--notes`, GitHub generates change notes and the script adds build details.
Custom notes replace generated change notes, while retaining those build details.

## What runs

1. Check tools, version synchronization, source state, remote branch, release/tag
   conflicts, and repository access. It checks every page of releases, including
   drafts visible to the authenticated account. HTTP errors stop the workflow.
2. Run `SmallGit/scripts/test-release.sh`: Python release-tooling tests, a named
   allowlist of core regressions, then `SmallGit/scripts/test-ui.sh`.
3. Run `SmallGit/scripts/build-app.sh --release`.
4. Check bundle version/build, project/dependency licenses, stripped executable,
   absence of `.dSYM` and embedded `__DWARF`, personal build paths, unexpected
   bundle files/symlinks, code signature, and architecture. Verify Hardened Runtime,
   secure timestamps, signing team and absence of debug entitlements.
5. Submit to Apple and require `Accepted` with a matching submission ID and archive
   SHA-256 in Apple's log. Staple the ticket; validate it and assess Gatekeeper.
6. ZIP **only** `SmallGit.app`; verify archive contents and CRCs, write SHA-256
   and a JSON manifest containing commit/version/build/architecture/signing and
   notarization details. Extract the ZIP and verify its ticket and Gatekeeper again.
7. Recheck source and remote state, then use `gh release create --draft` with the
   exact commit SHA and tag `v<marketing-version>`.
8. Verify the draft's target commit and its exact asset list, upload states,
   sizes and SHA-256 digests. If GitHub omits an asset digest, download that asset
   into a temporary project directory and compare its contents with the local
   file. The default leaves this verified release as a draft.
9. With `--publish`, recheck the source and remote refs, publish that draft, then
   verify the published release, assets and actual tag commit again. Report
   success only after these checks pass.

The core test allowlist covers repository addition, file refresh during actions,
Git failures/credentials, GitHub CLI auth, credential submission, repository
layouts, and terminal behavior. The separate UI suite drives real controls in
process. This is not the full suite of native-window tests; those remain on a
dedicated macOS runner. See [Testing](testing.md).

## Artifacts and logs

| File | Purpose |
| --- | --- |
| `release/SmallGit.app` | Optimized, stripped app bundle |
| `release/SmallGit-<version>-macos-<arch>.zip` | Downloadable app; arch comes from the executable |
| Same ZIP filename plus `.sha256` | SHA-256 checksum |
| `release/SmallGit-<version>-macos-<arch>.json` | Build provenance and verification summary |
| `SmallGit/.build/release-workflow/` | Local workflow lock, logs, notes, temporary ZIP |
| `SmallGit/.build/release-workflow/notary/` | Private Apple submission response and notarization log |
| `SmallGit/.build/release-tests/` | Core test logs and XML results |
| `SmallGit/.build/ui-tests/results/` | UI logs, XML results, component snapshots |

Only the three versioned ZIP/checksum/manifest files are uploaded. `.private/`,
working transcripts, caches, test fixtures, and logs stay local. The script does
not create DMGs; use the existing DMG tooling only when one is explicitly requested.

## Existing releases and interrupted uploads

The workflow never overwrites a release or reassigns a tag to another commit.
If the version already has a draft or published release, it stops before building.
For a new release, choose a new marketing version and build number, sync, commit,
and push before rerunning.

To publish a **previously reviewed draft** without rebuilding or changing assets,
first inspect it, then explicitly publish it with GitHub CLI (replace placeholders):

```sh
gh release view TAG --repo OWNER/REPO
gh release edit TAG --repo OWNER/REPO --draft=false
```

An upload failure may leave a partial draft on GitHub. Inspect its assets before
publishing or deciding to remove that draft and retry. Verification failures
stop automatic publication. If an error happens during or after publication,
inspect GitHub: the release may already be published even if the final check
failed. The script retains local assets and never automatically deletes a release
or uses `--clobber`.

## README and discovery metadata

The English `README.md`, attribution text and referenced images are ordinary
version-controlled files. Finish and commit documentation changes before running
the upload modes; the script does not rewrite marketing copy during a release.
`README.vi.md` is the Vietnamese review copy. Repository description, homepage
and topics are GitHub settings, separate from release assets; the release script
does not synchronize them. The agreed discovery topics are already configured
on the upstream repository.

## Signing and publication

Every GitHub upload requires a **Developer ID Application** certificate with its
private key in the login Keychain, plus Apple notarization credentials stored by
`xcrun notarytool store-credentials`. Reuse a working Keychain profile when one
already exists; do not export keys or copy passwords into the repository.

The workflow automatically selects the certificate only when exactly one valid
Developer ID identity is available. Use `SIGN_IDENTITY` to select its SHA-1 or
full name when there are several. `Apple Development`, `Apple Distribution`,
self-signed and ad-hoc identities do not satisfy this gate. The workflow enables
Hardened Runtime and secure timestamping when building for notarization.

Profile precedence is `--notary-profile NAME`, `NOTARY_KEYCHAIN_PROFILE`, ignored
local config, then the default profile name `SmallGit`. For a reusable local setup,
create `.private/release-config.json` with **labels only**:

```json
{"notary_profile": "YOUR_EXISTING_PROFILE"}
```

An optional `sign_identity` label selects a certificate; `SIGN_IDENTITY` overrides
it. Never store passwords, API keys or private keys in this file. With these labels
configured, `./release.sh --publish` handles the complete release.

Apple acceptance is checked against the exact submitted archive and its log.
The manifest includes the submission ID, acceptance, staple and Gatekeeper results,
not the Keychain profile or credentials. If Apple is still processing after the
wait timeout, keep the local files and resume that submission with
`xcrun notarytool wait SUBMISSION_ID --keychain-profile PROFILE`. Inspect its log
before continuing; do not blindly resubmit. Upload and publication stop on any
notarization, signature, ticket or Gatekeeper failure.

`./release.sh --local` keeps local development builds available without Apple
credentials. Add `--notarize` to exercise the full signing flow locally. Standalone
`build-app.sh` builds are not automatically notarized. The ZIP release flow does
not create or notarize DMGs.

Creating or publishing a release does not change repository visibility. A private
repository remains private. No release command commits, pushes source, force-pushes,
opens the app, or changes the version automatically.
