#!/usr/bin/env bash
# Website only; never builds or releases the macOS app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
MODE="${1:---check}"
if [[ $# -gt 1 ]]; then
  echo "Usage: ./website.sh [--check|--test|--deploy]" >&2
  exit 2
fi
case "$MODE" in
  --check|--test|--deploy) ;;
  -h|--help)
    echo "Usage: ./website.sh [--check|--test|--deploy]"
    echo "--check: build and validate; --test: also run headless UI tests; --deploy: upload the clean, pushed main commit."
    exit 0 ;;
  *) echo "Unknown option: $MODE" >&2; exit 2 ;;
esac

node website/scripts/build.mjs
node website/scripts/check.mjs
node website/scripts/check-public-release.mjs

if [[ "$MODE" == --test ]]; then
  node website/scripts/test-ui.mjs
elif [[ "$MODE" == --deploy ]]; then
  if [[ -n "$(git status --porcelain)" || "$(git branch --show-current)" != main ]]; then
    echo "Commit the website on a clean main branch before deploying." >&2
    exit 1
  fi
  HEAD_SHA="$(git rev-parse HEAD)"
  REMOTE_SHA="$(git ls-remote --exit-code origin refs/heads/main | cut -f1)"
  if [[ "$HEAD_SHA" != "$REMOTE_SHA" ]]; then
    echo "Push main before deploying; local HEAD does not match origin/main." >&2
    exit 1
  fi
  if [[ ! -x website/node_modules/.bin/wrangler ]]; then
    echo "Install website tools first: npm ci --prefix website --cache SmallGit/.build/website/npm" >&2
    exit 1
  fi
  export WRANGLER_LOG_PATH="$ROOT/SmallGit/.build/website/wrangler-logs"
  export WRANGLER_SEND_METRICS=false
  export CI=true
  # The existing Git-connected Pages project must be set up first; no auto-create.
  website/node_modules/.bin/wrangler pages deploy website/dist \
    --project-name smallgit --branch main --commit-hash "$HEAD_SHA" \
    --commit-message "$(git log -1 --format=%s)" --commit-dirty=false
fi
