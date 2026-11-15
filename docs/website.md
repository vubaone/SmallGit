# SmallGit website

The landing page is a static HTML/CSS site hosted on **Cloudflare Pages** at
**https://smallgit.vuba.one**. The source lives in `website/`; app downloads stay
on GitHub Releases. There is no backend, runtime JavaScript, analytics, or cookie
banner. DNS and hosting can be managed in the same Cloudflare account.

Production is configured as the Git-connected Pages project `smallgit`, with
automatic deployment from `main`. Its assigned hostname is `smallgit.pages.dev`.
The `vuba.one` zone has a proxied CNAME from `smallgit` to `smallgit.pages.dev`
with automatic TTL. The setup instructions below are for recovery or migration;
do not recreate the existing project during routine updates.

The site's `Cache-Control: no-transform` response header keeps Cloudflare from
rewriting contact links or injecting scripts into the static pages. This is
scoped to SmallGit's responses; it does not edit settings for the rest of the
`vuba.one` zone. Keep this header when changing cache rules.

## Local commands

Use Node.js 22 or later from the repository root:

```sh
./website.sh --check  # build + asset/link/metadata checks + public release check
```

The output is `website/dist/`. Build scripts use only Node's standard library.
Only the explicitly copied HTML, CSS, images, headers, robots.txt, sitemap, and
generated `index.md` / `llms.txt`
are published; the repository, app bundle, logs and credentials are not copied.

Install the pinned tools once to run browser tests or deploy manually:

```sh
npm ci --prefix website --cache SmallGit/.build/website/npm
./website.sh --test
```

Tests launch Chrome **headless with a separate temporary profile**. They do not
open or control the desktop. The default executable is the installed Google
Chrome on macOS. On other systems, set `SMALLGIT_TEST_BROWSER` to an installed
Chrome/Chromium executable; the runner does not download a browser. Screenshots,
temporary files and logs stay under `SmallGit/.build/website/`.

Both public and coming-soon modes are checked at 1440, 768, 390 and 320 pixels:
horizontal overflow, image loading, FAQ controls, keyboard navigation, download
destinations, security headers and the 404 page. Tests restore the configured
build when finished.

## Connect Cloudflare once

1. In Cloudflare **Workers & Pages → Create application → Pages → Connect to
   Git**, install and authorize **Cloudflare Workers & Pages** for
   `vubaone/SmallGit`. Restrict access to this repository where possible. Do not
   uninstall an existing integration used by other projects.
2. Create a **Git-connected** Pages project named `smallgit`, branch `main`.
   Do not create a Direct Upload project first: Cloudflare cannot convert it to
   Git integration later.
3. Set the build configuration:

   | Setting | Value |
   | --- | --- |
   | Framework | None |
   | Root directory | Repository root (blank) |
   | Build command | `./website.sh --check` |
   | Build output directory | `website/dist` |
   | Environment variable | `NODE_VERSION=22` |
   | Production branch | `main` |
   | Automatic production deployments | Enabled |
   | Preview deployments | Disabled initially |

   Build watch paths: `website/*`, `website.sh`, `README.md`,
   `screens/smallgit-main-window.png`, `resources/small-potato.png`.
   Cloudflare uses a single `*` to include nested paths; do not use `**`.
   No npm install is needed for the Cloudflare build.
4. After a successful deployment, open the project's **Custom domains** and
   add `smallgit.vuba.one`. Let Cloudflare create its CNAME in the `vuba.one`
   zone. If doing this via API, verify that the DNS record was actually created;
   adding a Pages domain alone is not proof that DNS works. The CNAME target is
   the project's assigned `*.pages.dev` hostname, which can differ from its name.
5. Verify HTTPS on the custom domain, both images, `/styles.css`, `/robots.txt`,
   `/sitemap.xml`, `/llms.txt`, `/index.md` and a missing page returning 404. Set the GitHub repository
   homepage to the custom domain only after it is live.

After setup, a normal commit and push to `main` deploys relevant website changes.
When checking the deployment API, inspect `is_skipped` and `skip_reason` as well
as `latest_stage`: a skipped deployment can remain at `queued` with `idle` status.
Git integration does not need a Cloudflare API token stored in GitHub Actions.
App CI and the app release command remain separate.

Official references: [GitHub integration](https://developers.cloudflare.com/pages/configuration/git-integration/github-integration/),
[custom domains](https://developers.cloudflare.com/pages/configuration/custom-domains/),
[Direct Upload limitations](https://developers.cloudflare.com/pages/get-started/direct-upload/).

## Public launch and download links

`website/site.config.json` uses `"publicRelease": true` for the public launch.
Set it to `false` for coming-soon mode, which uses the maintainer's contact
address instead of GitHub links and does not offer a public download.

Once the maintainer has explicitly approved making the repository public and a
stable release with an Apple silicon ZIP is publicly accessible, set
`publicRelease` to `true`, run the checks, commit and push. The build verifies the
latest release **without credentials** before allowing download links to ship.
Do not change GitHub repository visibility automatically as part of deployment.

The download button uses `/releases/latest`; future app releases do not require
editing the website version. Keep platform and signing information aligned with
the actual app. `SMALLGIT_PUBLIC_RELEASE=true|false` is a temporary build/test
override; prefer the tracked config for production so local and Cloudflare builds
agree. Do not leave an override in Cloudflare after changing the tracked setting.

## Search and AI discovery

The page describes SmallGit as a free, native, open-source Git client for macOS
and an independent SmartGit alternative. Keep claims consistent with the README's
feature table and limitations. Do not add unsupported features, keyword lists,
invented reviews or ratings to improve search appearance.

- `scripts/discovery.mjs` maintains the title, description and SoftwareApplication
  metadata. The public release URL is always `/releases/latest`, not a copied
  version number. Coming-soon mode omits repository and download metadata.
- `/index.md` is generated at build time from an explicit list of README product
  sections, including limitations. Relative links resolve to GitHub. Renaming a
  required heading stops the build so missing information cannot silently ship.
- `/llms.txt` provides a concise product overview and links to the generated
  guide, release and documentation. HTML discovery links and HTTP `Link` headers
  advertise both files; Markdown has the correct content type and a canonical
  link to the landing page. These files also respect coming-soon mode.
- `robots.txt` allows crawling and advertises `sitemap.xml`. The sitemap contains
  the canonical HTML page and its app screenshot; generated Markdown is an
  alternate representation, not another search landing page. Do not stamp a
  fresh sitemap date on every build when the content has not changed.
- README changes must trigger Pages builds because they change the public guide.
  Keep `README.md` in the Cloudflare build watch paths.

Run `./website.sh --test` after changing discovery content. Both publication
modes check metadata, absolute Markdown links, limitations, and the output file
allowlist in addition to the responsive UI checks. After deploy, fetch the
discovery URLs without credentials and verify their status, content type and
headers. A successful request with a crawler User-Agent is only a reachability
check, not evidence that the actual search crawler has indexed the site.

The site does not submit to Google Search Console automatically: that requires
access to a verified property. An owner can verify `smallgit.vuba.one` (or use an
existing `vuba.one` domain property), submit
`https://smallgit.vuba.one/sitemap.xml`, and inspect the homepage URL. Never commit
Search Console credentials. Use its indexing and search-performance reports to
measure discovery; deployment alone does not prove indexing or rankings.

References: [Google's AI search guidance](https://developers.google.com/search/docs/appearance/ai-features),
[software-app structured data](https://developers.google.com/search/docs/appearance/structured-data/software-app),
[sitemap guidance](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap),
[llms.txt proposal](https://llmstxt.org/).
`llms.txt` is supplementary; Google does not require AI text files. The app has no
published rating/review data, so the schema does not claim eligibility for a
Google software-app rich result that requires such data.

## Manual deployment and rollback

For an **existing Git-connected** Pages project, an authorized maintainer can
deploy the clean, pushed `main` commit with:

```sh
./website.sh --deploy
```

This uses existing Wrangler authentication and refuses dirty or unpushed source.
It does not create a Pages project, change DNS, change repository visibility,
or release the app. If authentication needs renewing, the maintainer can run
`website/node_modules/.bin/wrangler login` themselves; an agent must not open a
browser or take over the primary Mac. Never commit tokens or copy local OAuth
refresh credentials into CI.

Use Cloudflare Pages **Deployments → Rollback to this deployment** for an urgent
rollback, then revert the relevant website commit so the next automatic deploy
does not restore the unwanted change.
