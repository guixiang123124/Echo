#!/usr/bin/env bash
set -euo pipefail

# Installs the unified latest Release build of Echo from the fixed DerivedData path
# used by scripts/build_and_deploy_latest.sh. This prevents Debug/Release path drift
# and keeps a single canonical app at /Applications/Echo.app.
#
# Usage:
#   ./scripts/install_macos_app.sh
#
# Notes:
# - Build with scripts/build_and_deploy_latest.sh (or Release in Xcode) before running.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DIR="${ROOT}/output/DerivedDataLatest"
APP_SRC="${DERIVED_DIR}/Build/Products/Release/EchoMac.app"
if [[ ! -d "${APP_SRC}" ]]; then
  APP_SRC="${DERIVED_DIR}/Build/Products/Release/Echo.app"
fi

if [[ ! -d "${APP_SRC}" ]]; then
  echo "Release app not found in unified DerivedData path."
  echo "Expected one of:"
  echo "  ${DERIVED_DIR}/Build/Products/Release/EchoMac.app"
  echo "  ${DERIVED_DIR}/Build/Products/Release/Echo.app"
  echo "Run scripts/build_and_deploy_latest.sh first."
  exit 1
fi

INSTALL_DIR="/Applications"
APP_DEST="${INSTALL_DIR}/Echo.app"

rm -rf "${APP_DEST}"

/usr/bin/ditto "${APP_SRC}" "${APP_DEST}"
echo "Installed:"
echo "  ${APP_DEST}"

open "${APP_DEST}"
