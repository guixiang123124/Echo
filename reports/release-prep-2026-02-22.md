# Echo release prep report (2026-02-22)

## Scope
- Goal: finish all pre-submit items that can be completed automatically today.
- Repo: `/Users/xianggui/.openclaw/workspace/Echo`

## Completed today

1. Release documentation alignment
- Unified macOS bundle ID references to `com.xianggui.echo.mac` in App Store kit docs.
- Unified install-path references to `/Applications/Echo.app`.
- Added final runbook:
  - `docs/app-store-kit/07-pre-submit-final-checklist.md`

2. Preflight automation upgrade
- Updated `scripts/release_preflight.sh` to check:
  - Team ID + bundle IDs (iOS / keyboard / macOS)
  - Dynamic project build/version vs plist consistency
  - iOS keyboard extension version consistency
  - Profile presence from both legacy and modern Xcode paths
  - Optional ASC API key and Xcode account cache (warn-only)

3. iOS extension version consistency fix
- Updated `iOS/EchoKeyboard/Info.plist`:
  - `CFBundleVersion` from `1` -> `2`

4. Release builds executed
- iOS Release build: succeeded
  - Command: `xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Release -destination "generic/platform=iOS" build`
- macOS Release build: succeeded
  - Command: `xcodebuild -project Echo.xcodeproj -scheme EchoMac -configuration Release -destination "generic/platform=macOS" build`

## Current blockers (manual / account-side)

1. Missing distribution certificates
- `Apple Distribution` not found
- `Mac Installer Distribution` not found

2. Local keychain currently has only development identity
- `security find-identity -v -p codesigning`:
  - `Apple Development: guixiang123123@gmail.com (J5Y8R5W53N)`

## Latest preflight result

- Command: `bash scripts/release_preflight.sh`
- Result:
  - Pass: 21
  - Fail: 2
  - Warn: 2
- Fails are exactly the two missing distribution certs above.

## Tomorrow go-live minimal steps

1. In Xcode (or Developer portal), install distribution certificates/profiles:
- Apple Distribution
- Mac Installer Distribution

2. Re-run:
```bash
bash scripts/release_preflight.sh
```

3. Archive and upload:
```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Release -destination "generic/platform=iOS" archive -archivePath /tmp/Echo-iOS-Release.xcarchive
xcodebuild -project Echo.xcodeproj -scheme EchoMac -configuration Release -destination "generic/platform=macOS" archive -archivePath /tmp/Echo-macOS-Release.xcarchive
```

4. Complete App Store Connect submission metadata + review notes and submit.
