#!/usr/bin/env bash
# Build a release SmallGit.app and package it into a compressed DMG.
#
# Usage:
#   scripts/build-dmg.sh              # build release app, create DMG
#   scripts/build-dmg.sh --skip-build # reuse release/SmallGit.app
#   scripts/build-dmg.sh --open       # reveal/open the resulting DMG
#   scripts/build-dmg.sh --sign       # codesign DMG with SIGN_IDENTITY
#
# Output: <repo root>/release/SmallGit-<version>.dmg -- alongside the .app,
# so every reviewable artifact sits in the same top-level release/ folder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PACKAGE_ROOT}/.." && pwd)"
cd "${PACKAGE_ROOT}"  # the SmallGit/ swift package

SKIP_BUILD=0
OPEN_AFTER=0
SIGN_DMG=0

for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --open)       OPEN_AFTER=1 ;;
    --sign)       SIGN_DMG=1 ;;
    -h|--help)
      sed -n '2,11p' "${SCRIPT_DIR}/build-dmg.sh"
      exit 0 ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2 ;;
  esac
done

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "ERROR: hdiutil is required to create a DMG." >&2
  exit 1
fi

"${REPO_ROOT}/make_version.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
RELEASE_DIR="${REPO_ROOT}/release"
APP_DIR="${RELEASE_DIR}/SmallGit.app"
DMG_PATH="${RELEASE_DIR}/SmallGit-${VERSION}.dmg"

# Staging is scratch, not an artifact: a copy of the .app plus an /Applications
# symlink, thrown away the moment hdiutil has read it. It used to live in
# SmallGit/build/, which meant a stale 4.5 MB copy of the app sat in the
# working tree between releases, in a directory that exists for no other
# reason. A temp dir removes both the leftovers and the directory.
#
# The trap fires on error and interrupt as well as on success -- hdiutil
# failing halfway used to leave the staged copy behind too.
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/smallgit-dmg.XXXXXX")"
trap 'rm -rf "${SCRATCH_DIR}"' EXIT
STAGE_DIR="${SCRATCH_DIR}/dmg"
TMP_DMG_PATH="${SCRATCH_DIR}/SmallGit-${VERSION}.tmp.dmg"
VOLUME_NAME="SmallGit ${VERSION}"

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  echo "[1/4] building release app"
  # build-app.sh defaults to debug for fast local iteration; the DMG is the
  # distribution artifact, so force the optimized release config here.
  scripts/build-app.sh --release
else
  echo "[1/4] reusing existing release app"
fi

if [[ ! -d "${APP_DIR}" ]]; then
  echo "ERROR: release/SmallGit.app not found. Run scripts/build-app.sh first or omit --skip-build." >&2
  exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_DIR}/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_DIR}/Contents/Info.plist")"
EXPECTED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
if [[ "${APP_VERSION}" != "${VERSION}" || "${APP_BUILD}" != "${EXPECTED_BUILD}" ]]; then
  echo "ERROR: app version is stale. Rebuild without --skip-build." >&2
  exit 1
fi

mkdir -p "${RELEASE_DIR}"

echo "[2/4] staging DMG contents"
mkdir -p "${STAGE_DIR}"
cp -R "${APP_DIR}" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"

# Release builds are already stripped by build-app.sh. Strip the staged copy
# defensively as well because --skip-build may reuse an older or debug bundle.
# strip mutates the binary and invalidates the code signature, so re-sign the
# staged bundle afterwards using the same identity logic as build-app.sh.
STAGED_BIN="${STAGE_DIR}/SmallGit.app/Contents/MacOS/SmallGit"
echo "      stripping symbols from staged binary"
strip "${STAGED_BIN}"

SIGN_ID="${SIGN_IDENTITY:-}"
if [[ -z "${SIGN_ID}" ]]; then
  if security find-certificate -c "SmallGit Development" \
       "${HOME}/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
    SIGN_ID="SmallGit Development"
  else
    SIGN_ID="-"
  fi
fi
echo "      re-codesigning stripped bundle with '${SIGN_ID}'"
codesign --force --sign "${SIGN_ID}" --options runtime --timestamp=none \
  "${STAGE_DIR}/SmallGit.app" >/dev/null

# Only the destination needs clearing now; the temp DMG is in a fresh dir.
rm -f "${DMG_PATH}"

echo "[3/4] creating compressed DMG"
hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${TMP_DMG_PATH}" >/dev/null

mv "${TMP_DMG_PATH}" "${DMG_PATH}"

if [[ "${SIGN_DMG}" -eq 1 ]]; then
  SIGN_ID="${SIGN_IDENTITY:-}"
  if [[ -z "${SIGN_ID}" || "${SIGN_ID}" == "-" ]]; then
    echo "ERROR: --sign requires SIGN_IDENTITY to name a real signing identity." >&2
    exit 1
  fi

  echo "[4/4] signing DMG with '${SIGN_ID}'"
  codesign --force --sign "${SIGN_ID}" --timestamp "${DMG_PATH}" >/dev/null
else
  echo "[4/4] skipping DMG signing"
fi

echo "OK: ${DMG_PATH}"

if [[ "${OPEN_AFTER}" -eq 1 ]]; then
  open "${DMG_PATH}"
fi
