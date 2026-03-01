# PITFALLS.md — Lessons & Constraints

## Session & Code Safety

- **Never do large-scale rewrites in a single session.** Session 4 rewrite destroyed 2 days of uncommitted work. Always commit incrementally.
- **Never trust context compaction.** After compaction, the agent may lose awareness of prior changes and overwrite working code with plan-based re-implementation.
- **Commit before any refactoring.** All worktree work in `loving-ardinghelli` was lost because nothing was committed.
- **File recovery**: Pre-session file contents can be extracted from JSONL transcripts (`Read` tool results). Recovery script: `/tmp/recover_sessions.py`.

## iOS Sandbox Restrictions

- `proc_pidpath()` returns 0 for other processes' PIDs — blocked in **both** keyboard extension AND main app.
- `_hostApplicationBundleIdentifier` returns `<null>` on iOS 18 for keyboard extensions.
- `_hostBundleID` and `hostBundleID` also return `<null>`.
- `_hostProcessIdentifier` WORKS — returns valid host PID from keyboard extension.
- Keyboard extensions cannot access microphone. Must redirect to main app.
- `extensionContext.open()` alone does not reliably open URLs on iOS 18. Use `UIApplication.shared` via runtime selector.

## macOS Sandbox Restrictions

- `print()` output is lost when launching GUI app via `open`.
- `NSLog()` output is filtered by macOS unified logging — not visible in Terminal.
- File writes to `/tmp/` are blocked by sandbox.
- **Workaround**: Write diagnostics to `UserDefaults.standard`, read via `defaults read <bundle-id>`.

## macOS UserDefaults Confusion

- Two domains exist: `com.echo.mac` (old build) and `com.xianggui.echo.mac` (current app).
- Always verify bundle ID: `defaults read /Applications/Echo.app/Contents/Info.plist CFBundleIdentifier`.
- The running app uses its actual bundle ID domain, not an arbitrary one.

## Audio Engine

- `AsyncStream` is single-consumer. After first `recordingTask` is cancelled, a new `for await` on the same stream may not receive new chunks.
- Fix: Implement `resetAudioStream()` to create fresh `AsyncStream` + `Continuation` before each recording session.
- `AVAudioSession` conflict (OSStatus 560557684): Do not configure audio session from two places simultaneously.
- `idleEngine()` noop tap may not keep iOS from suspending the app — monitor this.

## Build & Deploy

- Multiple DerivedData directories exist. Always verify the correct one for your worktree/branch.
- Xcode may cache old builds. Use `SYMROOT=/tmp/echo-build-0225` to force clean output path.
- When deploying via `xcrun devicectl`, the device must be unlocked and on the same WiFi.

## Volcano API

- Stored endpoint in Keychain/UserDefaults is the batch HTTP URL — irrelevant for streaming.
- `startStreaming()` uses hardcoded WSS endpoint: `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`.
- Resource ID auto-maps: `volc.bigasr.auc_turbo` → `volc.bigasr.sauc.duration` for streaming.
- BackendProxyASRProvider "streaming" is actually 750ms HTTP polling — not real WebSocket.

## Private API Usage

- `LSApplicationWorkspace` / `LSApplicationProxy` — private, works on iOS but may break in future OS versions.
- `UIApplication.perform(sharedApplication)` from extension — standard practice for third-party keyboards but technically private.
- `suspend()` selector on UIApplication — undocumented, returns to previous app for system apps only.
