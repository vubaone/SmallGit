# release/

Build output lands here. This is the one place to look for a freshly built
app — nothing else in the tree needs checking.

| Artifact | Produced by |
|----------|-------------|
| `SmallGit.app` | `SmallGit/scripts/build-app.sh` |
| `SmallGit-<version>-macos-<arch>.zip`, `.zip.sha256`, `.json` | `./release.sh` |
| `SmallGit-<version>.dmg` | `SmallGit/scripts/build-dmg.sh` |

```sh
cd SmallGit
scripts/build-app.sh --open     # build a stripped release, drop it here, launch it
```

Generated artifacts are gitignored — only this file is tracked, so the folder
exists in a fresh clone before anything has been built.

Use `./release.sh` at the repository root for a GitHub draft, `--publish` for
a new published release, or `--local` for checks and packaging without uploading.
See [Release workflow](../docs/releasing.md).

## Notes

- `build-app.sh` defaults to an optimized, stripped **release** build. Use
  Xcode or `swift run` for normal development and debugging; `--debug` remains
  available when a packaged debug bundle is specifically needed.
- GitHub releases require Developer ID signing and Apple notarization; the
  pipeline staples the ticket and verifies Gatekeeper on the extracted ZIP.
- A standalone local build is ad-hoc signed unless an identity is available, so macOS
  re-prompts for Desktop/Documents access on every rebuild. Run
  `SmallGit/scripts/create-dev-cert.sh` once to make those grants stick.
- `build-dmg.sh` defensively strips its staged copy too, including when
  `--skip-build` reuses an older or debug bundle.
- Scratch space (DMG staging, SwiftPM intermediates) stays under
  `SmallGit/build/` and `SmallGit/.build/`.
