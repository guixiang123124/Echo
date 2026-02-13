#!/usr/bin/env bash
set -euo pipefail

# Capture macOS App Store screenshots by launching Echo in an automation mode
# that opens the Home + History windows, then captures them to PNG files.
#
# Usage:
#   bash scripts/capture_macos_screenshots.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${TMPDIR:-/tmp}/echo_deriveddata_macos_screenshots"
OUTDIR="${ROOT}/output/appstore_screenshots/macos"

mkdir -p "${OUTDIR}"

xcodebuild \
  -project "${ROOT}/Echo.xcodeproj" \
  -scheme EchoMac \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "${DERIVED}" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="${DERIVED}/Build/Products/Debug/Echo.app"
if [[ ! -d "${APP}" ]]; then
  echo "Built app not found at: ${APP}" >&2
  exit 1
fi

# Launch the app in automation mode (must use `open` so it runs as a proper app bundle).
open -n "${APP}" --args --automation-screenshot --automation-out-dir "${OUTDIR}"

expected=(
  "${OUTDIR}/EchoMac-Home.png"
  "${OUTDIR}/EchoMac-Home-History.png"
  "${OUTDIR}/EchoMac-Home-Dictionary.png"
  "${OUTDIR}/EchoMac-History.png"
)

deadline=$((SECONDS + 25))
while (( SECONDS < deadline )); do
  all_ok=1
  for f in "${expected[@]}"; do
    if [[ ! -f "${f}" ]]; then
      all_ok=0
      break
    fi
  done
  if [[ "${all_ok}" -eq 1 ]]; then
    break
  fi
  sleep 0.3
done

missing=0
for f in "${expected[@]}"; do
  if [[ ! -f "${f}" ]]; then
    echo "Missing: ${f}" >&2
    missing=1
  fi
done
if [[ "${missing}" -eq 1 ]]; then
  echo "Screenshot automation did not produce all expected files." >&2
  exit 1
fi

echo "Saved:"
for f in "${expected[@]}"; do
  echo "  ${f}"
done
