# Echo 上架一步一步（已填好）

> 这是一个「单文件」流程清单，按顺序完成即可。所有可复制字段已经填好。

## 0. 固定字段（直接复制）
- App Name (CN): Echo 语音输入
- App Name (EN): Echo Voice Input
- Category: Productivity
- iOS Bundle ID: com.xianggui.echo.app
- macOS Bundle ID: com.echo.mac
- iOS Keyboard Extension Bundle ID: com.xianggui.echo.keyboard
- App Group ID: group.com.xianggui.echo.shared
- Support Email: support@fashionflow.ai
- Website URL: https://guixiang123124.github.io/Typeless/
- Support URL: https://guixiang123124.github.io/Typeless/support.html
- Marketing URL: https://guixiang123124.github.io/Typeless/
- Privacy Policy URL: https://guixiang123124.github.io/Typeless/privacy.html

## 1. 先开通 GitHub Pages（用于官网/隐私/支持链接）
1. 打开 GitHub 仓库 `guixiang123124/Typeless`
2. 进入 `Settings` → `Pages`
3. Source 选择 `Deploy from a branch`
4. Branch 选 `main`，Folder 选 `/docs`
5. 保存后等待 1~3 分钟
6. 访问以下地址确认可打开：
   - https://guixiang123124.github.io/Typeless/
   - https://guixiang123124.github.io/Typeless/privacy.html
   - https://guixiang123124.github.io/Typeless/support.html

## 2. Apple Developer Program（必须本人完成）
1. 确认 Apple ID 已开启 2FA
2. 访问 Apple Developer Program 并完成付费加入
3. 加入后回到 Xcode，确保能看到 Team ID

## 3. Apple Developer Portal（App ID + App Group）
1. 在 Developer Portal 创建 App ID（iOS）：
   - Bundle ID: `com.xianggui.echo.app`
2. 创建 App ID（Keyboard Extension）：
   - Bundle ID: `com.xianggui.echo.keyboard`
3. 创建 App Group：
   - `group.com.xianggui.echo.shared`

## 4. Xcode Signing（在本机 Xcode 完成）
1. 打开 `Echo.xcodeproj`
2. 选择 Target `Echo`：
   - Bundle Identifier = `com.xianggui.echo.app`
   - Team 选择你的开发者 Team
   - Capabilities 勾选 `App Groups`，选择 `group.com.xianggui.echo.shared`
3. 选择 Target `EchoKeyboard`：
   - Bundle Identifier = `com.xianggui.echo.keyboard`
   - Team 同上
   - App Groups 同上
4. 选择 macOS Target（如 EchoMac）：
   - Bundle Identifier = `com.echo.mac`
   - Team 同上
5. Xcode 顶部选择设备/模拟器并编译运行

## 5. App Store Connect 新建 App
1. 进入 App Store Connect → My Apps → “+”
2. 选择平台 iOS / macOS（按需）
3. 填写基本信息：
   - App Name / Bundle ID / Category 用本文件第 0 节
4. App Information → 粘贴 URL（Website/Support/Privacy）
5. Privacy → 按 `APP_PRIVACY_ANSWERS.md` 勾选

## 6. 提交前检查
1. 打开 `docs/app-store-kit/README.md` 按顺序复核
2. 元数据可直接复制：
   - iOS: `IOS_METADATA.zh-Hans.md` / `IOS_METADATA.en-US.md`
   - macOS: `MACOS_METADATA.zh-Hans.md` / `MACOS_METADATA.en-US.md`
3. 截图脚本：`SCREENSHOT_SHOTLIST.md`
4. 审核备注：`REVIEW_NOTES_TEMPLATE.md`

## 7. 你必须亲自完成的动作
- 支付 Apple Developer Program 年费
- App Store Connect 税务与银行信息
- 最终点击“提交审核”

