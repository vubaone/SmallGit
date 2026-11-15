# SmallGit handoff workflow

- After completing any code fix, run the relevant tests and build the optimized release app with `SmallGit/scripts/build-app.sh --release`.
- Deliver the resulting bundle at `release/SmallGit.app`; do not hand off only a debug build.
- Verify the packaged executable is stripped and the app bundle contains no `.dSYM` or embedded `__DWARF` segment.
- Build a DMG only when the user explicitly requests one.

## Releasing SmallGit (persistent instructions for agents)

When the user asks to release SmallGit, upload a GitHub release, or says
"release", "đẩy release", or "phát hành", use the root entry point:

```sh
./release.sh            # tests → Developer ID build → notarize → verify → ZIP → GitHub draft
./release.sh --publish  # same pipeline, publish a new release immediately
./release.sh --local    # local checks/package without Apple or GitHub uploads
./release.sh --local --notarize # also sign/notarize locally; no GitHub upload
./release.sh --check    # read-only readiness check, no tests/build/upload
```

- Default to a draft. Use `--publish` when the user explicitly asks to publish
  immediately. A request to implement or repair the workflow itself is not a
  request to create a real release: validate with `--local` in that case.
- Read [docs/releasing.md](docs/releasing.md) before releasing. Do not improvise
  another build/upload flow or upload the workspace, private backups, or logs.
- Version comes from `AppVersion` and [MAKE_VERSION_GUIDE.MD](MAKE_VERSION_GUIDE.MD).
  Use the version the user requested; do not silently increment it or substitute
  today's date. After changing it, run `./make_version.sh` and commit the metadata.
- Upload modes require a clean working tree and HEAD matching the pushed
  `origin` branch. Finish, test, commit, and normally push the intended source
  before running them. Never force-push as part of a release.
- The workflow uses the existing `gh` authentication and the GitHub repository
  from `origin`. It pins the release to the exact built commit. It does not change
  repository visibility, overwrite releases/assets, or move existing tags.
- Run the included desktop-free tests. Do not replace them with unfiltered
  `swift test` on the primary Mac, open the app/Xcode/browser, or create a VM.
  Full native-window tests belong to a dedicated runner; see docs/testing.md.
- Do not bypass a failing check to upload. For an existing version, inspect the
  release and follow the existing-draft instructions in docs/releasing.md.
  Publishing a reviewed existing draft is a separate explicit user action.
- New releases are always uploaded as drafts first. Verify the remote asset
  list, upload states, sizes and checksums before publishing. `--publish` does
  this automatically and verifies the final release and tag again. Do not replace
  this with a direct `gh release create` that bypasses the verification steps.
- Report the version/build, commit, test results, asset paths, GitHub release URL
  and whether it is a draft or published. GitHub uploads require Developer ID,
  Apple acceptance, a stapled ticket and Gatekeeper verification of the extracted
  ZIP. Never bypass notarization or upload an ad-hoc build.
- Reuse the existing notarytool Keychain profile. Profile/identity labels may be
  stored in ignored `.private/release-config.json`; never store credentials there
  or in source. Read the signing setup in docs/releasing.md. A timeout must resume
  the existing Apple submission; do not repeatedly submit the same pending build.

## Landing page (smallgit.vuba.one)

- Read [docs/website.md](docs/website.md) for website deployment and account setup.
- Source is `website/`; hosting is Cloudflare Pages with GitHub integration.
  Run `./website.sh --check` and `./website.sh --test` for changes. Tests use
  headless Chrome, never the primary Mac desktop. Keep artifacts in `.build`.
- Once Git integration is configured, pushing relevant changes to `main`
  automatically deploys. `./website.sh --deploy` is the manual fallback for an
  existing Git-connected project and requires clean, pushed source.
- `website/site.config.json` controls public download links. Do not change repo
  visibility without explicit permission. Public mode must pass the unauthenticated
  GitHub release check; keep `/releases/latest` instead of hardcoding a version.
- Keep the app release workflow separate. Website deployment does not publish an
  app release. Never upload the repository root or create a Direct Upload Pages
  project that would prevent the intended Git integration.
- Search/AI discovery is generated during the website build. Update README product
  sections and `website/scripts/discovery.mjs`, not files under `website/dist/`.
  Keep limitations, platform requirements, and public/coming-soon mode consistent.
  Preserve `README.md` in Pages build watch paths. Never invent ratings or claim
  that publishing `llms.txt` guarantees search indexing or AI recommendations.
