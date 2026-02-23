# Echo 网站功能介绍 — 详细版

## Hero
- EN: Speak at the speed of thought.
- ZH: 以思维速度开口，以可编辑文本落地。

## Subheadline
- EN: Echo turns your voice into clean, editable text in real time.
- ZH: Echo 将语音实时转成干净、可编辑的文字。

## Product Principle
- EN: Echo = the fastest path from thought to editable text.
- ZH: Echo = 从想法到可编辑文字的最快路径。

## Core Value
- EN: Fast first token. Stable live output. Accurate final text.
- ZH: 首字快、过程稳、结果准。

---

## 功能详解

### 🎙️ 语音识别引擎 — 选择你的"听力"

Echo 支持多个语音识别引擎，你可以根据场景选择：

| 引擎 | 特点 | 推荐场景 |
|------|------|---------|
| **Deepgram** | 业界领先的低延迟流式识别 | 实时对话、会议记录 |
| **Volcano** | 国产优化，响应迅速 | 中文场景优先 |
| **OpenAI Whisper** | 准确率最高，支持离线 | 追求准确性，不需要实时 |

> 💡 **小提示**: 默认使用 Volcano，因为它在中文场景下表现优异且响应快速。

---

### ⚡ 转写模式 — Batch vs Stream

这是 Echo 的核心创新：你可以选择"实时流式"或"批量处理"模式：

#### 🚀 Stream (流式模式)
- **速度最快**: 边说边出字，首字延迟极低
- **实时可见**: 文字像字幕一样逐字出现
- **适合**: 实时对话、会议记录、即时沟通
- **效果**: "我刚才说的那句话有没有被准确转写？" — 一目了然

#### 📦 Batch (批量模式)
- **质量更统一**: 整段说完后再处理
- **更适合 Polish**: LLM 润色更稳定
- **适合**: 演讲稿、正式内容、深度编辑
- **效果**: "这段话需要完整润色后再给你看"

> 🎯 **选择建议**: 如果你追求**速度**，选 Stream；如果追求**统一质量**，选 Batch。

---

### 🎛️ 智能润色 — 5 档预设模式

Echo 内置 5 档智能润色模式，满足不同场景需求：

| 模式 | 名称 | 适用场景 | 效果 |
|------|------|---------|------|
| 1 | **Pure Transcript** | 只想看原始转写 | 仅转写，不润色 |
| 2 | **StreamFast** | 实时沟通，低延迟优先 | 只修关键错误，保持速度 |
| 3 | **Smart Polish** 🌟默认 | 日常对话、工作沟通 | 平衡质量和速度，自动清理口语 |
| 4 | **Deep Edit** | 正式内容、演讲稿 | 深度重写，结构优化 |
| 5 | **Custom** | 高级用户 | 手动组合所有选项 |

#### 各模式详细说明：

**Pure Transcript** 
- 纯转写，不做任何修改
- 保留所有口语词、重复、填充词
- 适合：需要原始记录、法律取证

**StreamFast** 
- 只做必须修正：明显错字、标点
- 保持最低延迟
- 适合：实时对话、快速记录

**Smart Polish** ⭐ 推荐
- 自动清理填充词（"嗯"、"啊"）
- 修正重复词语
- 基础标点和格式
- 轻度重写，更通顺
- 适合：日常沟通、工作文档

**Deep Edit** 
- 深度重写，句式优化
- 结构调整，逻辑增强
- 适合：演讲稿、文章、正式内容

**Custom** 
- 完全自定义：哪些修正在开，哪些关闭
- 填充词去除 开/关
- 重复词语去除 开/关
- 重写强度：关闭/轻度/中度/强力
- 适合：高级用户，按需配置

---

### 🌍 翻译功能 — 实时多语言

Echo 支持实时翻译，说中文直接出英文，说英文直接出中文：

- **目标语言**: English、中文（简体）
- **翻译时机**: 可以在转写后立即翻译
- **应用场景**: 国际会议、与外国同事沟通、学习外语

---

### 📝 结构化输出 — 不仅是纯文本

除了普通文本，Echo 还能输出结构化格式：

| 格式 | 说明 |
|------|------|
| Plain Text | 普通纯文本 |
| JSON | 结构化数据 |
| Markdown | 带格式的 Markdown |

---

### ⌨️ 多平台支持

- **macOS**: 菜单栏应用，全局快捷键
- **iOS**: 自定义键盘，随时随地使用
- **Windows**: 开发中 🚧
- **Android**: 开发中 🚧

---

## 安装指南

### macOS 安装
1. 从 App Store 下载 Echo
2. 打开应用，设置全局快捷键
3. 按住快捷键说话，松手停止

### iOS 安装
1. 从 App Store 下载 Echo Keyboard
2. 打开系统设置 → 通用 → 键盘 → 键盘
3. 添加 Echo Keyboard
4. **重要**: 开启 "Allow Full Access" 以启用语音功能
5. 切换到 Echo 键盘，按住麦克风说话

---

## CTA Buttons
- EN: Download for macOS / Download for iOS / Join Windows & Android waitlist
- ZH: 下载 macOS / 下载 iOS / 加入 Windows 与 Android 候补
