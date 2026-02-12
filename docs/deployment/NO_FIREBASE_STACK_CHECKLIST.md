# Echo No-Firebase Launch Checklist

This project now supports the stack:

- Client: macOS + iOS + Keyboard Extension (local SQLite first)
- API: Railway (`backend/`)
- Database: Railway Postgres
- Storage: S3/R2 (optional, for audio blobs only when enabled)
- Website: Vercel (`docs/` or separate web console)

## A. Core infra

1. Provision Railway Postgres and API service.
2. Set API env vars:
   - `DATABASE_URL`
   - `JWT_SECRET`
   - `CORS_ORIGIN`
   - `APPLE_AUDIENCE`
   - (if billing) `STRIPE_SECRET_KEY` + `STRIPE_WEBHOOK_SECRET`
3. (Optional) Configure object storage env vars.
4. Verify `GET /healthz` returns `{ "ok": true }`.

## B. App wiring

1. In Echo iOS/macOS Settings:
   - Fill `Cloud API URL (Railway)`.
   - Keep `Upload audio to cloud` OFF by default.
2. Test sign-up/sign-in in app.
3. Record once and ensure:
   - Local history appears immediately.
   - Sync status card updates to synced.

## C. Privacy defaults

1. Keep local history enabled.
2. Keep cloud sync opt-in.
3. Keep cloud audio upload opt-in and off by default.
4. Update privacy policy text in `docs/privacy.html`.

## D. App Store preflight

1. iOS target:
   - microphone usage strings set
   - keyboard extension enabled and tested
2. macOS target:
   - Accessibility/Input Monitoring flow tested
3. Release build archive passes:
   - no Firebase references
   - no hardcoded API keys
4. Upload build in Xcode Organizer to App Store Connect.

## E. Recommended next hardening

1. Add refresh tokens + token revocation.
2. Add per-user rate limiting.
3. Add background sync queue and retry policy.
4. Add migration job for local-to-cloud backfill.
