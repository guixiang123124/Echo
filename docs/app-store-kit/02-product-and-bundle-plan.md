# 02 产品与 Bundle 规划

## 当前仓库中的 Bundle ID
- iOS App: `com.xianggui.echo.app`
- iOS Keyboard Extension: `com.xianggui.echo.app.keyboard`
- macOS App: `com.xianggui.echo.mac`

## 建议保持不变的关键项
- Bundle ID（不要频繁改）
- App Group（当前：`group.com.xianggui.echo.shared`）
- App 名称（Echo）

## SKU 规划建议
- iOS 主 App: `echo-ios-main`
- macOS App: `echo-macos-main`

## 上架产品线建议
1. iOS（含键盘扩展）先上一个最小可用版本
2. macOS 菜单栏语音输入单独上架
3. 后续版本再统一功能和数据模型

## 版本号策略
- Marketing Version: `1.0.0`（对外展示）
- Build Number: 当前为 `2`，每次提交 +1

## 命名与本地化建议
- 中文名：`Echo 语音输入`
- 英文名：`Echo Voice Input`
- 副标题突出“语音转文字 + 快速插入”
