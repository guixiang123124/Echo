#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/xianggui/.openclaw/workspace/Echo"
DERIVED="$ROOT/output/DerivedDataLatest"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STAMP_ID="$(date -u +%Y%m%d%H%M%S)"

cd "$ROOT"

mkdir -p "$ROOT/output/latest"

echo "[1/5] Build iOS (Release)"
xcodebuild \
  -project Echo.xcodeproj \
  -scheme Echo \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED" \
  build

echo "[2/5] Build macOS (Release)"
xcodebuild \
  -project Echo.xcodeproj \
  -scheme EchoMac \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  build

IOS_APP="$DERIVED/Build/Products/Release-iphoneos/EchoApp.app"
MAC_APP="$DERIVED/Build/Products/Release/EchoMac.app"
MAC_CANONICAL="/Applications/Echo.app"

if [[ ! -d "$IOS_APP" ]]; then
  echo "iOS app not found: $IOS_APP" >&2
  exit 1
fi
if [[ ! -d "$MAC_APP" ]]; then
  echo "macOS app not found: $MAC_APP" >&2
  exit 1
fi

echo "[3/5] Install/launch iOS on connected device"
DEVICE_ID="$(xcrun devicectl list devices | grep ' connected ' | sed -E 's/.*([A-F0-9-]{36}).*/\1/' | head -n1 || true)"
if [[ -z "${DEVICE_ID}" ]]; then
  echo "No connected iPhone detected via devicectl" >&2
  exit 1
fi

xcrun devicectl device install app --device "$DEVICE_ID" "$IOS_APP"
xcrun devicectl device process launch --device "$DEVICE_ID" com.xianggui.echo.app

echo "[4/5] Promote macOS app to canonical path"
pkill -f "/Applications/Echo.app/Contents/MacOS/Echo" >/dev/null 2>&1 || true
rm -rf "$MAC_CANONICAL"
cp -R "$MAC_APP" "$MAC_CANONICAL"
open -na "$MAC_CANONICAL"

echo "[5/5] Write unified latest stamp"
cat > "$ROOT/output/latest/BUILD_STAMP.txt" <<EOF
stamp_utc=$STAMP
stamp_id=$STAMP_ID
build_configuration=Release
derived_data=$DERIVED
ios_app=$IOS_APP
mac_source_app=$MAC_APP
mac_canonical_app=$MAC_CANONICAL
ios_bundle_id=com.xianggui.echo.app
mac_bundle_id=com.xianggui.echo.mac
EOF

echo "Done. Unified latest release deployed."
echo "Stamp: $ROOT/output/latest/BUILD_STAMP.txt"
