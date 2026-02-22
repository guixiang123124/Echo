# 04 App Store Connect 提交流程

## iOS 提交流程
1. 在 App Store Connect 创建 iOS App 记录
2. 填写名称、主语言、Bundle ID、SKU
3. 在 Xcode Archive iOS Release 包并上传
4. 在 App Store Connect 选择 build
5. 填写 App Information（分类、年龄分级、隐私政策 URL）
6. 填写 App Privacy（数据收集与用途）
7. 填写版本说明、截图、关键词、描述
8. 添加审核备注（使用模板）
9. 提交审核

## macOS 提交流程
1. 在 App Store Connect 创建 macOS App 记录
2. 绑定 `com.xianggui.echo.mac`
3. Archive macOS Release 包并上传
4. 选择 build 并填写元数据
5. 填写权限说明、审核备注（重点讲热键与辅助功能用途）
6. 提交审核

## 提审前 10 项自检
- [ ] 不崩溃（冷启动、连续录音、切换输入框）
- [ ] 权限弹窗与说明一致
- [ ] 隐私政策 URL 可访问
- [ ] App 内无占位文案/测试按钮泄漏
- [ ] 版本号与 build 号正确
- [ ] 截图与真实功能一致
- [ ] 网络失败时有可理解错误提示
- [ ] 历史记录可打开、可播放、可清理
- [ ] API Key 不写死在代码仓库
- [ ] 审核备注写清楚“为什么需要这些权限”

## 审核容易卡住的点（你这个项目重点）
- 热键监听和 Input Monitoring 的必要性说明不充分
- Accessibility 使用场景不清晰（必须写“用于将转写文本插入到当前光标位置”）
- 键盘扩展（iOS）若请求 Full Access，需明确数据流和用途
