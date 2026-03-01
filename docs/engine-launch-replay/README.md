# Echo 键盘唤醒链路与回归记录（2026-02-28）

本目录用于保存**可回滚**的试验记录，避免“本地修补覆盖真相”。

## 目标

1. 外部键盘点击 `Tap to speak` 后，主 App 可被打开（冷启动也适用）。
2. App 打开后自动进入语音状态，录音开始并可在 1 秒内回到输入框。
3. 回到输入框后可在同一键盘内反复 Start/Stop，不需二次跳转。
4. 维护可复现的故障日志与判断边界，便于回归。

## 当前状态（截至 2026-02-28）

- `VoiceInputTrigger.open(url:)` 已修复为：
  - 优先使用 `extensionContext.open(...)`
  - 若超时无回调，自动尝试 Runtime `UIApplication` 打开
  - 再尝试 responder/`UIInputViewController` 兜底
- 这样可避免在 iOS 18+ 上“extensionContext 没回调却已发起打开”导致的误判失败。
- `swift test --package-path Packages/EchoCore` 通过（84 tests）。
- `xcodebuild build -project Echo.xcodeproj -scheme Echo -destination 'generic/platform=iOS'` 通过。

## 已发生的回退点（待验证）

- 仍需确认“`Tap to speak` -> 主 App 跳转成功率”在真实机上是否稳定：
  - 需用系统日志确认 `open:` 和 `onOpenURL` 路径是否命中。
- 仍需确认“录音结束后自动回跳行为”在真实场景（无返回按钮时）是否稳定。
- 回跳失败时，主链路仍依赖：
  - 键盘侧保存 host bundle/PID 到 `AppGroupBridge`
  - 主 App 使用 `openAppByBundleID` 或 PID 回退，再 `suspend()`

## 下一步验收（建议）

1. 在真实设备做两组测试：
   - App 进程未启动 -> 点击 `Tap to speak`
   - 切到其他键盘后再切回当前键盘，点击 `Tap to speak`
2. 观察日志关键字：
   - 键盘端：`openMainAppForVoice`, `extensionContext.open`, `openURLFromExtension`
   - 主 App 端：`onOpenURL`, `handleVoiceDeepLink`, `autoReturnToHostApp`
3. 若任一场景再次失效，回滚到该目录里该时间点代码并记录复现条件。

## 链路图（简化）

- 键盘按钮 -> `VoiceInputTrigger.triggerVoiceInput`
- 非直连态 -> `openMainAppForVoice` -> `AppGroupBridge.setPendingLaunchIntent(.voice)`
- `open(url)` 发起 URL 启动；待 ACK（`hasRecentLaunchAcknowledgement`）
- 主 App 打开 -> `AppURLBridge.application(open:options:)` 或 `onOpenURL`
- `MainView.consumeKeyboardLaunchIntentIfNeeded` -> `handleVoiceDeepLink`
- 录音状态回传 -> 键盘端消费 `dictationState`/Streaming

