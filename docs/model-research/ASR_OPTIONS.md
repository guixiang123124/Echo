# Echo ASR Options (Latency / Cost / Privacy)

This doc summarizes realistic ASR paths for Echo, from "ship now" (cloud Whisper) to next-step upgrades (better cloud transcribe models, and on-device speech-to-text for Apple Silicon).

## V1 (Ship Now): OpenAI Whisper

- Provider: OpenAI
- Model: `whisper-1`
- Strengths: simple, stable, good multilingual quality
- Tradeoffs: network round-trip latency; audio leaves device

Recommended when:
- You want fastest time-to-market.
- You can accept cloud processing for ASR.

## V1.5 (Upgrade, Still OpenAI Cloud): GPT-4o Transcribe

OpenAI offers newer speech-to-text models that improve WER and language recognition vs classic Whisper:

- `gpt-4o-mini-transcribe`: best default for speed + cost.
- `gpt-4o-transcribe`: higher accuracy, higher cost.
- `gpt-4o-transcribe-diarize`: adds speaker diarization (multi-speaker labeling).

Implementation notes:
- All work with the same OpenAI API key.
- You can expose them as a simple "ASR Model" dropdown in Settings.

## On-Device (Apple Silicon): Lowest Latency + Best Privacy

If the product direction is "audio stays on device", on-device ASR is the strongest long-term path.

Options worth evaluating:

### WhisperKit (Core ML)
- Good on-device stack for Apple Silicon.
- Features: streaming, timestamps, VAD, etc.

### MLX-based Whisper (Apple Silicon optimized)
- `lightning-whisper-mlx`: optimized Whisper implementation for Apple Silicon via MLX.
- Target: very low latency on modern Macs.

### whisper.cpp / faster-whisper
- `whisper.cpp`: widely used C/C++ implementation (often fast; easy to embed).
- `faster-whisper` (CTranslate2): strong speed/accuracy tradeoff; supports quantization.

Operational tradeoffs for on-device:
- App size increases (models).
- Need model download/cache management and battery/thermal considerations.
- You still may want cloud fallbacks for older devices or very large models.

## Domestic (China) Cloud Options (Future)

If you want in-country routing or cost control, domestic ASR APIs can be integrated behind the same "Speech Provider" interface.

Example: ByteDance/Volcengine (WebSocket ASR / speech translate APIs).

Tradeoffs:
- Separate auth + keys.
- Different audio requirements/format constraints.
- Model quality varies by language and domain.

## Suggested Roadmap (Pragmatic)

1. Keep `whisper-1` as default for V1 App Store submission.
2. Add optional OpenAI transcribe models as "experimental":
   - `gpt-4o-mini-transcribe` (fast)
   - `gpt-4o-transcribe` (accurate)
3. Start a separate branch for on-device ASR (WhisperKit first).
4. Only after product-market fit: add domestic providers.

