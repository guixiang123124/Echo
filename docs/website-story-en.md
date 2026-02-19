# Echo — Product Story (English Draft)

## One-line story
**Echo is the fastest path from thought to editable text.**

## Why Echo exists
Typing is precise but slow.
Pure voice is fast but hard to control.

Echo combines the best of both:
- the speed of speaking,
- the clarity of text,
- and the control of editing.

This is not “typing vs voice.”
It is a new interaction model: **voice input + visual text editing**.

## What we are building
Echo helps people speak naturally and get clean, editable text in real time.

Core experience:
1. Press and speak
2. See live transcription while speaking
3. Get a refined final result
4. Edit instantly if needed

## Product principles
1. **Fast first token** — users should see text quickly.
2. **Stable live output** — continuous, low-jitter transcription.
3. **Strong final quality** — names, terms, and context stay accurate.
4. **Always editable** — users remain in control.

## Near-term model strategy
For real-time streaming, Echo focuses on:
- **Deepgram Stream** (low latency, mature infra)
- **Volcano Stream** (strong Chinese potential)
- **Google STT v2** (multi-language robustness; benchmark track)

Default non-stream baseline remains:
- **OpenAI gpt-4o-transcribe**

## Platform roadmap
- **Phase 1:** macOS + iOS
- **Phase 2:** Windows + Android

## What makes Echo different
Echo is not trying to be “just another STT app.”
We optimize the full loop from intent to output:
- speaking speed,
- visual comprehension,
- and final editability.

Our goal is to outperform existing products on speed, quality, and interaction design.

## Website copy starter (short)
**Hero:**
Speak at the speed of thought. Edit with precision.

**Subheadline:**
Echo turns your voice into clean, editable text in real time — fast, accurate, and built for serious work.

**CTA:**
Download for macOS / iOS
