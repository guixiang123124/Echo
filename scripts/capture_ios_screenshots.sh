#!/usr/bin/env bash
set -euo pipefail

# Capture iOS App Store style screenshots from Simulator using Echo deep links.
#
# Requirements:
# - Xcode + Simulator installed
# - iOS app supports deep links like: echo://home, echo://history, echo://dictionary, echo://account, echo://settings, echo://voice
#
# Usage:
#   bash scripts/capture_ios_screenshots.sh [SIMULATOR_UDID]
#
# Default UDID is the iPhone 16e simulator used in this repo's local setup.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UDID="${1:-489BB97C-ED14-4EB4-A1F7-DF746F3B79A6}"
DERIVED="${TMPDIR:-/tmp}/echo_deriveddata_screenshots"
OUTDIR="${ROOT}/output/appstore_screenshots/ios"

mkdir -p "${OUTDIR}"

open -a Simulator || true
xcrun simctl boot "${UDID}" || true

# Make screenshots more App Store like.
xcrun simctl status_bar "${UDID}" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true

xcodebuild \
  -project "${ROOT}/Echo.xcodeproj" \
  -scheme Echo \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${UDID}" \
  -derivedDataPath "${DERIVED}" \
  build

APP_PATH="${DERIVED}/Build/Products/Debug-iphonesimulator/EchoApp.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "Built app not found at: ${APP_PATH}" >&2
  exit 1
fi

xcrun simctl install "${UDID}" "${APP_PATH}"
xcrun simctl launch "${UDID}" com.xianggui.echo.app || true

capture() {
  local name="$1"
  local url="$2"
  local out="${OUTDIR}/Echo-${name}.png"
  xcrun simctl openurl "${UDID}" "${url}" || true
  sleep 1.5
  xcrun simctl io "${UDID}" screenshot "${out}"
  echo "Saved: ${out}"
}

capture "Home" "echo://home"
capture "History" "echo://history"
capture "Dictionary" "echo://dictionary"
capture "Account" "echo://account"
capture "Settings" "echo://settings"
capture "Voice" "echo://voice"

echo
echo "All screenshots saved under:"
echo "  ${OUTDIR}"
