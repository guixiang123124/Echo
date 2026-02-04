# 05 当前仓库上架审计（基于本地代码）

## 关键结论
- 当前本地安装包签名仍是 ad-hoc（会导致权限授权不稳定）。
- macOS 已切到 Whisper 主路径，并使用本地 SQLite 落盘与历史记录。
- iOS 侧仍有 Apple Speech 路径与 `NSSpeechRecognitionUsageDescription`。

## 高优先级项（P0）
1. 固定签名身份
- 现象：`codesign -dv` 显示 `Signature=adhoc`
- 影响：系统把新构建视为不同身份，TCC 权限会重复请求

2. App Store 提审文案与权限用途要完全一致
- macOS 需要明确说明：
  - Microphone：采集语音
  - Input Monitoring：热键监听
  - Accessibility：将转写文本写入当前光标位置

## 中优先级项（P1）
1. `project.yml` 与现代码能力可能存在漂移
- 建议每次改 entitlements 后同步更新 `project.yml`

2. iOS 与 macOS ASR 路线尚未完全统一
- macOS 当前是 Whisper 主路径
- iOS 仍有 Apple Speech 逻辑

## 低优先级项（P2）
1. README 中部分能力描述与当前实现可能不完全一致
- 上架前建议做一轮功能文档校对

## 建议提审顺序
1. 先上 macOS（当前最接近可用）
2. 再上 iOS（补齐语音链路一致性与键盘扩展说明）
