# ASR Provider Key Wiring (CLI + App)

## App (UI settings)

- OpenAI ASR key → provider `openai_whisper`
- Volcano keys → `volcano_app_id`, `volcano_access_key`
- Deepgram key → `deepgram`

## CLI benchmark (no Keychain prompts)

CLI prioritizes env/file over Keychain.

### OpenAI
- Env: `OPENAI_API_KEY`
- File: `~/.openai_key`

### Volcano
- Env: `VOLCANO_APP_ID`, `VOLCANO_ACCESS_KEY`
- Optional: `VOLCANO_RESOURCE_ID`, `VOLCANO_ENDPOINT`
- File: `~/.volcano_token` (access key only; app id defaults to `6490217589`)

### Deepgram
- Env: `DEEPGRAM_API_KEY`
- File: `~/.deepgram_key`

## Example run

```bash
swift run --package-path Packages/EchoCore ASRBenchmarkCLI \
  /tmp/echo-bench/real_zh1.wav /tmp/echo-bench/real_zh2.wav
```

The report will include unavailable providers as `Provider unavailable` so gaps are visible.
