# Echo V2 Architecture and Implementation Log

## Product decisions locked

1. Default preset: `Smart Polish`
2. AutoEdit default apply behavior: `Auto Replace`
3. Rewrite default intensity: `Light`
4. Translation placement: inside `Auto Edit`
5. Dictionary strategy: `Manual + Auto Learn`, with `Review Required` enabled by default

## Three-layer architecture (final)

1. Stream layer
- ASR native partial revision (provider-side hypothesis updates)
- Client merge/dedupe/in-place replacement (stable input-field typing)
- Goal: low latency, smooth live text

2. Finalize layer
- ASR-native finalization once stop/release happens
- Goal: whole-utterance ASR-final text (non-LLM)

3. AutoEdit/Polish layer
- LLM post-processing after finalize
- Goal: configurable quality upgrades (cleanup/format/rewrite/translation)

## V2 preset model

1. `Pure Transcript`
- Stream + Finalize only
- No AutoEdit

2. `StreamFast`
- Accuracy-first polish with low latency
- Typical options: homophones + punctuation + repetition cleanup

3. `Smart Polish` (default)
- Accuracy + cleanup + formatting + light rewrite

4. `Deep Edit`
- Full quality profile (strong rewrite and advanced structure refinement)

5. `Custom`
- User manual toggle combination

## AutoEdit option groups

1. Accuracy
- Homophones
- Terminology normalization (via dictionary context)

2. Cleanup
- Remove filler words
- Remove repetitions

3. Formatting
- Punctuation
- Sentence and paragraph segmentation

4. Rewrite
- Intensity: off / light / medium / strong

5. Translation
- Enabled/disabled
- Target language: keep source / English / Chinese Simplified

6. Workflow
- Apply behavior: auto replace / diff confirm (UI placeholder path)
- Dictionary auto-learn behavior and review policy

## Dictionary strategy

1. Auto-learn enabled by default
2. Review-required enabled by default
3. Runtime correction context uses:
- Manual terms only when review-required is ON
- Manual + auto-added terms when review-required is OFF

This keeps quality stable while still collecting candidates automatically.

## Stream vs Finalize clarification

1. Stream revision is continuous and incremental (during speech)
2. Finalize is one-shot ASR final text reconciliation at stop
3. AutoEdit is separate LLM pass after finalize

## Implementation status (this batch)

1. Shared model updates
- Added V2 preset and option enums
- Expanded correction options for cleanup/rewrite/translation

2. Settings store updates
- `AppSettings` and `MacAppSettings` now persist V2 options and defaults
- Default values aligned with decisions above

3. Runtime updates
- Dictionary auto-learn strategy wired into correction context and auto-add behavior
- StreamFast iOS polish options aligned with low-latency intent

4. UI updates
- macOS and iOS settings upgraded toward V2 controls (preset + advanced toggles)

## Validation checklist

1. Build
- EchoMac build
- iOS app build

2. Tests
- Swift package tests

3. Manual checks
- Stream realtime typing stability
- Finalize completion correctness
- AutoEdit trigger/apply correctness
- Trace/audit event visibility

## Release prep updates (2026-02-22)

1. Release preflight automation upgraded
- `scripts/release_preflight.sh` now validates:
  - Bundle IDs (iOS / keyboard / macOS)
  - Team ID
  - Dynamic build + marketing versions (project vs plist)
  - Required iOS/macOS plist keys for submission
  - Distribution certificates and provisioning profiles (legacy + modern Xcode paths)
  - Optional ASC API key presence (warn-only)

2. App Store kit docs aligned to current project identifiers
- Unified macOS bundle ID to `com.xianggui.echo.mac`
- Unified install path docs to `/Applications/Echo.app`
- Added final go-live runbook:
  - `docs/app-store-kit/07-pre-submit-final-checklist.md`

3. Pre-submit consistency hardening
- Fixed iOS keyboard extension version mismatch:
  - `iOS/EchoKeyboard/Info.plist` `CFBundleVersion` updated to `2`
- Generated release prep report:
  - `reports/release-prep-2026-02-22.md`

## Edith Release Prep (2026-02-22 continuation)

1. Parallel prep while Codex completes UI
- Created comprehensive release checklist:
  - `RELEASE_CHECKLIST_v1.0.0.md`
- Created release branch automation script:
  - `scripts/release-prep-branch.sh`

2. Current blockers identified
- Missing: Apple Distribution certificate
- Missing: Mac Installer Distribution certificate
- Missing: Provisioning Profiles (App Store distribution)
- Pending: Codex UI changes completion (~30 min)

3. Next immediate actions
- Acquire Distribution certificates via Xcode
- Execute release branch script after Codex commit
- Archive and upload builds
- Complete App Store Connect submission
