# PROJECT_STATE.md — Current Status

*Updated: 2026-02-28*
*Branch: `feature/rebuild-from-0225` | Latest: `9000ff1`*

## Completed

### Core Infrastructure
- [x] DarwinNotificationCenter (cross-process signals)
- [x] AppGroupBridge streaming IPC (partial text, dictation state, session ID)
- [x] ASRProviderResolver (extracted from VoiceRecordingViewModel)
- [x] BackgroundDictationService (state machine: idle→recording→transcribing→finalizing)
- [x] BackgroundDictationOverlay (floating recording indicator in main app)
- [x] Embedded encrypted Volcano API keys (AES-256-GCM)
- [x] RemoteLogger UDP system for iOS wireless debugging

### Keyboard Extension
- [x] Conditional voice button (Darwin toggle vs URL Link)
- [x] Incremental text injection via textDocumentProxy
- [x] Host PID detection via `_hostProcessIdentifier`
- [x] URL opening via UIApplication runtime access (iOS 18+ workaround)

### macOS
- [x] Volcano streaming confirmed working (Feb 28 rebuild)
- [x] UserDefaults-based diagnostics for sandboxed debugging
- [x] Startup credential verification logging

### Auto-Return (iOS)
- [x] Host PID passthrough (extension → bridge → main app)
- [x] LSApplicationWorkspace.openApplicationWithBundleIdentifier
- [x] sysctl KERN_PROC_PID → process name → app matching (deployed, untested)

## In Progress

### iOS Auto-Return to Third-Party Apps
- sysctl approach deployed in `9000ff1`, needs real device testing
- If sysctl also fails, need alternative (e.g., `extensionContext.open` navigation)

## Remaining

### High Priority
- [ ] Test sysctl auto-return approach
- [ ] Fix second recording failure (AsyncStream reuse bug — see Feb 27 progress)
- [ ] Enable and test LLM correction pipeline (`correctionEnabled` = 0)

### Medium Priority
- [ ] Customizable final ASR finalization + AutoEdit polish
- [ ] Residence strategy (Never / 15min / 12h engine timeout)
- [ ] Audio interruption handling (phone calls)
- [ ] App-killed cleanup of bridge state

### Low Priority
- [ ] VoiceRecordingView refactor to use ASRProviderResolver
- [ ] VAD auto-sentence-break for long dictation
- [ ] Pipeline parallelization (start LLM before ASR completes)
- [ ] Local Whisper fallback (WhisperKit)

## Known Blockers
- **iOS sandbox**: `proc_pidpath` blocked for other PIDs in both extension and main app
- **iOS 18**: `_hostApplicationBundleIdentifier` returns `<null>` on UIViewController
- **AsyncStream**: Single-consumer limitation causes second recording to fail (needs `resetAudioStream()`)
