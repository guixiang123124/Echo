# Echo Production Roadmap (Vercel + Railway, No Firebase)

## 1. Services

- `Railway API` (`backend/`):
  - auth (`/v1/auth/*`)
  - sync (`/v1/sync/*`)
  - postgres persistence
- `Postgres`:
  - users
  - recordings
  - dictionary terms
- `Object storage` (optional):
  - S3 or Cloudflare R2 for audio blobs
- `Vercel`:
  - marketing site + docs + account portal (optional)

## 2. Environment map

### Railway API

- `DATABASE_URL`
- `JWT_SECRET`
- `CORS_ORIGIN`
- Optional storage:
  - `S3_ENDPOINT`
  - `S3_REGION`
  - `S3_BUCKET`
  - `S3_ACCESS_KEY_ID`
  - `S3_SECRET_ACCESS_KEY`
  - `S3_PUBLIC_BASE_URL`

### iOS/macOS app runtime settings

- `Cloud API URL (Railway)` in app settings
- `Upload audio to cloud (optional)` toggle

Defaults remain privacy-safe:

- local history on-device
- cloud sync opt-in
- audio upload off by default

## 3. Subscription path (Stripe)

Recommended:

1. Stripe products/plans in dashboard.
2. Vercel web checkout + customer portal page.
3. Railway webhook endpoint:
   - receives Stripe events
   - updates subscription status in Postgres (`users` extension table)
4. App reads entitlements from API and gates pro features.

## 4. App Store submission compatibility

This stack is App Store-safe without Firebase as long as:

1. privacy policy discloses cloud processing when enabled.
2. keyboard extension purpose strings are complete.
3. permissions are requested at action time (mic/input/accessibility).
4. account deletion/export path is available before release.

## 5. Suggested release order

1. Ship local-only build to TestFlight/internal.
2. Enable Railway auth + metadata sync.
3. Add optional object storage upload.
4. Add Stripe billing + entitlement checks.
5. Submit iOS/macOS production builds.
