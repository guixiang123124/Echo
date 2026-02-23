# Echo API Key Storage Strategy (Launch)

## Goal
- Keep ASR/LLM provider secrets off client devices.
- Let apps keep only:
  - Cloud API base URL
  - User auth tokens (Echo backend)

## Recommended production model
1. Store provider keys in backend environment variables (Railway secrets).
2. Expose only Echo backend endpoints to iOS/macOS.
3. Backend calls OpenAI/Deepgram/Volcano on behalf of the user.
4. Client never persists raw provider keys.

## Current app support
- Client-side Keychain storage is supported (dev/testing).
- Cloud API URL can be preloaded via `CLOUD_API_BASE_URL` in app Info.plist.
- Auth (Email/Google/Apple) uses backend URL from Settings or bundled default.

## Backend secret checklist
- `OPENAI_API_KEY`
- `DEEPGRAM_API_KEY`
- `VOLCANO_APP_ID`
- `VOLCANO_ACCESS_KEY`
- (optional) `VOLCANO_RESOURCE_ID`

## Migration path
1. Add server-side ASR proxy endpoints (`/v1/asr/*`) in backend.
2. Switch app providers to backend proxy mode.
3. Remove client API key entry UI for non-admin users.
4. Keep admin-only debug key entry as fallback.
