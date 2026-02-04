# 02 产品与 Bundle 规划

## 当前仓库中的 Bundle ID
- iOS App: `com.typeless.app`
- iOS Keyboard Extension: `com.typeless.app.keyboard`
- macOS App: `com.typeless.mac`

## 建议保持不变的关键项
- Bundle ID（不要频繁改）
- App Group（当前：`group.com.typeless.shared`）
- App 名称（Typeless）

## SKU 规划建议
- iOS 主 App: `typeless-ios-main`
- macOS App: `typeless-macos-main`

## 上架产品线建议
1. iOS（含键盘扩展）先上一个最小可用版本
2. macOS 菜单栏语音输入单独上架
3. 后续版本再统一功能和数据模型

## 版本号策略
- Marketing Version: `1.0.0`（对外展示）
- Build Number: `1` 起，每次提交 +1

## 命名与本地化建议
- 中文名：`Typeless 语音输入`
- 英文名：`Typeless Voice Input`
- 副标题突出“语音转文字 + 快速插入”
