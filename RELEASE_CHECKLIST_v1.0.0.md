# 🚀 Echo v1.0.0 上线准备 - 执行清单

> 生成时间: 2026-02-22
> 当前分支: `codex/stream-polish-unification`
> 未提交改动: 39 个文件

---

## ✅ 已完成（Edith 验证）

### 1. 代码层面
- [x] V2 Preset 模型定义
- [x] Stream/Finalize/Polish 三层架构
- [x] Deepgram + Volcano 流式 ASR
- [x] LLM Correction (OpenAI/Claude/豆包/千问)
- [x] iOS + macOS 双端构建通过
- [x] Release preflight 脚本
- [x] 预提交检查清单

### 2. 文档层面
- [x] App Store Kit 文档集
- [x] iOS/macOS 元数据（中英文）
- [x] 审核备注模板
- [x] 隐私政策框架
- [x] 截图拍摄脚本

### 3. 版本信息
```
Marketing Version: 1.0.0
Build Number: 2
iOS Bundle ID: com.xianggui.echo.app
macOS Bundle ID: com.xianggui.echo.mac
Team ID: D7BK236H9B
```

---

## 🔴 阻塞项（必须解决）

### 1. Distribution 证书
**状态**: ❌ 缺失  
**需要**:
- [ ] Apple Distribution 证书
- [ ] Mac Installer Distribution 证书（如上架 Mac App Store）
- [ ] Provisioning Profiles (iOS App Store, macOS App Store)

**操作路径**:
1. 打开 Xcode → Settings → Accounts
2. 选中你的 Apple ID → Manage Certificates
3. 点击 "+" → Apple Distribution
4. 点击 "+" → Mac Installer Distribution（如需要）
5. Download Manual Profiles

### 2. 代码提交与合并
**状态**: ❌ 39 个文件未提交  
**操作**:
```bash
# 当 Codex 完成 UI 后执行
cd /Users/xianggui/.openclaw/workspace/Echo
bash scripts/release-prep-branch.sh
```

### 3. App Store Connect 配置
**状态**: ⚠️ 待确认  
**需要确认**:
- [ ] 税务/银行/协议状态为 "可售"
- [ ] iOS App 记录创建并绑定正确 Bundle ID
- [ ] macOS App 记录创建并绑定正确 Bundle ID
- [ ] 定价/销售范围已配置

---

## 🟡 建议完成（体验优化）

### 4. 真机回归测试
```bash
# iOS 流式回归
echo "测试 Deepgram zh-CN 短句 10 句"
echo "测试 Volcano 短句/中句各 10 次"

# 验证指标
./scripts/streaming-metrics-report.sh --days 1
# 目标: empty_final_rate < 3%, fallback_rate < 3%
```

### 5. 登录验证
- [ ] Google Sign-In (iOS 真机)
- [ ] Google Sign-In (macOS)
- [ ] Apple Sign-In (iOS)
- [ ] Apple Sign-In (macOS)
- [ ] 后端 Railway 服务可用性 (curl 检查)

### 6. 截图生成
```bash
# 需要连接真机或启动模拟器
bash scripts/capture_ios_screenshots.sh
bash scripts/capture_macos_screenshots.sh

# 检查尺寸
ls -la output/appstore_screenshots/ios/
ls -la output/appstore_screenshots/macos/
```

**截图要求**:
- iOS: 1284×2778 (iPhone 14 Pro Max) 或 1170×2532
- macOS: 16:10 比例，推荐 2560×1600

---

## 📋 提审日执行流程

### Phase 1: 预检（提前 30 分钟）
```bash
cd /Users/xianggui/.openclaw/workspace/Echo

# 1. 证书检查
bash scripts/release_preflight.sh
# 期望: Pass=23, Fail=0

# 2. Release 构建验证
xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Release \
  -destination "generic/platform=iOS" build

xcodebuild -project Echo.xcodeproj -scheme EchoMac -configuration Release \
  -destination "generic/platform=macOS" build
```

### Phase 2: Archive（提审前）
```bash
# iOS Archive
xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Release \
  -destination "generic/platform=iOS" \
  archive -archivePath /tmp/Echo-iOS-Release.xcarchive

# macOS Archive
xcodebuild -project Echo.xcodeproj -scheme EchoMac -configuration Release \
  -destination "generic/platform=macOS" \
  archive -archivePath /tmp/Echo-macOS-Release.xcarchive
```

### Phase 3: Xcode Organizer 上传
1. 打开 Xcode → Window → Organizer
2. 选中最新 Archive → Distribute App → App Store Connect → Upload
3. 等待处理完成

### Phase 4: App Store Connect 配置
1. 选择对应版本 → Add Build
2. 填写/检查:
   - [ ] 标题/副标题/描述/关键词
   - [ ] 截图（按设备尺寸）
   - [ ] 隐私问卷
   - [ ] 审核备注（粘贴 REVIEW_NOTES_TEMPLATE.md）
   - [ ] 导出合规（回答问卷）
3. Submit for Review

---

## 🆘 常见问题快速修复

### "No profiles for bundle identifier"
```bash
# 去 developer.apple.com 手动创建 App Store Provisioning Profile
# 下载后双击安装
```

### "Missing Compliance" 警告
在 App Store Connect → 选择 Build → 回答导出合规问卷。

### "Invalid Bundle Structure"
检查 EchoKeyboard 是否已正确签名。

---

## 📞 升级状态追踪

| 时间 | 状态 | 备注 |
|------|------|------|
| 2026-02-22 09:40 | 🟡 启动 | Xiang 回归，全面复盘 |
| 2026-02-22 11:00 | 🟡 准备中 | 创建 release prep 脚本 |

**下次更新**: Distribution 证书配好后

---

*自动生成的执行清单 - Edith*
