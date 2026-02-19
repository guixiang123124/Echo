# ASR / Speech-to-Text Model Research — February 2026

> **Goal**: Find fast, accurate STT solutions that can beat or match OpenAI `gpt-4o-transcribe` (~2-5s for 15-25s audio), with strong Chinese + English + code-switching support.

---

## Executive Summary

The ASR landscape in 2025-2026 has become remarkably competitive. Key findings:

1. **Groq Whisper** is the fastest cloud API for Whisper models (~189-216x real-time), making it the cheapest and fastest way to run Whisper at scale.
2. **Deepgram Nova-3** offers one of the best speed/accuracy/cost trade-offs for production streaming at $0.0077-0.0092/min.
3. **Gladia** is a strong real-time API contender with partial transcripts advertised at **<100ms**, and simpler all-included feature packaging.
4. **SenseVoice / Fun-ASR** from Alibaba is the **best open-source option for Chinese** with state-of-the-art CER and built-in code-switching support.
5. **Moonshine** is the most promising **on-device** option for Apple Silicon, with models from 26MB to 245M params running at 50-258ms latency.
6. **Fun-ASR-Nano** (Dec 2025) is a game-changer — 800M params trained on tens of millions of hours, supporting 31 languages with Chinese dialect coverage.
7. For **mixed Chinese-English**, SenseVoice and Fun-ASR-Nano are the clear leaders; most Western-focused APIs (Deepgram, AssemblyAI, Gladia) have weaker published Chinese benchmarking.

---

## Comparison Table

| Model / API | Provider | Type | Latency | English WER | Chinese CER | Streaming | Pricing | On-Device |
|---|---|---|---|---|---|---|---|---|
| **gpt-4o-transcribe** | OpenAI | Cloud API | ~2-5s for 15-25s | ~5-8% | ~5-8% (good) | ❌ | ~$0.006/min ($0.36/hr) | ❌ |
| **gpt-4o-mini-transcribe** | OpenAI | Cloud API | ~1-3s | ~8-10% | ~8-10% | ❌ | ~$0.003/min ($0.18/hr) | ❌ |
| **Whisper Large V3** | OpenAI (whisper-1) | Cloud API | ~3-8s | 10.3% (HF bench) | ~8-12% | ❌ | $0.006/min ($0.36/hr) | ❌ |
| **Groq Whisper V3** | Groq | Cloud API | **~0.1-0.5s** (189x RT) | 10.3% | ~8-12% | ❌ | **$0.111/hr** ($0.00185/min) | ❌ |
| **Groq Whisper V3 Turbo** | Groq | Cloud API | **~0.08-0.4s** (216x RT) | ~12% | ~10-14% | ❌ | **$0.04/hr** ($0.00067/min) | ❌ |
| **Deepgram Nova-3 Mono** | Deepgram | Cloud API | **<300ms** (streaming) | ~5-8% (SOTA claim) | ⚠️ Limited | ✅ WebSocket | $0.0077/min ($0.46/hr) | ❌ |
| **Deepgram Nova-3 Multi** | Deepgram | Cloud API | **<300ms** (streaming) | ~5-8% | ⚠️ Limited | ✅ WebSocket | $0.0092/min ($0.55/hr) | ❌ |
| **Deepgram Flux** | Deepgram | Cloud API | **Ultra-low** (agent-optimized) | ~6-9% | ⚠️ Limited | ✅ WebSocket | $0.0077/min ($0.46/hr) | ❌ |
| **AssemblyAI Universal-2** | AssemblyAI | Cloud API | ~1-3s (batch) | **~5-6%** (SOTA claim) | ⚠️ Limited | ✅ | $0.15/hr ($0.0025/min) | ❌ |
| **AssemblyAI Universal-3 Pro** | AssemblyAI | Cloud API | ~1-3s (batch) | **~4-5%** (best claim) | ⚠️ 6 languages | ✅ | $0.21/hr ($0.0035/min) | ❌ |
| **AssemblyAI Universal-Streaming** | AssemblyAI | Cloud API | **<200ms** (streaming) | ~5-7% | ⚠️ 6 languages | ✅ | $0.15/hr ($0.0025/min) | ❌ |
| **Gladia Real-time STT** | Gladia | Cloud API | **<100ms partials** | ~competitive (vendor claim) | ⚠️ Not publicly benchmarked | ✅ | $0.75/hr self-serve (from $0.55/hr scaling) | ❌ |
| **Google Cloud STT V2** | Google Cloud | Cloud API | ~1-3s | ~6-10% | ✅ Good (Chirp 3) | ✅ | $0.016/min ($0.96/hr) | ❌ |
| **Google Chirp 3** | Google Cloud | Cloud API | ~1-3s | ~5-8% | ✅ Good | ✅ | $0.016/min ($0.96/hr) | ❌ |
| **Azure Speech STT** | Microsoft | Cloud API | ~1-2s | ~5-8% | ✅ Good (100+ langs) | ✅ | ~$1.00/hr (std transcription) | ❌ (containers available) |
| **SenseVoice-Small** | Alibaba/FunAudioLLM | Open Source | **~0.1-0.3s** (non-autoregressive) | ~8-12% | **~3-5% (SOTA)** | ⚠️ Via FunASR | Free (self-hosted) | ✅ (with effort) |
| **Fun-ASR-Nano** | Alibaba/Tongyi | Open Source | Low latency (streaming) | Good | **~3-5% (SOTA)** | ✅ | Free (self-hosted) | ⚠️ (800M, needs GPU) |
| **Paraformer-Large** | Alibaba/FunASR | Open Source | Fast (non-autoregressive) | ~10-15% | **~4-6% (excellent)** | ✅ Via FunASR | Free (self-hosted) | ⚠️ (needs GPU) |
| **faster-whisper** | SYSTRAN (open source) | Local | **4x faster** than OpenAI whisper | Same as Whisper | Same as Whisper | ❌ | Free (self-hosted) | ✅ (CPU int8) |
| **whisper.cpp** | ggml-org (open source) | Local | ~1-3x RT (Metal on M-series) | Same as Whisper | Same as Whisper | ⚠️ (community) | Free (self-hosted) | **✅ Excellent** (Metal, CoreML) |
| **Moonshine Medium** | Moonshine AI | Local/Open Source | **258ms** (MacBook Pro) | **6.65%** | ⚠️ Mandarin supported | ✅ (native streaming) | Free (open source) | **✅ Best** |
| **Moonshine Small** | Moonshine AI | Local/Open Source | **148ms** (MacBook Pro) | 7.84% | ⚠️ Mandarin supported | ✅ (native streaming) | Free (open source) | **✅ Best** |
| **Moonshine Tiny** | Moonshine AI | Local/Open Source | **50ms** (MacBook Pro) | 12.00% | ⚠️ Limited | ✅ (native streaming) | Free (open source) | **✅ Best** (26MB) |

> **Note**: WER/CER figures are approximate, sourced from provider claims and community benchmarks. Real-world performance varies significantly by audio quality, domain, accent, and noise conditions.

---

## Detailed Analysis

### 1. Cloud APIs — Speed Champions

#### Groq Whisper (Fastest Cloud Whisper)
- **Speed**: 189-216x real-time. Transcribes 25s audio in ~0.1-0.5s
- **Models**: Whisper Large V3 ($0.111/hr) and V3 Turbo ($0.04/hr)
- **Accuracy**: Same as OpenAI Whisper (10.3% WER for V3, 12% for Turbo)
- **Chinese**: Supported (Whisper's multilingual capability), but not optimized
- **Streaming**: No — batch only (OpenAI-compatible API)
- **Limit**: 25MB free tier, 100MB dev tier
- **Best for**: When you need Whisper-level accuracy at maximum speed and minimum cost
- **⚡ Verdict**: Best price-performance for batch transcription. 50-100x faster than OpenAI's own Whisper API

#### Deepgram Nova-3 (Best Streaming)
- **Speed**: Sub-300ms streaming latency, real-time WebSocket
- **Models**: Nova-3 Monolingual ($0.0077/min), Multilingual ($0.0092/min), Flux (agent-optimized, $0.0077/min)
- **Accuracy**: Claims industry-leading accuracy; independent benchmarks show competitive with best models
- **Chinese**: Listed in 30+ languages but Chinese accuracy is not their strength — primarily English-optimized
- **Streaming**: ✅ First-class WebSocket streaming with diarization
- **Features**: Speaker diarization ($0.002/min extra), smart formatting, keyword boosting, multichannel, deep search
- **Best for**: Real-time voice agents, live transcription, English-heavy workloads

#### AssemblyAI Universal-2/3
- **Speed**: Batch: ~1-3s; Streaming: <200ms
- **Models**: Universal-2 ($0.15/hr, 99 languages), Universal-3 Pro ($0.21/hr, 6 languages with prompting)
- **Accuracy**: Claims best-in-class, 600M param Conformer RNN-T architecture. Universal-2 outperforms Whisper Large V3 by 15% relative on their benchmarks
- **Chinese**: Universal-2 lists 99 languages but Chinese is not a primary focus
- **Streaming**: ✅ Universal-Streaming with built-in turn detection
- **Features**: Entity detection, sentiment, summarization, topic detection, auto chapters, PII redaction
- **Best for**: English-first applications needing rich post-processing features

#### Gladia Real-time STT
- **Speed**: Real-time partial transcripts in **<100ms** (vendor claim), with low-latency full transcripts
- **Pricing**: Self-serve starts at **$0.75/hr real-time** and **$0.61/hr async** (10 hours/month free); scaling tier from $0.55/hr real-time
- **Accuracy**: Markets itself as state-of-the-art, but public independent WER/CER benchmarks are limited
- **Chinese**: 100+ language support and language switching advertised; Chinese quality not as openly benchmarked as SenseVoice/Whisper
- **Streaming**: ✅ Yes (core product focus)
- **Features**: Diarization, language detection/switching, API integrations for LiveKit/Pipecat/Vapi/Twilio
- **Best for**: Voice-agent stacks needing low latency + turnkey API experience

#### Google Cloud Speech-to-Text V2 / Chirp 3
- **Speed**: Standard streaming latency (~1-3s for batch)
- **Pricing**: $0.016/min ($0.96/hr) standard; $0.003/min dynamic batch
- **Accuracy**: Good across many languages. Chirp 3 is their latest model
- **Chinese**: ✅ Well-supported (Mandarin, Cantonese)
- **Streaming**: ✅ Native streaming support
- **Features**: Auto-punctuation, speaker diarization, medical models, custom speech models
- **Best for**: Google Cloud ecosystem, medical transcription, enterprise deployments

#### Azure Speech (Microsoft)
- **Speed**: Low-latency real-time transcription, fast transcription for batch
- **Pricing**: ~$1.00/hr for standard real-time transcription (5 free hours/month)
- **Chinese**: ✅ Excellent Chinese support (one of the best for Mandarin)
- **Streaming**: ✅ Real-time and batch transcription
- **Features**: Custom speech models, voice containers for on-prem, speech translation, pronunciation assessment, Voice Live (conversational AI)
- **Best for**: Enterprise, on-prem via containers, voice agents, Microsoft ecosystem

### 2. Open Source — Self-Hosted Champions

#### SenseVoice (Alibaba/FunAudioLLM) ⭐ Best for Chinese
- **Architecture**: Non-autoregressive (very fast inference), supports ASR + language ID + sentiment + audio event detection
- **Speed**: 5-10x faster than Whisper due to non-autoregressive design
- **Chinese CER**: State-of-the-art, ~3-5% on standard benchmarks
- **Code-switching**: Excellent Chinese-English mixing support
- **Models**: SenseVoice-Small (available on ModelScope/HuggingFace)
- **Deployment**: Via FunASR runtime with ONNX optimization
- **On-device**: Possible but needs optimization for M-series

#### Fun-ASR-Nano (Dec 2025) ⭐ Best New Model
- **Architecture**: End-to-end large model, 800M parameters
- **Training**: Tens of millions of hours of real speech data
- **Languages**: 31 languages, with 7 Chinese dialects + 26 regional accents
- **Features**: 
  - Far-field high-noise recognition (93% accuracy)
  - Chinese dialect support (Wu, Cantonese, Min, Hakka, Gan, Xiang, Jin)
  - Music background lyric recognition
  - Low-latency real-time transcription
- **Best for**: Chinese-heavy applications needing dialect support

#### Paraformer-Large (FunASR)
- **Architecture**: Non-autoregressive end-to-end model
- **Chinese CER**: Excellent (~4-6%), one of the best for Mandarin
- **Speed**: Very fast inference due to non-autoregressive design
- **Deployment**: Full server deployment via FunASR runtime (CPU and GPU)
- **Features**: VAD, punctuation restoration, speaker diarization via FunASR pipeline

#### faster-whisper (SYSTRAN)
- **Architecture**: CTranslate2 reimplementation of Whisper
- **Speed**: 4x faster than OpenAI Whisper, same accuracy; batch mode processes 13min audio in 16-17s on GPU
- **Quantization**: int8 support reduces memory usage by ~40%
- **CPU**: int8 on CPU is viable (~1m42s for 13min audio on i7-12700K)
- **Best for**: Self-hosted Whisper with GPU, batch transcription workloads

#### whisper.cpp (ggml-org)
- **Architecture**: Pure C/C++ port of Whisper, optimized for Apple Silicon
- **Speed**: Metal GPU acceleration on Mac; ~1m05s for 13min audio (Large V2, Flash Attention)
- **Apple Silicon**: First-class support via ARM NEON, Accelerate, Metal, Core ML
- **Memory**: From 273MB (tiny) to 3.9GB (large)
- **Quantization**: Supports various quantization levels (Q4, Q5, Q8)
- **Best for**: On-device Mac/iOS deployment, edge computing

#### Moonshine ⭐ Best On-Device
- **Architecture**: Custom models trained from scratch (not Whisper derivatives), designed for streaming
- **Models**: 
  - Tiny (34M params, 50ms on MacBook, 12% WER)
  - Small (123M params, 148ms on MacBook, 7.84% WER)
  - Medium (245M params, 258ms on MacBook, **6.65% WER** — better than Whisper Large V3's 7.44%)
- **vs Whisper**: 
  - Moonshine Medium: 6.65% WER vs Whisper Large V3: 7.44% WER
  - Moonshine Medium: 258ms vs Whisper Large V3: 11,286ms on MacBook Pro
  - **44x faster at higher accuracy**
- **Streaming**: Native streaming support, works while user is still talking
- **Languages**: English, Spanish, Mandarin, Japanese, Korean, Vietnamese, Ukrainian, Arabic
- **Platforms**: Python, iOS, Android, macOS, Linux, Windows, Raspberry Pi, IoT
- **Mandarin**: Listed as supported but accuracy benchmarks are primarily English-focused
- **Best for**: On-device real-time voice interfaces, especially on Apple Silicon

---

## 3. Pricing Comparison (Normalized to $/hour)

| Provider | Model | $/hour | $/minute | Notes |
|---|---|---|---|---|
| **Groq** | Whisper V3 Turbo | **$0.04** | $0.00067 | Cheapest cloud option |
| **Groq** | Whisper V3 | **$0.111** | $0.00185 | Best accuracy at low cost |
| **AssemblyAI** | Universal-2 | $0.15 | $0.0025 | 99 languages |
| **AssemblyAI** | Universal-Streaming | $0.15 | $0.0025 | Real-time |
| **AssemblyAI** | Universal-3 Pro | $0.21 | $0.0035 | + $0.05/hr prompting |
| **OpenAI** | whisper-1 | $0.36 | $0.006 | Legacy |
| **OpenAI** | gpt-4o-transcribe | ~$0.36 | ~$0.006 | Best OpenAI quality |
| **Deepgram** | Nova-3 Mono | $0.46 | $0.0077 | Streaming |
| **Deepgram** | Nova-3 Multi | $0.55 | $0.0092 | Multilingual streaming |
| **Gladia** | Real-time STT (Self-serve) | $0.75 | $0.0125 | <100ms partials; 10h free/mo |
| **Google Cloud** | STT V2 Standard | $0.96 | $0.016 | Batch: $0.003/min |
| **Azure** | Speech STT | ~$1.00 | ~$0.017 | 5 hrs/mo free |
| **Self-hosted** | Any open source | $0 | $0 | + compute costs |

---

## 4. Recommendations for Echo Project

### Primary Use Case: Transcribe voice messages (15-30s) in Chinese/English

#### Option A: Fast Cloud API (Recommended for v1)
**Groq Whisper V3** → $0.111/hr, ~0.1-0.5s latency
- Pros: Extremely fast, cheap, good Chinese support (via Whisper), OpenAI-compatible API
- Cons: No streaming, accuracy ceiling is Whisper V3 level

#### Option B: Best Chinese Accuracy (Recommended if Chinese quality matters most)
**SenseVoice or Fun-ASR-Nano** (self-hosted) → Free, ~0.1-0.3s
- Pros: State-of-the-art Chinese CER, dialect support, code-switching
- Cons: Requires GPU server, more setup complexity

#### Option C: On-Device (Recommended for offline/privacy)
**Moonshine Small/Medium** → Free, 148-258ms on MacBook
- Pros: Runs locally on Apple Silicon, native streaming, competitive accuracy
- Cons: Mandarin accuracy less proven than SenseVoice, English-first

#### Option D: Streaming Real-Time
**Deepgram Nova-3** → $0.0077/min streaming
- Pros: Sub-300ms streaming, great for real-time agents
- Cons: Chinese not a strength, higher cost

### Suggested Architecture
```
Voice Message → Groq Whisper V3 (fast, cheap, batch)
                 ↓ fallback for Chinese
              SenseVoice/Fun-ASR-Nano (self-hosted, best CER)
                 ↓ optional on-device
              Moonshine Medium (local, offline, streaming)
```

---

## 5. Key Trends

1. **Non-autoregressive models** (SenseVoice, Paraformer) are inherently faster than autoregressive ones (Whisper) for batch transcription
2. **LPU/custom silicon** (Groq) makes even autoregressive Whisper models blazingly fast
3. **Streaming-first architectures** (Moonshine, Deepgram Flux) are purpose-built for voice agents, not adapted from batch models
4. **Chinese ASR** remains dominated by Alibaba's ecosystem (FunASR, SenseVoice, Fun-ASR-Nano) — Western providers lag significantly
5. **On-device** is mature for English (Moonshine, whisper.cpp) but less proven for Chinese
6. **Model size is less important than architecture** — Moonshine Medium (245M) beats Whisper Large V3 (1.5B) in both speed and accuracy

---

## Sources & Links

- [OpenAI Speech-to-Text Docs](https://developers.openai.com/api/docs/guides/speech-to-text)
- [Groq Speech-to-Text Docs](https://console.groq.com/docs/speech-to-text)
- [Deepgram Pricing](https://deepgram.com/pricing)
- [AssemblyAI Pricing](https://www.assemblyai.com/pricing)
- [AssemblyAI Universal-2 Research](https://www.assemblyai.com/research/universal-2)
- [Gladia Pricing](https://www.gladia.io/pricing)
- [Gladia Docs](https://docs.gladia.io)
- [Google Cloud STT Pricing](https://cloud.google.com/speech-to-text/pricing)
- [Azure Speech Overview](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/overview)
- [Azure Speech Pricing](https://azure.microsoft.com/en-us/pricing/details/speech/)
- [SenseVoice (GitHub)](https://github.com/FunAudioLLM/SenseVoice)
- [FunASR (GitHub)](https://github.com/modelscope/FunASR)
- [Fun-ASR-Nano (GitHub)](https://github.com/FunAudioLLM/Fun-ASR)
- [faster-whisper (GitHub)](https://github.com/SYSTRAN/faster-whisper)
- [whisper.cpp (GitHub)](https://github.com/ggml-org/whisper.cpp)
- [Moonshine (GitHub)](https://github.com/moonshine-ai/moonshine)
- [HuggingFace Open ASR Leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)

---

*Last updated: February 18, 2026*
