#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Echo.xcodeproj"
IOS_INFO_PLIST="$ROOT_DIR/iOS/EchoApp/Info.plist"
IOS_KEYBOARD_INFO_PLIST="$ROOT_DIR/iOS/EchoKeyboard/Info.plist"
MAC_INFO_PLIST="$ROOT_DIR/macOS/EchoMac/Info.plist"
TEAM_ID="${TEAM_ID:-D7BK236H9B}"
EXPECTED_IOS_BUNDLE_ID="${EXPECTED_IOS_BUNDLE_ID:-com.xianggui.echo.app}"
EXPECTED_IOS_KEYBOARD_BUNDLE_ID="${EXPECTED_IOS_KEYBOARD_BUNDLE_ID:-com.xianggui.echo.app.keyboard}"
EXPECTED_MAC_BUNDLE_ID="${EXPECTED_MAC_BUNDLE_ID:-com.xianggui.echo.mac}"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "[PASS] $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "[FAIL] $1"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  echo "[WARN] $1"
}

check_file() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    pass "$label exists"
  else
    fail "$label missing: $path"
  fi
}

check_text() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq "$needle" <<< "$haystack"; then
    pass "$label"
  else
    fail "$label"
  fi
}

extract_pbx_setting() {
  local key="$1"
  local value
  value="$(grep -m1 "$key = " "$PROJECT_PATH/project.pbxproj" | sed -E 's/.*= ([^;]+);/\1/' | tr -d '[:space:]' || true)"
  echo "$value"
}

plist_get() {
  local plist_path="$1"
  local key_path="$2"
  /usr/libexec/PlistBuddy -c "Print :$key_path" "$plist_path" 2>/dev/null || true
}

echo "=== Echo release preflight ==="
echo "Project: $PROJECT_PATH"
echo "Team:    $TEAM_ID"
echo

check_file "$PROJECT_PATH/project.pbxproj" "Xcode project"
check_file "$IOS_INFO_PLIST" "iOS Info.plist"
check_file "$IOS_KEYBOARD_INFO_PLIST" "iOS keyboard Info.plist"
check_file "$MAC_INFO_PLIST" "macOS Info.plist"

CODE_SIGN_OUTPUT="$(security find-identity -v -p codesigning 2>/dev/null || true)"
check_text "$CODE_SIGN_OUTPUT" "Apple Development" "Apple Development certificate available"
check_text "$CODE_SIGN_OUTPUT" "Apple Distribution" "Apple Distribution certificate available"
check_text "$CODE_SIGN_OUTPUT" "Mac Installer Distribution" "Mac Installer Distribution certificate available"

PBXPROJ_CONTENT="$(cat "$PROJECT_PATH/project.pbxproj")"
check_text "$PBXPROJ_CONTENT" "DEVELOPMENT_TEAM = $TEAM_ID;" "Team ID configured in project"
check_text "$PBXPROJ_CONTENT" "PRODUCT_BUNDLE_IDENTIFIER = $EXPECTED_IOS_BUNDLE_ID;" "iOS bundle ID configured"
check_text "$PBXPROJ_CONTENT" "PRODUCT_BUNDLE_IDENTIFIER = $EXPECTED_IOS_KEYBOARD_BUNDLE_ID;" "iOS keyboard bundle ID configured"
check_text "$PBXPROJ_CONTENT" "PRODUCT_BUNDLE_IDENTIFIER = $EXPECTED_MAC_BUNDLE_ID;" "macOS bundle ID configured"

EXPECTED_BUILD_NUMBER="$(extract_pbx_setting CURRENT_PROJECT_VERSION)"
EXPECTED_MARKETING_VERSION="$(extract_pbx_setting MARKETING_VERSION)"
if [[ -n "$EXPECTED_BUILD_NUMBER" ]]; then
  pass "Project build number detected ($EXPECTED_BUILD_NUMBER)"
else
  fail "Could not detect CURRENT_PROJECT_VERSION in project.pbxproj"
fi
if [[ -n "$EXPECTED_MARKETING_VERSION" ]]; then
  pass "Project marketing version detected ($EXPECTED_MARKETING_VERSION)"
else
  fail "Could not detect MARKETING_VERSION in project.pbxproj"
fi

IOS_INFO="$(cat "$IOS_INFO_PLIST")"
MAC_INFO="$(cat "$MAC_INFO_PLIST")"
check_text "$IOS_INFO" "UILaunchScreen" "iOS launch screen key present"
check_text "$IOS_INFO" "UISupportedInterfaceOrientations" "iOS supported orientations present"
check_text "$MAC_INFO" "LSApplicationCategoryType" "macOS category key present"

IOS_BUILD_NUMBER="$(plist_get "$IOS_INFO_PLIST" CFBundleVersion)"
IOS_KEYBOARD_BUILD_NUMBER="$(plist_get "$IOS_KEYBOARD_INFO_PLIST" CFBundleVersion)"
MAC_BUILD_NUMBER="$(plist_get "$MAC_INFO_PLIST" CFBundleVersion)"
IOS_MARKETING_VERSION="$(plist_get "$IOS_INFO_PLIST" CFBundleShortVersionString)"
IOS_KEYBOARD_MARKETING_VERSION="$(plist_get "$IOS_KEYBOARD_INFO_PLIST" CFBundleShortVersionString)"
MAC_MARKETING_VERSION="$(plist_get "$MAC_INFO_PLIST" CFBundleShortVersionString)"

if [[ -n "$EXPECTED_BUILD_NUMBER" && "$IOS_BUILD_NUMBER" == "$EXPECTED_BUILD_NUMBER" ]]; then
  pass "iOS build number matches project ($IOS_BUILD_NUMBER)"
else
  fail "iOS build number mismatch (project=$EXPECTED_BUILD_NUMBER, plist=$IOS_BUILD_NUMBER)"
fi
if [[ -n "$EXPECTED_BUILD_NUMBER" && "$IOS_KEYBOARD_BUILD_NUMBER" == "$EXPECTED_BUILD_NUMBER" ]]; then
  pass "iOS keyboard build number matches project ($IOS_KEYBOARD_BUILD_NUMBER)"
else
  fail "iOS keyboard build number mismatch (project=$EXPECTED_BUILD_NUMBER, plist=$IOS_KEYBOARD_BUILD_NUMBER)"
fi
if [[ -n "$EXPECTED_BUILD_NUMBER" && "$MAC_BUILD_NUMBER" == "$EXPECTED_BUILD_NUMBER" ]]; then
  pass "macOS build number matches project ($MAC_BUILD_NUMBER)"
else
  fail "macOS build number mismatch (project=$EXPECTED_BUILD_NUMBER, plist=$MAC_BUILD_NUMBER)"
fi
if [[ -n "$EXPECTED_MARKETING_VERSION" && "$IOS_MARKETING_VERSION" == "$EXPECTED_MARKETING_VERSION" ]]; then
  pass "iOS marketing version matches project ($IOS_MARKETING_VERSION)"
else
  fail "iOS marketing version mismatch (project=$EXPECTED_MARKETING_VERSION, plist=$IOS_MARKETING_VERSION)"
fi
if [[ -n "$EXPECTED_MARKETING_VERSION" && "$IOS_KEYBOARD_MARKETING_VERSION" == "$EXPECTED_MARKETING_VERSION" ]]; then
  pass "iOS keyboard marketing version matches project ($IOS_KEYBOARD_MARKETING_VERSION)"
else
  fail "iOS keyboard marketing version mismatch (project=$EXPECTED_MARKETING_VERSION, plist=$IOS_KEYBOARD_MARKETING_VERSION)"
fi
if [[ -n "$EXPECTED_MARKETING_VERSION" && "$MAC_MARKETING_VERSION" == "$EXPECTED_MARKETING_VERSION" ]]; then
  pass "macOS marketing version matches project ($MAC_MARKETING_VERSION)"
else
  fail "macOS marketing version mismatch (project=$EXPECTED_MARKETING_VERSION, plist=$MAC_MARKETING_VERSION)"
fi

PROFILE_COUNT=0
PROFILE_DIRS=(
  "$HOME/Library/MobileDevice/Provisioning Profiles"
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
)

for dir in "${PROFILE_DIRS[@]}"; do
  if [[ -d "$dir" ]]; then
    COUNT="$(find "$dir" -name "*.mobileprovision" 2>/dev/null | wc -l | tr -d ' ')"
    PROFILE_COUNT=$((PROFILE_COUNT + COUNT))
  fi
done

if [[ "$PROFILE_COUNT" -gt 0 ]]; then
  pass "Provisioning profiles present ($PROFILE_COUNT total)"
else
  fail "No provisioning profiles found (checked legacy and Xcode UserData paths)"
fi

ASC_KEY_DIR="$HOME/.appstoreconnect/private_keys"
if [[ -d "$ASC_KEY_DIR" ]]; then
  ASC_KEY_COUNT="$(find "$ASC_KEY_DIR" -name "AuthKey_*.p8" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$ASC_KEY_COUNT" -gt 0 ]]; then
    pass "App Store Connect API keys detected ($ASC_KEY_COUNT)"
  else
    warn "ASC key directory exists but no AuthKey_*.p8 found"
  fi
else
  warn "No ASC API key directory found (~/.appstoreconnect/private_keys)"
fi

if [[ -d "$HOME/Library/Developer/Xcode/UserData/Accounts" ]]; then
  pass "Xcode account cache directory exists"
else
  warn "Xcode account cache directory not found; if export/upload fails, sign in via Xcode Settings > Accounts"
fi

echo
echo "=== Summary ==="
echo "Pass: $PASS_COUNT"
echo "Fail: $FAIL_COUNT"
echo "Warn: $WARN_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "Preflight failed. Fix FAIL items before export/upload."
  exit 1
fi

echo "Preflight passed."
