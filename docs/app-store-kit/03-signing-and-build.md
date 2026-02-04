# 03 签名与构建（解决“每次更新都要重新授权”）

## 核心结论
如果你每次构建后都要重新授予 Accessibility / Input Monitoring / Microphone，通常是因为 App 身份不稳定（例如 ad-hoc 签名）。

## 目标状态
- 使用固定 Team 的正式签名（非 ad-hoc）
- 固定 Bundle ID
- 固定安装路径：`/Applications/EchoMac.app`

## Xcode 配置步骤（macOS / iOS 都建议）
1. 打开 target -> Signing & Capabilities
2. 勾选 Automatically manage signing
3. Team 选择你的固定 Team ID
4. Signing Certificate:
   - Debug: `Apple Development`
   - Release: `Apple Distribution`（App Store 构建）
5. 确认 Bundle Identifier 不变

## 当前 macOS 必要能力（按当前代码）
- App Sandbox
- Audio Input
- Network Client

## 当前权限文案检查（macOS）
- `NSMicrophoneUsageDescription`
- `NSInputMonitoringUsageDescription`

## 验证命令
```bash
codesign -dv --verbose=4 /Applications/EchoMac.app 2>&1 | sed -n '1,80p'
```

期望看到：
- `Signature` 不是 `adhoc`
- `TeamIdentifier` 有固定值

## 升级后首次清理建议（只做一次）
1. 系统设置里删除旧 Echo 权限条目
2. 仅保留 `/Applications/EchoMac.app` 一份
3. 重新授权一次后，后续更新通常不再重复弹窗
