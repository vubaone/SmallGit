# SmallGit landing page

Production: https://smallgit.vuba.one

From the repository root, use `./website.sh --check` to build and validate,
`./website.sh --test` for headless browser tests, or `./website.sh --deploy` for
an authorized manual deployment. Normal updates deploy automatically from `main`.

See [the website guide](../docs/website.md) for setup, dependencies, public
download configuration, DNS and troubleshooting. The Cloudflare build watch
pattern is `website/*`; its single wildcard also matches nested directories.

Only `dist/` is deployed. Do not upload this source directory or the repository
root, and keep tokens outside the published files.
