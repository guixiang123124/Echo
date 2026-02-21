# Echo Agent Progress Log

This file is the shared coordination log for multi-agent work.

## 2026-02-19 10:48 PST — Codex

### Scope
- Switched to workspace repo and completed a full project audit pass.

### Project Path
- `/Users/xianggui/.openclaw/workspace/Echo`
- Xcode project: `/Users/xianggui/.openclaw/workspace/Echo/Echo.xcodeproj`

### What Was Verified
- `swift test` in `Packages/EchoCore` passed (75 tests).
- iOS simulator build succeeded:
  - `xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16e' build`
- macOS build succeeded:
  - `xcodebuild -project Echo.xcodeproj -scheme EchoMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- Backend checks succeeded after dependency install:
  - `npm run typecheck`
  - `npm run build`

### Findings
- Repository is currently dirty; active modifications exist in Info.plists:
  - `iOS/EchoApp/Info.plist`
  - `macOS/EchoMac/Info.plist`
- Notable document updates from today are present under `docs/`:
  - `docs/asr-model-research-2026-02.md`
  - `docs/asr-roadmap-2026Q1.md`
  - `docs/deployment/GOOGLE_OAUTH_SETUP_CHECKLIST.md`
  - `docs/deployment/ASR_PROVIDER_KEYS.md`
  - website copy drafts in `docs/website-*.md`

### Coordination Note
- Use this file (`docs/AGENT_PROGRESS_LOG.md`) as the single shared progress ledger for subsequent updates.

## 2026-02-19 10:52 PST — Codex

### Sync Scan (Local + GitHub)
- Ran:
  - `git fetch --all --prune`
  - `git status -sb`
  - `git branch -vv`
  - `git log --oneline --decorate --graph --all -n 20`
  - branch divergence checks against `main`

### Current Result
- `main` is aligned with `origin/main`.
- No remote branch has commits ahead of `main` in current local refs.
- Existing side branches (`edith/*`) are behind `main` and do not require merge now.
- Working tree is still dirty with active in-progress edits from parallel workstreams:
  - `Packages/EchoCore/Sources/ASRStreamSmokeCLI/main.swift`
  - `Packages/EchoCore/Sources/EchoCore/ASR/DeepgramASRProvider.swift`
  - `Packages/EchoCore/Sources/EchoCore/ASR/VolcanoStreamingSession.swift`
  - `Packages/EchoCore/Sources/EchoCore/Auth/EchoAuthSession.swift`

### Ongoing Rule (agreed)
- Before each implementation cycle, always perform:
  - local status scan
  - remote fetch scan
  - branch divergence check
  - merge/review decision for parallel branches

- 2026-02-20  Re-audit auth flows: fixed Google/Apple login reliability for user report.
  - iOS Login: added missing iOS Google OAuth URL scheme (com.googleusercontent.apps....) in `iOS/EchoApp/Info.plist` and `project.yml` for SDK callback stability.
  - iOS Google sign-in: hardened presenter fallback to avoid nil active window in sheet/scene states.
  - iOS Apple sign-in: adds explicit error when nonce is missing instead of silent return.
  - Next check: Apple/Google login now depends on configured Cloud Sync URL and backend health (`/healthz`). Verify by opening Auth sheet and testing both providers end-to-end.

- 2026-02-20  Mac login hardening pass.
  - macOS: added explicit Google/Apple sign-in failure surfacing in settings auth sheet.
  - macOS: Google sign-in now validates configured GOOGLE_CLIENT_ID_MAC before calling SDK; returns explicit "Google Client ID is not configured" instead of proceeding.
  - macOS: Google sign-in now validates non-empty token before backend exchange.
  - macOS: Apple sign-in now reports "Apple sign-in missing nonce" when nonce state is unavailable, instead of silently returning.
  - Result: macOS auth no longer fails silently in edge states (no presenting window / missing token / missing nonce). Please retest both providers with configured Cloud API URL.

## 2026-02-20 19:30 PST — Codex

### Scope
- Streaming reliability hardening on macOS before broader roadmap expansion.

### Repository
- Repo: `/Users/xianggui/.openclaw/workspace/Echo`

### Changes Applied
- `Packages/EchoCore/Sources/EchoCore/ASR/VolcanoStreamingSession.swift`
  - `result_type` switched to `"partial"` to improve partial update cadence.
  - Stream stop now waits briefly and returns captured final result when available.
  - Final detection now handles `is_final`, `final`, `status`, and utterance-level markers.
  - Latest final result is held thread-safely for stop-time fallback logic.
- `macOS/EchoMac/Services/VoiceInputService.swift`
  - `deepgramLanguageCode(from:)` changed for `zh-CN` to `"zh-CN"` for stream/batch consistency.

### Validation
- Pending immediate rerun after edits:
  - `swift test` (Packages/EchoCore)
  - macOS stream smoke/recording path with short CN + EN phrases.

## 2026-02-20 04:20 UTC — Codex

### Scope
- 按 `docs/STREAMING-IMPLEMENTATION-PLAN-2026-02-19.md` 落地“流式回归脚本”阶段。

### Implementation
- 新增可执行脚本：
  - `scripts/streaming-metrics-report.py`
  - `scripts/streaming-metrics-report.sh`
- 覆盖能力：
  - 自动发现本机数据库（macOS + iOS Simulator）
  - 空 final / fallback 率
  - 首 partial、首 final 的均值、中位数、P90
  - Provider、stream_mode、error_code 分桶
  - 支持 `--days` 与 `--db`，支持窗口限制

### Validation
- `python3 -m py_compile scripts/streaming-metrics-report.py`
- `./scripts/streaming-metrics-report.sh --days 7`

### Output
- 输出到 `reports/streaming/`：
  - `streaming-metrics-<timestamp>.md`
  - `streaming-metrics-<timestamp>.json`

## 2026-02-20 20:08 UTC — Codex

### Scope
- 按照 `docs/STREAMING-IMPLEMENTATION-PLAN-2026-02-19.md` 继续推进“回归闭环”。

### Actions
- 读取并复核 `docs/STREAMING-IMPLEMENTATION-PLAN-2026-02-19.md`；
- 执行 `./scripts/streaming-metrics-report.sh --days 7` 验证回归链路。

### Findings
- 报表已成功产出到 `reports/streaming/streaming-metrics-20260220T040817Z.md/json`；
- 当前样本库返回 `recordings = 0`（尚未有本地真实转写样本，因此缺少 KPI 可比对）。

### Next Step
- 在真实录音后复跑同一命令，建立首版可对比基线；
- 用 `--platform mac`、`--platform ios` 与 `--days 1` 产出双端对比。

## 2026-02-20 23:20 UTC — Codex

## 2026-02-21 00:00 UTC — Codex

### Scope
- EchoMac Deepgram / Volcano 流式链路二次修复与可观测性补齐（针对输入实时性与尾段掉字）。

### 实施
- Deepgram (`Packages/EchoCore/Sources/EchoCore/ASR/DeepgramASRProvider.swift`)
  - 收口策略增强：当 `final` 非空但明显短于累积 `partial` 时，优先使用 partial，并打标 `partial-fallback-short-final`。
  - 空 `final` 且有 `partial` 时不回吞有效 partial。
- Volcano (`Packages/EchoCore/Sources/EchoCore/ASR/VolcanoASRProvider.swift`, `Packages/EchoCore/Sources/EchoCore/ASR/VolcanoStreamingSession.swift`)
  - `resolvedStreamingResourceId()` 仍强制 `.sauc` 体系资源；非流式资源会重映射并记录日志。
  - `VolcanoStreamingSession` 停止收口输出 `stop result source`，并新增 `partial-fallback-short-final` 分支。
- EchoMac 流式交互与存储 (`macOS/EchoMac/App/AppDelegate.swift`, `macOS/EchoMac/Services/VoiceInputService.swift`, `macOS/EchoMac/Services/TextInserter.swift`, `macOS/EchoMac/Services/RecordingStore.swift`)
  - 流式插入失败保持 `focus/selection/accessibility/state` 细分类日志。
  - 保存记录 `stream_mode / first_partial_ms / first_final_ms / fallback_used / error_code` 全量写入（`-1` 表示未触发的默认值，避免空字段）。
- 文档核对（外部）
  - 快速确认火山批/流式路径差异：文件极速版 `POST /api/v3/auc/bigmodel/recognize/flash`，流式输入相关路径/资源在 `.../sauc/...` 体系（示例 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async` 与 `volc.bigasr.sauc.*`）。

### Scope
- 修复 Volcano 流式协议序号导致的服务端 `decode ws request failed` 错误（`autoAssignedSequence (1) mismatch sequence in request (0)`），并回归验证。

### Changes
- `Packages/EchoCore/Sources/EchoCore/ASR/VolcanoStreamingSession.swift`
  - 将 `nextOutboundSequence` 的初始值改为 `1`（连接建立与会话开始时均重置为 1），保持首帧请求使用服务端期望的首序号。

### Validation
- `swift run --package-path Packages/EchoCore ASRStreamSmokeCLI deepgram /tmp/echo_test.wav`
  - 输出见常规 partial / final，未阻塞。
- `swift run --package-path Packages/EchoCore ASRStreamSmokeCLI volcano /tmp/echo_test.wav`
  - 不再出现 `autoAssignedSequence` 解码失败；
  - 能持续收到 partial；
  - 输出最终转写（短音频场景可继续走 batch fallback）。
- `swift test --package-path Packages/EchoCore`
  - 全部测试通过（0 失败）。

### Follow-up
- 下次复盘建议：在用户实录场景下跑一次 `./scripts/streaming-metrics-report.sh --platform mac`，确认 `empty_final_rate` / `fallback_rate` 下降。
