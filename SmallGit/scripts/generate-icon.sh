#!/usr/bin/env bash
# Generate Resources/AppIcon.icns from the hand-designed master PNG.
# Idempotent — re-run any time after editing the master.
#
# Source : ../resources/icon.png   (1024x1024 — at the repo root)
# Output : Resources/AppIcon.icns  (committed for reproducibility)
#
# Pipeline:
#   1. sips downscales the master to the macOS iconset
#      (16, 32, 128, 256, 512 plus @2x of each)
#   2. iconutil compiles AppIcon.iconset to AppIcon.icns
#
# `sips` reads JPEG-in-PNG gracefully, so the source can be either
# format as long as it's 1024x1024 square.
set -euo pipefail

cd "$(dirname "$0")/.."  # SmallGit/

MASTER="../resources/icon.png"
if [[ ! -f "${MASTER}" ]]; then
  echo "ERROR: master icon not found at ${MASTER}" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
ICONSET="${TMP}/AppIcon.iconset"
mkdir -p "${ICONSET}"

echo "[1/2] generating iconset variants from ${MASTER}"
for s in 16 32 128 256 512; do
  sips -s format png -z "$s" "$s" "${MASTER}" --out "${ICONSET}/icon_${s}x${s}.png"     >/dev/null
  sips -s format png -z $((s*2)) $((s*2)) "${MASTER}" --out "${ICONSET}/icon_${s}x${s}@2x.png" >/dev/null
done

echo "[2/2] compiling AppIcon.icns"
mkdir -p Resources
iconutil --convert icns "${ICONSET}" --output Resources/AppIcon.icns

echo "OK: Resources/AppIcon.icns"
