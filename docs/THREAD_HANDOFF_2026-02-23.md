# Echo 项目交接文档（2026-02-23）

## 1) 当前仓库与目录（唯一真源）

- 项目仓库：`/Users/xianggui/.openclaw/workspace/Echo`
- Xcode 项目：`/Users/xianggui/.openclaw/workspace/Echo/Echo.xcodeproj`
- 历史遗留目录 `/Users/xianggui/Downloads/Typeless` 已不再使用，不再作为源码来源。

## 2) 本轮目标

- 修复 iOS 外部 App 的自定义键盘中 `Setting` / `Tap to Speak` 按钮无响应问题。
- 保持 macOS + iOS 的 V2 语音链路与现有 Stream/Finalize/Polish 架构不回退。
- 输出可直接复用的交接文档，便于切新 thread 继续。

## 3) 最近变更（已落盘）

### 3.1 代码修复

- `iOS/EchoKeyboard/KeyboardView.swift`
  - 将顶部按钮从 `onTapGesture` 改为 `Button` 事件，增强按钮兼容性与触发一致性。
  - `Settings` 与 `Tap to Speak` 按钮不再在界面层强制拦截“未命中共享容器”路径，先尝试打开主 app，再按结果显示提示。
  - 保留 `openMainApp...` 的 toast 与失败回显。

- `iOS/EchoKeyboard/VoiceInputTrigger.swift`
  - 增强主 app 打开链路：
    - 保留现有 `extensionContext.open`。
    - 增加对 `UIInputViewController` 级别 `openURL:completionHandler:` selector 的兜底尝试。
    - 保留 responder-chain 降级方案。
  - 超时分支不再立即 hard fail，继续尝试 responder 兜底，再做确认等待。

### 3.2 其他背景性修复基线（非本次改动）

- iOS/ macOS App Group 与录音链路、日志链路已完成统一。
- Stream/Fast/Finalize/Polish 四层语音架构已在 `AGENT_PROGRESS_LOG.md` 与 `docs/AGENT_PROGRESS_LOG.md` 里记录。
- `iOS/EchoApp/Views/MainView.swift` 已实现：
  - `onOpenURL` 解析 `echo://voice`/`echo://settings`。
  - App 启动时轮询消费键盘端 pending launch intent。
- 外键盘启动态共享写入/清空 pending intent 的关键字段已在 `AppGroupBridge`。

## 4) Edith 分支确认结论

- 我检查了 `edith/launch-quality-perf` 与 `main` 的提交差异，结果显示 `edith/launch-quality-perf` 50 0（Edith 分支未领先 main）。
- 结论：**Edith 这批提交并未提供你这次外部键盘“无响应”问题的新修复可直接合并点**。
- 当前会聚焦于现有 `main` 分支链路内修复。

## 5) 关键现象复盘（重点）

1. macOS 内 App 内录音与流式转写稳定可用。
2. iOS 外部 App 中，键盘唤起后 `Tap to Speak` / `Setting` 点击常无反应或无可见日志。
3. 该问题更可能发生在：
   - 自定义键盘事件在外部 host app 中的 open-url 触发链路兼容。
   - 触发时 Full Access / App Group 状态判断导致早期拦截。
4. 当前修复方向为“先发起 openURL，再按失败结果反馈，不把 Full Access 作为 hard-block”。

## 6) 需要你继续确认的两类日志（建议你回填）

1. 外部 App 中点击按钮时主控台日志是否出现：
   - `openMainAppVoice called` 或 `openMainAppSettings called`
   - `openViaResponderChain` / `openURL:completionHandler` / `Failed to open URL`
2. 主 App 被带起后，是否有：
   - `MainView` 的 `.onOpenURL` 命中的 `selected deepLink` 现象
   - `AppGroupBridge().markLaunchAcknowledged()` 日志

## 7) 下一步建议（按优先级）

1. 继续加一层“主 App 侧兜底入口”（建议监听 `application(_:open:options:)` 也可），确认 scheme 打开时一定走深链路。
2. 在外部输入时，记录每次按钮点击到 app 打开确认（或失败）所耗时，判断是否为 host 侧延迟。
3. 若仍然无响应，新增第二通道（例如短时复制方案或 app-group 事件轮询唤醒页）作为临时 fallback。

## 8) 当前可直接执行的验证用例

1. 外部 App：长按呼出 Echo Keyboard 后点击 `Settings`，观察能否切到 Echo 设置页。
2. 外部 App：点击 `Tap to Speak`，确认弹出主 app，开始录音并回填输入框。
3. 外部 App：`hasFullAccess` / `AppGroup` 状态显示是否变为可用，不再作为硬拦截条件。
