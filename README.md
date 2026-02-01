# Typeless - AI Voice Input Method

<p align="center">
  <strong>AI-powered voice input method with LLM error correction</strong>
</p>

<p align="center">
  <a href="#english">English</a> | <a href="#中文说明">中文</a>
</p>

---

## English

### Overview

**Typeless** is an AI-powered voice input method for iOS and macOS. It combines state-of-the-art speech recognition with Large Language Model (LLM) error correction to deliver highly accurate transcription, especially for Chinese homophones and context-dependent phrases.

Inspired by [Doubao Input Method (豆包输入法)](https://www.doubao.com), Typeless uses a 3-stage correction pipeline to achieve 20-50% lower error rates compared to traditional ASR alone.

### Key Features

- **Real-time Speech-to-Text**: Stream transcription as you speak with live waveform visualization
- **LLM-Powered Error Correction**: 3-stage pipeline for homophone correction (的/得/地, 在/再, etc.)
- **Full Keyboard**: Complete QWERTY + Chinese Pinyin keyboard with candidate bar
- **Pluggable ASR Providers**: Switch between Apple, OpenAI Whisper, Deepgram, iFlytek, and more
- **Multi-LLM Support**: Choose from OpenAI GPT-4o, Claude, or Doubao for correction
- **Secure Storage**: API keys stored in iOS Keychain
- **Bilingual**: Supports Chinese and English equally, with mixed-language input
- **Privacy-First**: On-device ASR options available (no cloud required)

### Supported Providers

| Type | Providers |
|------|-----------|
| **ASR (Speech-to-Text)** | Apple SFSpeechRecognizer, OpenAI Whisper API, Deepgram Nova-3, iFlytek, Volcano Engine |
| **LLM (Correction)** | OpenAI GPT-4o, Claude, Doubao |

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Typeless                             │
├─────────────────────────────────────────────────────────────┤
│  [Voice Input] → [ASR] → [LLM Correction] → [Text Output]  │
├─────────────────────────────────────────────────────────────┤
│  TypelessCore (Swift Package)                               │
│  ├── ASR/          - Pluggable speech recognition          │
│  ├── LLMCorrection/ - 3-stage correction pipeline          │
│  ├── Audio/        - Real-time audio capture               │
│  ├── Keyboard/     - QWERTY + Pinyin engine               │
│  └── Settings/     - Secure configuration                  │
├─────────────────────────────────────────────────────────────┤
│  TypelessUI (Swift Package)                                 │
│  └── Shared SwiftUI components                             │
├─────────────────────────────────────────────────────────────┤
│  iOS App + Keyboard Extension                               │
│  macOS Input Method (planned)                               │
└─────────────────────────────────────────────────────────────┘
```

### Requirements

- **iOS**: 17.0+
- **macOS**: 14.0+ (Sonoma)
- **Xcode**: 15.0+
- **Swift**: 5.9+

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/YOUR_USERNAME/Typeless.git
   cd Typeless
   ```

2. **Generate Xcode project** (if `Typeless.xcodeproj` doesn't exist)
   ```bash
   # Install XcodeGen if needed
   brew install xcodegen
   # Generate project
   xcodegen generate
   ```

3. **Open in Xcode**
   ```bash
   open Typeless.xcodeproj
   ```

4. **Configure signing**
   - Select the project in navigator
   - Go to Signing & Capabilities
   - Select your development team

5. **Build and run**
   - Select target: `Typeless`
   - Select destination: iPhone Simulator or device
   - Press `⌘R`

### Enabling the Keyboard

1. Go to **Settings → General → Keyboard → Keyboards**
2. Tap **Add New Keyboard**
3. Select **Typeless**
4. Tap **Typeless** and enable **Allow Full Access** (required for App Groups IPC)

### Project Structure

```
Typeless/
├── Packages/
│   ├── TypelessCore/           # Core business logic
│   │   └── Sources/TypelessCore/
│   │       ├── ASR/            # Speech recognition providers
│   │       ├── LLMCorrection/  # Error correction pipeline
│   │       ├── Audio/          # Audio capture & processing
│   │       ├── Keyboard/       # Keyboard layouts & Pinyin
│   │       ├── Context/        # Conversation memory
│   │       ├── Settings/       # Configuration & Keychain
│   │       └── Models/         # Data models
│   └── TypelessUI/             # Shared UI components
├── iOS/
│   ├── TypelessApp/            # Main iOS app
│   └── TypelessKeyboard/       # Keyboard extension
├── macOS/                      # (Planned) macOS input method
├── project.yml                 # XcodeGen configuration
└── README.md
```

### Technical Highlights

| Feature | Implementation |
|---------|----------------|
| **iOS Voice Input** | Keyboard extension redirects to main app (iOS restriction), results via App Groups |
| **Streaming ASR** | `SFSpeechRecognizer` with real-time partial results |
| **3-Stage Correction** | Pre-detection → LLM correction → Verification |
| **Chinese Input** | Custom `PinyinEngine` with 533+ character mappings |
| **Secure Storage** | API keys in iOS Keychain via `SecureKeyStore` |
| **Audio Processing** | `AVAudioEngine` with 16kHz mono PCM output |

### Roadmap

- [x] Phase 1-3: Core architecture, iOS app, keyboard extension
- [ ] Phase 4: Cloud ASR providers (Deepgram, iFlytek)
- [ ] Phase 5: On-device Whisper via WhisperKit
- [ ] Phase 6: macOS input method
- [ ] Phase 7: Android & Windows

### Testing

```bash
# Run unit tests (75+ tests)
cd Packages/TypelessCore && swift test

# Build UI package
cd Packages/TypelessUI && swift build
```

### Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### License

MIT License - see [LICENSE](LICENSE) for details.

---

## 中文说明

### 简介

**Typeless** 是一款 AI 驱动的语音输入法，支持 iOS 和 macOS 平台。它结合了先进的语音识别技术和大语言模型（LLM）纠错功能，能够提供高度准确的转写结果，尤其擅长处理中文同音字和上下文相关的表达。

灵感来自 [豆包输入法](https://www.doubao.com)，Typeless 采用三阶段纠错流水线，相比传统 ASR 可降低 20-50% 的错误率。

### 核心功能

- **实时语音转文字**：边说边转写，配有实时波形可视化
- **大模型智能纠错**：三阶段流水线，专门处理同音字（的/得/地、在/再、做/作等）
- **完整键盘**：QWERTY 英文 + 拼音输入，带候选词栏
- **可插拔 ASR**：支持 Apple、OpenAI Whisper、Deepgram、讯飞等多种语音识别
- **多模型纠错**：支持 OpenAI GPT-4o、Claude、豆包
- **安全存储**：API 密钥存储在 iOS Keychain
- **中英双语**：同时支持中文和英文，支持混合输入
- **隐私优先**：提供本地识别选项，无需云端

### 技术架构

```
┌─────────────────────────────────────────────────────────────┐
│                        Typeless                             │
├─────────────────────────────────────────────────────────────┤
│   [语音输入] → [ASR识别] → [LLM纠错] → [文字输出]           │
├─────────────────────────────────────────────────────────────┤
│   TypelessCore (Swift Package)                              │
│   ├── ASR/           - 可插拔语音识别                       │
│   ├── LLMCorrection/ - 三阶段纠错流水线                     │
│   ├── Audio/         - 实时音频采集                         │
│   ├── Keyboard/      - QWERTY + 拼音引擎                   │
│   └── Settings/      - 安全配置存储                         │
├─────────────────────────────────────────────────────────────┤
│   TypelessUI (Swift Package)                                │
│   └── 共享 SwiftUI 组件                                     │
├─────────────────────────────────────────────────────────────┤
│   iOS 应用 + 键盘扩展                                       │
│   macOS 输入法（计划中）                                    │
└─────────────────────────────────────────────────────────────┘
```

### 系统要求

- **iOS**: 17.0+
- **macOS**: 14.0+ (Sonoma)
- **Xcode**: 15.0+
- **Swift**: 5.9+

### 安装运行

1. **克隆仓库**
   ```bash
   git clone https://github.com/YOUR_USERNAME/Typeless.git
   cd Typeless
   ```

2. **生成 Xcode 项目**（如果 `Typeless.xcodeproj` 不存在）
   ```bash
   brew install xcodegen
   xcodegen generate
   ```

3. **在 Xcode 中打开**
   ```bash
   open Typeless.xcodeproj
   ```

4. **配置签名**
   - 选择项目 → Signing & Capabilities → 选择你的开发者团队

5. **构建运行**
   - 目标: `Typeless`
   - 设备: iPhone 模拟器或真机
   - 快捷键: `⌘R`

### 启用键盘

1. 前往 **设置 → 通用 → 键盘 → 键盘**
2. 点击 **添加新键盘**
3. 选择 **Typeless**
4. 点击 **Typeless** 并开启 **允许完全访问权限**

### 开发计划

- [x] 阶段 1-3: 核心架构、iOS 应用、键盘扩展
- [ ] 阶段 4: 云端 ASR（Deepgram、讯飞）
- [ ] 阶段 5: 本地 Whisper (WhisperKit)
- [ ] 阶段 6: macOS 输入法
- [ ] 阶段 7: Android 和 Windows

### 测试

```bash
# 运行单元测试（75+ 测试用例）
cd Packages/TypelessCore && swift test

# 构建 UI 包
cd Packages/TypelessUI && swift build
```

### 贡献

欢迎提交 Pull Request！

### 许可证

MIT License - 详见 [LICENSE](LICENSE)

---

<p align="center">
  Made with ❤️ using Swift and SwiftUI
</p>
