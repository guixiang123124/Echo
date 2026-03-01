# PROJECT_CORE.md — Echo Voice-to-Text System

## Goal
Cross-platform (iOS + macOS) voice-to-text app with keyboard extension, multi-provider ASR, real-time streaming, and LLM-powered post-editing.

## Architecture

### Dual Platform
- **iOS**: SwiftUI app + keyboard extension (`EchoKeyboard`)
- **macOS**: AppKit app (`EchoMac`) with global hotkey + Accessibility API text insertion
- **Shared**: `EchoCore` Swift Package (ASR, LLM, settings, audio, IPC)

### ASR Pipeline: Stream → Finalize → Polish
```
RECORD → [Stream: WebSocket partials] or [Batch: collect audio]
STOP   → [Finalize: merge final+partial, optional batch retry]
POST   → [AutoEdit: LLM correction with 5 presets] → insert text
```

### Provider Matrix
| Provider | Stream | Batch | Client-Direct | Backend-Proxy |
|----------|--------|-------|---------------|---------------|
| Volcano  | WSS    | Flash HTTP | Embedded key | Railway polling |
| Deepgram | WSS    | HTTP POST  | Keychain     | Railway polling |
| OpenAI   | N/A    | HTTP POST  | Keychain     | Railway proxy  |

### Dual API Mode
- `clientDirect`: Keys in Keychain, direct provider WebSocket/HTTP
- `backendProxy`: Keys on Railway server, HTTP polling proxy

### IPC (iOS Keyboard ↔ Main App)
- **Darwin Notifications**: Signal-only (start/stop/heartbeat/stateChanged/transcriptionReady)
- **AppGroupBridge**: Shared UserDefaults for data (streaming text, dictation state, session ID)
- **URL Scheme**: `echo://voice`, `echo://settings` for cold launch

### Key Security
- Volcano credentials: AES-256-GCM encrypted in `EmbeddedKeyProvider.swift`
- HKDF-SHA256 derivation: master="echo-embedded-v1", salt="com.xianggui.echo"
- Keychain storage: service="com.echo.apikeys", `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`

## Bundle IDs
- iOS App: `com.xianggui.echo.app`
- Keyboard: `com.xianggui.echo.app.keyboard`
- macOS: `com.xianggui.echo.mac`
- App Group: `group.com.xianggui.echo`

## DO NOT Change
- `EmbeddedKeyProvider` encryption parameters (master secret, salt, info string)
- `AppGroupBridge` key names (cross-process IPC contract)
- `DarwinNotificationCenter` notification names (cross-process signal contract)
- `SecureKeyStore` service name "com.echo.apikeys"
- Bundle IDs (provisioning profiles depend on them)
- `ASRProvider` protocol interface (3 providers + resolver depend on it)
- `VolcanoStreamingSession` binary protocol format (Volcano API contract)
