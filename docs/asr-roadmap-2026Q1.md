# Echo ASR Roadmap (2026 Q1)

## North Star
上线稳定优先；差异化靠“更快 + 更准 + 上下文纠错”。

## Phase 0 — Current baseline (done)
- Default: `gpt-4o-transcribe`
- Keep OpenAI trio + Volcano in benchmark matrix
- AutoEdit default OFF (advanced mode)
- Volcano batch + stream path in codebase

## Phase 1 — Immediate post-launch (1-2 weeks)
1. **Google/Apple login fully stable**
2. **Deepgram benchmark pass** (nova-3, stream + batch)
3. **Provider routing strategy**
   - EN long-form: whisper-1 / gpt-4o-mini fallback
   - ZH + mixed: gpt-4o-transcribe primary, Volcano as optional
4. **Quality dashboard**
   - latency p50/p95
   - truncation rate
   - named-entity error rate (brand/person/product)

## Phase 2 — Speed differentiation (2-4 weeks)
1. Add **Deepgram streaming** as low-latency mode candidate
2. Add **Groq Whisper batch** adapter for ultra-fast offline-finalization
3. Build “dual-path” mode:
   - realtime text (stream)
   - final rewrite pass (optional)

## Phase 3 — Accuracy differentiation (4-8 weeks)
1. **Context-aware AutoEdit v2**
   - user dictionary
   - conversation history window
   - domain profile (medical/legal/dev)
2. **Named entity correction layer**
3. **Chinese/mixed-language tuned prompts and hotwords**

## Candidate model shortlist (from research)
- Cloud streaming: Deepgram Nova-3, Gladia
- Cloud batch speed: Groq Whisper
- CN-focused open source: SenseVoice / FunASR Nano
- On-device exploration: whisper.cpp / Moonshine (Apple Silicon)

## Decision policy
- If p95 latency > 2x baseline OR truncation rises: auto-fallback to OpenAI default.
- Any new provider must pass:
  - 50-sample regression set
  - CN + EN + code-switch mix
  - stream and batch reliability checks
