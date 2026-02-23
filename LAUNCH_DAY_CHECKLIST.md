# 🚀 Echo v1.0.0 上线执行清单

> 生成时间: 2026-02-22 13:50 PST  
> 执行日期: 2026-02-23 (明天)  
> 代码状态: ✅ 已合并到 main，tag v1.0.0 已推送

---

## ✅ 已完成 (Edith)

- [x] Codex 功能完成并推送 (f304fd7)
- [x] 网站多页面 + 中英双语部署
- [x] 代码合并到 main 分支
- [x] 打 tag v1.0.0
- [x] 所有文档准备就绪

---

## 🔴 明天必须完成 (需要你操作)

### Step 1: Distribution 证书 (5分钟)
```bash
# 在 Xcode 中:
1. 打开 Xcode → Window → Organizer
2. 选中 Archive → Distribute App → App Store Connect
3. 这时会提示下载证书，点击确认
4. 验证证书:
   security find-identity -v -p codesigning
   # 应该看到 "Apple Distribution" 和 "Mac Installer Distribution"
```

### Step 2: Archive & Upload (10分钟)
```bash
cd /Users/xianggui/.openclaw/workspace/Echo

# iOS Archive
xcodebuild -project Echo.xcodeproj -scheme Echo \
  -configuration Release -destination "generic/platform=iOS" \
  archive -archivePath /tmp/Echo-iOS-Release.xcarchive

# macOS Archive  
xcodebuild -project Echo.xcodeproj -scheme EchoMac \
  -configuration Release -destination "generic/platform=macOS" \
  archive -archivePath /tmp/Echo-macOS-Release.xcarchive

# 然后在 Xcode Organizer 中上传两个 Archive
```

### Step 3: App Store Connect 配置 (15分钟)

#### iOS App
- [ ] 选择 build (等待处理完成，约 10-15 分钟)
- [ ] 填写元数据:
  - 标题: Echo Voice Input
  - 副标题: Speak, Transcribe, Insert
  - 描述: (从 `docs/app-store-kit/IOS_METADATA.en-US.md` 复制)
  - 关键词: voice input, speech to text, dictation, keyboard, transcription
- [ ] 上传截图 (6张，从 `output/appstore_screenshots/ios/`)
- [ ] 回答导出合规问卷
- [ ] 粘贴审核备注 (从 `docs/app-store-kit/REVIEW_NOTES_TEMPLATE.md`)

#### macOS App
- [ ] 同样流程，使用 `MACOS_METADATA.en-US.md`
- [ ] 上传 macOS 截图

### Step 4: 最终检查清单
- [ ] 隐私政策 URL: https://docs-9l91ofmwf-guixiang123124s-projects.vercel.app/privacy.html
- [ ] 支持 URL: https://docs-9l91ofmwf-guixiang123124s-projects.vercel.app/support.html
- [ ] 营销网址: https://docs-9l91ofmwf-guixiang123124s-projects.vercel.app
- [ ] 年龄分级: 4+
- [ ] 价格: 免费 (或你决定的定价)

### Step 5: 提交审核
- [ ] 点击 "Submit for Review"
- [ ] 等待审核 (通常 1-3 天)

---

## 🟡 建议执行 (可选但推荐)

### TestFlight 灰度 (推荐)
在提交正式审核前:
1. 选择 build → TestFlight
2. 添加内部测试员 (你自己的 Apple ID)
3. 下载 TestFlight app，安装测试
4. 验证: 流式转写、AutoEdit、登录功能

### 真机回归测试 (30分钟)
- [ ] Volcano 长句中文 stream 测试
- [ ] Deepgram 英文 stream 测试
- [ ] AutoEdit DeepEdit 结构化输出测试
- [ ] iOS 真机录音测试

---

## 📋 文件速查

| 文件 | 路径 |
|------|------|
| iOS 元数据 | `docs/app-store-kit/IOS_METADATA.en-US.md` |
| macOS 元数据 | `docs/app-store-kit/MACOS_METADATA.en-US.md` |
| 审核备注 | `docs/app-store-kit/REVIEW_NOTES_TEMPLATE.md` |
| 隐私政策 | `docs/privacy.html` (已部署) |
| 截图 | `output/appstore_screenshots/ios/` |
| 预检脚本 | `scripts/release_preflight.sh` |

---

## 🆘 如果卡住了

**证书问题**:  
- 去 developer.apple.com → Certificates → 手动创建 Apple Distribution

**上传失败**:  
- 检查网络，或尝试 Xcode Organizer 图形界面上传

**截图尺寸错误**:  
- iOS 需要 1284×2778 或 1170×2532
- macOS 需要 16:10 比例 (2560×1600)

---

## 📞 完成后通知我

当你完成 Step 5 (提交审核) 后，告诉我：
1. 是否成功提交？
2. 有没有遇到错误？
3. 审核状态是什么？

然后我们等待审核通过，准备庆祝 Echo 上线！🎉

---

**状态**: 一切就绪，等待你的 Xcode 操作
**预计总时间**: 30-45 分钟
**风险**: 低 (所有代码已验证，文档已准备)
