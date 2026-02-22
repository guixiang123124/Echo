# 07 最终提审清单（明天上线用）

> 目标：把“可自动完成”与“必须人工完成”彻底分离，提审前 30 分钟按本清单走完。

## A. 今晚先自动完成（可脚本化）

1. 运行预检（证书/签名/版本/Bundle ID/Profiles）
```bash
bash scripts/release_preflight.sh
```

2. 构建 iOS Release（不上传）
```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Release -destination "generic/platform=iOS" build
```

3. 构建 macOS Release（不上传）
```bash
xcodebuild -project Echo.xcodeproj -scheme EchoMac -configuration Release -destination "generic/platform=macOS" build
```

4. 核对安装包身份（避免权限漂移）
```bash
codesign -dv --verbose=4 /Applications/Echo.app 2>&1 | sed -n '1,80p'
```

## B. 明天提审前 30 分钟执行（半自动）

- [ ] 再跑一次 `scripts/release_preflight.sh`，确认 `Fail = 0`
- [ ] Archive iOS:
```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Release -destination "generic/platform=iOS" archive -archivePath /tmp/Echo-iOS-Release.xcarchive
```
- [ ] Archive macOS:
```bash
xcodebuild -project Echo.xcodeproj -scheme EchoMac -configuration Release -destination "generic/platform=macOS" archive -archivePath /tmp/Echo-macOS-Release.xcarchive
```
- [ ] 在 Xcode Organizer 中验证并上传到 App Store Connect

## C. 必须你本人操作（不可自动化）

- [ ] App Store Connect 的税务/银行/协议状态全部为可售状态
- [ ] iOS 与 macOS App 记录绑定正确 Bundle ID
- [ ] 上传并选择最终 build
- [ ] 填写/检查 metadata（标题、副标题、描述、关键词、截图）
- [ ] 填写审核备注（权限用途：Mic/Input Monitoring/Accessibility）
- [ ] 点击 `Submit for Review`

## D. 本仓库当前固定值（已统一）

- iOS Bundle ID: `com.xianggui.echo.app`
- iOS Keyboard Bundle ID: `com.xianggui.echo.app.keyboard`
- macOS Bundle ID: `com.xianggui.echo.mac`
- Team ID: `D7BK236H9B`
- Marketing Version: `1.0.0`
- Build Number: `2`

## E. 失败时只看这 4 类阻塞项

1. 缺 `Apple Distribution` / `Mac Installer Distribution`
2. 缺 provisioning profile
3. Bundle ID 或 Team ID 不一致
4. App Store Connect 账号权限或协议未完成
