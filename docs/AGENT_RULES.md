# AGENT_RULES.md — Guardrails for Future Agents

## Core Principles

1. **Commit before changing.** Never start a refactor or rewrite without committing current work first.
2. **Minimal diff.** Change only what's needed. No drive-by cleanups, no "while I'm here" improvements.
3. **Plan before major change.** Use `/plan` for anything touching 3+ files or changing architecture.
4. **Ask before destructive ops.** Never force-push, hard-reset, delete branches, or overwrite uncommitted changes without explicit user approval.
5. **Preserve architecture.** Do not restructure the module layout, rename public APIs, or change IPC contracts.
6. **Stability over cleverness.** Working code > elegant code. If it works, don't rewrite it.

## File Safety

- Read before editing. Always `Read` a file before using `Edit`.
- Never create new files unless absolutely necessary. Prefer editing existing files.
- Do not create documentation files unless explicitly asked.
- Do not delete files without user confirmation.

## Build & Deploy

- Always build after code changes: verify compilation before claiming "done".
- Use the established build commands (see `PROGRESS_2026-02-28.md`).
- Test on real device when possible — simulator misses sandbox restrictions.
- Use `SYMROOT=/tmp/echo-build-0225` to avoid DerivedData confusion.

## IPC Contracts — DO NOT MODIFY

These are cross-process contracts between the keyboard extension and main app:
- `AppGroupBridge` key names and data formats
- `DarwinNotificationCenter.Name` raw values
- URL scheme routes (`echo://voice`, `echo://settings`)

Changing any of these requires updating BOTH the main app AND the keyboard extension simultaneously.

## Private API Caution

The codebase uses private APIs for iOS keyboard extension functionality:
- `LSApplicationWorkspace` — for opening apps by bundle ID
- `UIApplication.sharedApplication` — from extension context
- `_hostProcessIdentifier` — for detecting host app PID
- `suspend()` selector — for returning to previous app

Do not replace these with "cleaner" alternatives unless the replacement is verified working on iOS 18+.

## Debugging

- iOS: Use `rlog()` (RemoteLogger UDP) for wireless debug logging
- macOS: Use `UserDefaults.standard` for diagnostics (sandbox blocks file writes)
- Never leave `print()` as the only logging — output is lost in production builds and GUI apps

## Testing Strategy

- Keyboard extension behavior can only be verified on a real device
- Simulator does not replicate iOS sandbox restrictions on `proc_pidpath`, `sysctl`, etc.
- Always check UDP logs (`/tmp/echo_logs.txt`) after deploying to device

## Recovery

If code is lost or corrupted:
- Check git reflog for recent commits
- Session transcripts in `~/.claude/projects/` contain full file reads (JSONL format)
- Recovery script: `/tmp/recover_sessions.py` can replay edits from transcripts
- `@v1` backup files in `~/.claude/file-history/` contain pre-session baselines
