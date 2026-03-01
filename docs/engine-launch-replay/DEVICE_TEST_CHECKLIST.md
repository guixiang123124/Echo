# 设备测试清单（Tap to Speak 回跳链路）

> 目的：把“是否真的进入 App + 回跳状态”从主观感受变成可复现实验。

## 1. 安装与确认

- 清理旧版本：先删除已装 Echo，再重装测试 build，避免旧版覆盖。
- 进入 `设置 -> 键盘 -> 主键盘 -> Echo`，确认 `允许完全访问` 打开。

## 2. 场景 A：App 已关闭的冷启动

1. 在任意第三方输入框打开 Echo 键盘。
2. 点击 `Tap to speak`。
3. 预期：
   - 主 App 启动到前台 0.5~1s 内返回后台。
   - 键盘里看到录音状态变化。
4. 日志关键词：
   - 键盘：`extensionContext.open` / `openURLFromExtension` / `launch ack for`
   - App：`application(_:open:options:) received`, `handleVoiceDeepLink`, `autoReturnToHostApp`

## 3. 场景 B：后台驻留后再触发

1. 在场景 A 完成后点击停止。
2. 再次点击 `Tap to speak` 直接走热启动路径（`hasRecentHeartbeat` 有效）
3. 预期：主 App 不跳转 / 直接开始/停止录音。

## 4. 场景 C：长时间不操作（如 16 分钟）

1. 等待 15 分钟后再次点击。
2. 若 residence 设置为 `15 minutes`，应触发重新唤醒流程。

## 5. 复盘记录

- 每次测试记录：
  - 设备系统版本
  - 当前分支与 commit
  - 上述场景是否成功
  - 对应日志截图（重点 4-6 行）

