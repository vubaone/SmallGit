#!/usr/bin/env bash
# Build SmallGit.app -- a double-clickable macOS bundle wrapping the
# compiled binary (stripped release by default).
#
# Usage:
#   scripts/build-app.sh                # optimized, stripped release binary
#   scripts/build-app.sh --release      # explicit release build (the default)
#   scripts/build-app.sh --debug        # packaged debug build (keeps symbols)
#   scripts/build-app.sh --open         # open the resulting .app
#
# Use Xcode or `swift run` for normal development and debugging. Artifacts
# produced for distribution are optimized and have their symbols stripped.
#
# Output: <repo root>/release/SmallGit.app -- deliberately at the top level,
# outside the Swift package, so the freshly built bundle is one obvious
# place to look for a quick review instead of buried in the package tree.
set -euo pipefail

# Resolve everything to absolute paths up front: the `cd` below invalidates
# any relative path the script was invoked with (including "$0", which the
# --help handler reads).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PACKAGE_ROOT}/.." && pwd)"
cd "${PACKAGE_ROOT}"  # the SmallGit/ swift package

CONFIG="release"
OPEN_AFTER=0
for arg in "$@"; do
  case "$arg" in
    --debug)   CONFIG="debug" ;;
    --release) CONFIG="release" ;;
    --open)    OPEN_AFTER=1 ;;
    -h|--help)
      sed -n '2,16p' "${SCRIPT_DIR}/build-app.sh"
      exit 0 ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2 ;;
  esac
done

"${REPO_ROOT}/make_version.sh"

echo "[1/3] building SmallGit (${CONFIG})"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/SmallGit"
if [[ ! -x "${BIN_PATH}" ]]; then
  echo "ERROR: binary not found at ${BIN_PATH}" >&2
  exit 1
fi

OUT_DIR="${REPO_ROOT}/release"
APP_DIR="${OUT_DIR}/SmallGit.app"

echo "[2/3] assembling release/SmallGit.app"
mkdir -p "${OUT_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

APP_BIN="${APP_DIR}/Contents/MacOS/SmallGit"
cp "${BIN_PATH}" "${APP_BIN}"
cp "Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${REPO_ROOT}/LICENSE" "${APP_DIR}/Contents/Resources/LICENSE"
cp "${REPO_ROOT}/THIRD_PARTY_NOTICES.txt" "${APP_DIR}/Contents/Resources/THIRD_PARTY_NOTICES.txt"
if [[ -f "Resources/AppIcon.icns" ]]; then
  cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

# SwiftPM release builds are optimized but still contain a large symbol table.
# Strip it before signing so release/SmallGit.app is ready for distribution.
if [[ "${CONFIG}" == "release" ]]; then
  echo "      stripping symbols from release binary"
  strip "${APP_BIN}"
fi

# Pick a signing identity. Order of preference:
#   1. SIGN_IDENTITY env var (lets CI/distribution override)
#   2. A self-signed "SmallGit Development" cert if it's in the keychain
#      (run scripts/create-dev-cert.sh once to install it)
#   3. Ad-hoc ("-") as fallback
#
# Ad-hoc TCC permissions are tied to the binary cdhash, which changes
# every rebuild and forces macOS to re-prompt for Desktop/Downloads/etc.
# access. A stable identity keeps the grant across rebuilds.
SIGN_ID="${SIGN_IDENTITY:-}"
if [[ -z "${SIGN_ID}" ]]; then
  if security find-certificate -c "SmallGit Development" \
       "${HOME}/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
    SIGN_ID="SmallGit Development"
  else
    SIGN_ID="-"
  fi
fi

if [[ "${SIGN_ID}" == "-" ]]; then
  echo "[3/3] codesigning (ad-hoc) — TCC permissions will re-prompt on each rebuild."
  echo "      Run scripts/create-dev-cert.sh once to install a stable dev cert."
else
  echo "[3/3] codesigning with '${SIGN_ID}'"
fi
TIMESTAMP_FLAG="--timestamp=none"
if [[ "${SIGN_TIMESTAMP:-0}" == "1" ]]; then
  TIMESTAMP_FLAG="--timestamp"
fi
codesign --force --sign "${SIGN_ID}" --options runtime "${TIMESTAMP_FLAG}" \
  "${APP_DIR}" >/dev/null

echo "OK: ${APP_DIR}"

if [[ "${OPEN_AFTER}" -eq 1 ]]; then
  # If an old instance is already running, `open` would just re-focus it
  # and the user would keep testing the stale binary. Quit it first so the
  # freshly built bundle actually launches.
  if pgrep -x SmallGit >/dev/null 2>&1; then
    echo "      quitting running SmallGit instance before relaunch"
    osascript -e 'tell application "SmallGit" to quit' >/dev/null 2>&1 || true
    pkill -x SmallGit >/dev/null 2>&1 || true
    # Give the process a moment to exit so `open` relaunches cleanly.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -x SmallGit >/dev/null 2>&1 || break
      sleep 0.2
    done
  fi
  open -n "${APP_DIR}"
fi
