#!/bin/bash
# release-prep-branch.sh - 创建上线准备分支

set -e

echo "🎯 Echo Release Prep - Branch Setup"
echo "===================================="

# 1. 检查当前状态
echo "📋 Step 1: Checking current status..."
git status --short | head -10

# 2. 创建发布分支
echo ""
echo "📦 Step 2: Creating release branch..."
git checkout -b release/v1.0.0-$(date +%Y%m%d)

# 3. 提交当前所有改动
echo ""
echo "💾 Step 3: Staging changes..."
git add -A
git commit -m "wip: consolidate all v1.0.0 changes for release

- V2 preset model implementation
- LLMCorrection pipeline upgrades
- Stream layer unification (Deepgram + Volcano)
- Settings persistence updates
- UI improvements (iOS + macOS)
- Release preflight automation

Co-authored-by: Coding App <codex@anthropic.com>"

# 4. 合并到 main
echo ""
echo "🔀 Step 4: Merging to main..."
git checkout main
git merge --no-ff release/v1.0.0-$(date +%Y%m%d) -m "release: v1.0.0 - Echo Initial Release

Features:
- Real-time streaming ASR (Volcano default, Deepgram alternative)
- V2 Preset model: Pure Transcript / StreamFast / Smart Polish / Deep Edit / Custom
- LLM post-processing with 4 providers (OpenAI/Claude/Doubao/Qwen)
- iOS + macOS universal support
- Dictionary auto-learn with review queue

ASR Providers:
- Volcano Streaming (default for Chinese)
- Deepgram Streaming (with language hint fix)
- OpenAI Whisper (batch fallback)

Technical:
- Unified stream/finalize/polish three-layer architecture
- Trace ID funnel observability
- Streaming metrics persistence
- Release preflight automation"

# 5. 打 tag
echo ""
echo "🏷️  Step 5: Tagging v1.0.0..."
git tag -a v1.0.0 -m "Echo v1.0.0 - Initial App Store Release"

echo ""
echo "✅ Release branch setup complete!"
echo ""
echo "Next steps:"
echo "  1. Push to origin: git push origin main --tags"
echo "  2. Archive iOS: xcodebuild -scheme Echo -configuration Release archive"
echo "  3. Archive macOS: xcodebuild -scheme EchoMac -configuration Release archive"
