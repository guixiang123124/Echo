# Echo 流式转译功能实现计划（2026-02-19）

## 目标
实现“点击即录音、边说边出字、停止后快速收敛”的稳定流式体验，支持：
- Streaming 默认引擎：Volcano
- Batch 默认引擎：Deepgram（可切 OpenAI）
- iOS + macOS 双端一致行为

---

## 当前状态（已完成）

### 基础能力
- Deepgram / Volcano 流式 API 线下 smoke 均可跑通。
- 登录链路已恢复（Google + Apple）。

### 已落地修复（关键 commit）
- `75a2b1c`：iOS 接入流式路径 + 实时 partial 更新输入框。
- `054468f`：macOS 流式 final 为空时 fallback 到 batch 兜底。
- `918e008`：Deepgram 中文场景增加 language hint（zh-CN/zh-TW）。
- `e50761a`：macOS 录音胶囊显示实时 partial（提升“实时感”可见性）。

---

## 当前问题（待攻克）

1. **Deepgram（B）中文识别偏英文乱码**
   - 现象：英文可识别，中文不稳定。
   - 已缓解：显式 language hint（`918e008`）。
   - 待验证：真实场景下是否明显改善。

2. **Volcano（C）stream 体验像 batch**
   - 现象：用户体感不是持续出字，而是结束后集中出字。
   - 可能原因：
     - 短句导致 partial 稀疏
     - UI 只在特定时机刷新
     - provider 端 partial 回调频率低

3. **短句流式偶发空转录**
   - 现象：`Streaming returned empty transcription`。
   - 已缓解：空 final 自动 fallback batch（`054468f`）。
   - 待优化：减少 fallback 触发率本身。

## 2026-02-20 追加修复（已落地）

已完成两处第一优先级修复：

1) **Volcano 流式体验**
   - 文件：`Packages/EchoCore/Sources/EchoCore/ASR/VolcanoStreamingSession.swift`
   - 变更：
     - `result_type` 从 `"full"` 改为 `"partial"`，提升“边说边出字”颗粒度。
     - 增加 `parseServerResult`，兼容更多 final 标记（`is_final` / `final` / `status` / `utterances.definite` / `utterances.final`）。
     - `stop()` 增加带上限的最终结果等待（2.2s，80ms 间隔），减少短音频 stop 后立刻收不到 final 的概率。
     - `stop()` 当前返回最后一次最终帧，供上层在本地再决定 fallback 或直接入库。
   - 结果预期：
     - 减少“流式像 batch”体感；
     - 降低短句场景 fallback 到 batch 触发频率。

2) **Deepgram 中文语言码**
   - 文件：`macOS/EchoMac/Services/VoiceInputService.swift`
   - 变更：`deepgramLanguageCode(from:)` 的 `zh-CN` 从 `"zh"` 改为 `"zh-CN"`，并统一与服务端模型参数兼容。

## 回归验证建议（下次执行）
- Deepgram 逐句：`zh-CN` 与 `en-US` 分别录 10 句短语，检查是否仍出现空 final。
- Volcano 逐句：短句（2-3s）和中句（6-8s）各 10 次，观察 partial 连续性 + stop 时 final 收敛延迟（目标 <2.5s）。
- 如果仍出现 empty final，再切回 batch fallback 的日志计数应当下降或有清晰错误码。

## 2026-02-20 当前推进（已落地复核）

- 验证与构建
  - `swift test --package-path Packages/EchoCore`：通过
  - `xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16e' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build`：通过
  - `xcodebuild -project Echo.xcodeproj -scheme EchoMac -destination 'platform=macOS' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build`：通过

- 本轮落地
  - iOS 流式 fallback 兜底与指标日志已补齐（文件：`iOS/EchoApp/Views/VoiceRecordingView.swift`）
    - 空 final → 批量转写回退；
    - `streaming_metrics` 日志补全 provider/mode/fallback/first_partial_ms/first_final_ms。
  - Deepgram provider 编译修复（文件：`Packages/EchoCore/Sources/EchoCore/ASR/DeepgramASRProvider.swift`）
    - 补齐 `receiveLoop(task:)` 闭包；
    - 健康检查闭包返回类型显式化，避免推断错误。
  - macOS 侧默认语言与流式回退逻辑保持可用（`macOS/EchoMac/Services/VoiceInputService.swift`）。

- 下个循环建议立即推进
  1. 在 `RecordingStore` 加 `stream_mode/first_partial_ms/first_final_ms/fallback_used/error_code` 并做 schema 迁移。
  2. 新增回归脚本记录：partial 首次可见时延、final 收敛时延、空 final 与 fallback 率。
  3. 将上述指标接入历史页（若展示）或运维报表，方便按 Provider 对比。

## 2026-02-20 继续推进（已落地）

- 已完成：
  1. `RecordingStore`（iOS Core + macOS）schema 增补并完成迁移：
     - `stream_mode`
     - `first_partial_ms`
     - `first_final_ms`
     - `fallback_used`
     - `error_code`
  2. `saveRecording(...)` 扩展上述字段参数（包含默认值），并同步补齐插入/查询映射。
  3. iOS `VoiceRecordingView`：
     - 成功路径记录 `streamMode/firstPartial/firstFinal/fallbackUsed` 到本地库
     - 错误路径写入 `stream_mode` 与 `error_code`
  4. macOS `VoiceInputService`：
     - 补充 `streamingStartDate` 与 `streamingFirstPartialMs/streamingFirstFinalMs`
     - 采集流式首包/首 final 时间，写入本地库
     - 成功与失败路径都回填 `streamMode/fallback/error_code`
- 已知影响：
  - 仅本地存储字段扩展，不影响服务端上传 payload（如需云端透传，可在 `CloudSyncService`/`CloudRecording` 后续扩展）
- 建议下一步执行（本地）：
  - 增加一条 `scripts/streaming-metrics-report.swift`（或 shell+sqlite）脚本，对 `recordings` 表计算：
    - 空 final 率
    - fallback 率
    - 首 partial / 首 final 中位时延（按 provider 分桶）

## 2026-02-20 回归闭环（新增）

- 已完成：
  - `scripts/streaming-metrics-report.py`
  - `scripts/streaming-metrics-report.sh`
  - 功能点：
    - 自动发现数据库（macOS + iOS 模拟器）或手动 `--db` 指定
    - 计算总量/成功率/错误率/空转写率/fallback 率
    - 计算首 partial 与首 final 的平均值与中位数/P90（按 provider + mode 汇总）
    - 导出 markdown 与 json 报表到 `reports/streaming/`
  - 建议执行（回归）：
  - `./scripts/streaming-metrics-report.sh --days 7`
  - `./scripts/streaming-metrics-report.sh --platform ios`
  - `./scripts/streaming-metrics-report.sh --db ~/Library/Application\\ Support/Echo/echo.sqlite`

## 2026-02-20 回归执行（脚本联调）

- 已执行：
  - `./scripts/streaming-metrics-report.sh --days 7`
- 结果：
  - 生成报表：
    - `reports/streaming/streaming-metrics-YYYYMMDDTHHMMSSZ.md`
    - `reports/streaming/streaming-metrics-YYYYMMDDTHHMMSSZ.json`
  - 当前样本量：`0`（本地最近 7 天数据库中无转写记录）
- 后续动作：
  - 需要在一次实际麦克风录音后复测，产出包含 >0 样本的真实 baseline；
  - 将结果存入同一目录并贴到本页以便与后续版本 diff。
- 近期建议：
  - 把回归脚本加入日常验证清单（iOS 与 macOS 各测一轮）：
    - 录 2~3 分钟短句 + 中句混合；
    - 生成 `--days 1` 与 `--platform mac/ios` 两套报告；
    - 记录 `empty_final_rate` 与 `fallback_rate` 阈值（例如要求 `< 3%` 作为第一阶段目标）。

---

## 实现计划（分阶段）

## Phase A（今晚）：体验闭环
1) 双端统一流式状态机
- 状态：`idle -> listening(streaming) -> finalizing -> ready`
- 明确区分 partial / final 更新路径。

2) UI 实时反馈增强
- macOS：录音胶囊显示 partial（已做，继续微调文案/节奏）。
- iOS：输入框持续显示 partial，停止后替换为 final（已做，继续校验边界）。

3) 失败兜底一致化
- 空 final -> batch fallback（macOS 已做；iOS 视回归结果补齐）。

## Phase B（今晚）：可观测性与定位
1) 结构化日志（每次录音）
- provider
- mode(batch/stream)
- first_partial_ms
- first_final_ms
- total_ms
- fallback_used
- error

2) 回归数据落库
- 从 `echo.sqlite` 增补字段（若需要）用于 stream 统计。

## Phase C（今晚）：上线闸门
1) ABC 回归（至少 3 轮）
- A: OpenAI + Batch（基准）
- B: Deepgram + Stream（中文）
- C: Volcano + Stream（中文）

2) 通过标准
- B/C 至少有可见实时 partial
- 停止后能稳定收敛 final
- 无阻断级错误弹窗

---

## 默认策略（当前版本）
- Batch 默认：Deepgram
- Stream 默认：Volcano
- 允许一键切换与快速回退

---

## 与 Coding App 协作要求（重要）

如果 Coding App 做了任何改动，必须同步以下信息：
1) 改动文件路径
2) 改动目的
3) commit hash
4) 本地验证命令与结果
5) 是否影响默认引擎策略

建议实时记录到：
- `Echo/docs/STREAMING-WORKLOG-2026-02-19.md`

### Worklog 模板
```md
## HH:mm
- Author: <agent/name>
- Change: <what>
- Files: <path1, path2>
- Commit: <hash>
- Verify: <command + result>
- Risk/Follow-up: <notes>
```

---

## 当前最优分工
- Edith：快速修复 + 验证 + 收口
- Coding App：慢速深入排查（stream callback频率、状态机一致性、日志结构化）
- Xiang：真实设备体验评测（体感速度/稳定性）
