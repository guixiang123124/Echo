#!/usr/bin/env bash
set -euo pipefail

# Copies the latest Debug build of EchoMac.app from DerivedData into a stable location
# so macOS permissions (Accessibility/Input Monitoring) don't keep resetting due to
# changing build paths.
#
# Usage:
#   ./scripts/install_macos_app.sh
#
# Notes:
# - For best results, build/run the `EchoMac` scheme in Xcode with signing enabled first.
# - We install into ~/Applications to avoid requiring admin privileges.

DERIVED_ROOT="${HOME}/Library/Developer/Xcode/DerivedData"
DERIVED_DIR="$(ls -td "${DERIVED_ROOT}"/Echo-* 2>/dev/null | head -n 1 || true)"

if [[ -z "${DERIVED_DIR}" ]]; then
  echo "No DerivedData found for Echo. Build the EchoMac scheme in Xcode first."
  exit 1
fi

APP_SRC="${DERIVED_DIR}/Build/Products/Debug/EchoMac.app"
if [[ ! -d "${APP_SRC}" ]]; then
  echo "EchoMac.app not found at:"
  echo "  ${APP_SRC}"
  echo "Build the EchoMac scheme in Xcode (Debug) first, then re-run this script."
  exit 1
fi

INSTALL_DIR="${HOME}/Applications"
APP_DEST="${INSTALL_DIR}/Echo.app"

mkdir -p "${INSTALL_DIR}"
rm -rf "${APP_DEST}"

/usr/bin/ditto "${APP_SRC}" "${APP_DEST}"
echo "Installed:"
echo "  ${APP_DEST}"

open "${APP_DEST}"

