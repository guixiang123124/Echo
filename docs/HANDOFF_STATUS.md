# Echo — Project Status & Handoff (2026-02-15)

This document is a “where we are / what’s next” handoff for continuing development and shipping Echo on macOS + iOS.

## TL;DR

- Repo: `https://github.com/guixiang123124/Echo`
- Xcode project to use: `/Users/xianggui/Downloads/Echo/Echo.xcodeproj`
- Bundle IDs:
  - iOS app: `com.xianggui.echo.app`
  - iOS keyboard extension: `com.xianggui.echo.app.keyboard`
  - macOS app: `com.xianggui.echo.mac`
- Team ID used in project: `J5Y8R5W53N`
- App Group used by iOS/macOS: `group.com.xianggui.echo.shared`
- ASR v1 default: OpenAI Whisper (`whisper-1`)

## Current State

### What Works (Core)

- iOS + macOS build/run locally.
- OpenAI Whisper transcription works (v1 baseline).
- History recording persistence exists (SQLite in EchoCore).
- App icons generated and wired in asset catalogs.

### App Store Packaging Fixes Done

- iOS App Store validation fix:
  - Added `UILaunchScreen` and `UISupportedInterfaceOrientations` (including iPad key) to:
    - `/Users/xianggui/Downloads/Echo/iOS/EchoApp/Info.plist`
- Signing hygiene:
  - Set `DEVELOPMENT_TEAM = J5Y8R5W53N` across targets in:
    - `/Users/xianggui/Downloads/Echo/Echo.xcodeproj/project.pbxproj`

### Known Submission Friction

- **Export Compliance (“Missing Compliance”)**:
  - App Store Connect requires answering export-compliance questions for the selected build.
  - This is not “upload a build again”; it’s a compliance questionnaire.
- **Screenshot dimensions**:
  - Captured iOS screenshots were `1170×2532` (iPhone 16e class) and App Store Connect requires specific sizes like `1284×2778` or `1242×2688`.
  - A resized set was generated locally at:
    - `/Users/xianggui/Downloads/Echo/output/appstore_screenshots/ios_1284x2778`
  - For future: either capture from a simulator that matches required sizes, or keep the deterministic resize step.

## Repo Layout

- iOS app:
  - `/Users/xianggui/Downloads/Echo/iOS/EchoApp`
- iOS keyboard extension:
  - `/Users/xianggui/Downloads/Echo/iOS/EchoKeyboard`
- macOS app:
  - `/Users/xianggui/Downloads/Echo/macOS/EchoMac`
- Shared packages:
  - `/Users/xianggui/Downloads/Echo/Packages/EchoCore`
  - `/Users/xianggui/Downloads/Echo/Packages/EchoUI`

## Assets & Automation

### App Icon

- Source artwork (user-provided):
  - `/Users/xianggui/Downloads/Echo/Resources/echo.jpeg`
- Icon generation script:
  - `/Users/xianggui/Downloads/Echo/scripts/generate_app_icons.py`
- Output asset catalogs:
  - iOS: `/Users/xianggui/Downloads/Echo/iOS/EchoApp/Assets.xcassets/AppIcon.appiconset`
  - macOS: `/Users/xianggui/Downloads/Echo/macOS/EchoMac/Assets.xcassets/AppIcon.appiconset`

### App Store Screenshots

- iOS deep links used to jump to screens for capture:
  - Implemented in `/Users/xianggui/Downloads/Echo/iOS/EchoApp/Views/MainView.swift`
  - Supported routes (examples): `echo://home`, `echo://history`, `echo://dictionary`, `echo://account`, `echo://settings`, `echo://voice`
- Capture scripts:
  - iOS: `/Users/xianggui/Downloads/Echo/scripts/capture_ios_screenshots.sh`
  - macOS: `/Users/xianggui/Downloads/Echo/scripts/capture_macos_screenshots.sh`
- Output directories:
  - iOS: `/Users/xianggui/Downloads/Echo/output/appstore_screenshots/ios`
  - macOS: `/Users/xianggui/Downloads/Echo/output/appstore_screenshots/macos`
- macOS screenshot capture relies on app automation flags:
  - Implemented in `/Users/xianggui/Downloads/Echo/macOS/EchoMac/App/AppDelegate.swift`
  - Args:
    - `--automation-screenshot`
    - `--automation-out-dir <dir>`

## App Store Connect Runbook (High Level)

This is the intended flow for iOS and macOS (do each platform separately):

1. Xcode: `Product -> Archive`
2. Organizer: pick latest archive -> `Distribute App -> App Store Connect -> Upload`
3. App Store Connect:
   - Wait for build processing
   - Select the build in the version page (“Add Build”)
   - Answer export compliance
   - Upload screenshots
   - Fill metadata + privacy + review notes
   - `Submit for Review`

Detailed checklists and templates live here:

- `/Users/xianggui/Downloads/Echo/docs/app-store-kit/04-app-store-connect-submission.md`
- `/Users/xianggui/Downloads/Echo/docs/app-store-kit/APP_PRIVACY_ANSWERS.md`
- `/Users/xianggui/Downloads/Echo/docs/app-store-kit/REVIEW_NOTES_TEMPLATE.md`

## Engineering Notes (Why Certain Changes Exist)

### RecordingStore device name

`RecordingStore` is an `actor`. Some platform APIs like `UIDevice.current.name` are main-actor isolated in newer SDKs and caused compilation errors during builds.

We switched the device identifier used for sync metadata to a safe nonisolated value (`ProcessInfo.processInfo.hostName`) inside:

- `/Users/xianggui/Downloads/Echo/Packages/EchoCore/Sources/EchoCore/Persistence/RecordingStore.swift`

If we later need a user-friendly device name, fetch it on `@MainActor` and pass it into the store rather than calling main-actor-only APIs from within an actor.

## Next Steps (Recommended)

### Release blocking

- iOS:
  - Complete export compliance questionnaire for the selected build.
  - Upload correctly sized screenshots (use the resized folder if needed).
  - Fill required metadata + privacy details + review notes; submit for review.
- macOS:
  - Ensure macOS build is uploaded and processed.
  - Complete macOS metadata + screenshots + privacy + review notes; submit for review.

### Post-v1 product work (after first approval)

- UI polish (macOS and iOS) toward the desired minimalist “Typeless-like” feel.
- Account/login + cloud sync (if/when enabled): Vercel + Railway + Postgres + object storage stack (see `docs/deployment/*`).
- More ASR model options:
  - OpenAI: `gpt-4o-mini-transcribe`, `gpt-4o-transcribe` (optional “faster/accurate” presets)
  - On-device (privacy/latency): WhisperKit / whisper.cpp / faster-whisper / MLX variants

