# Echo API (Railway)

Minimal cloud backend for Echo (no Firebase):

- Auth: Email/Password + Apple Sign In + Google Sign-In token exchange
- Sync: Recording history metadata + dictionary terms
- Storage: Optional audio upload to S3/R2
- DB: PostgreSQL

## 1) Local run

```bash
cd backend
npm install
cp .env.example .env
# edit DATABASE_URL + JWT_SECRET
npm run dev
```

Production-like run:

```bash
npm run build
npm start
```

Health check:

```bash
curl http://127.0.0.1:8080/healthz
```

## 2) Railway deploy

1. Create a new Railway service from this `backend/` directory.
2. Add a PostgreSQL plugin and copy its `DATABASE_URL`.
3. Set env vars:
   - `DATABASE_URL`
   - `JWT_SECRET` (long random string)
   - `CORS_ORIGIN` (for web console origin; use `*` during initial test)
   - `APPLE_AUDIENCE` (comma-separated bundle IDs, required for Apple login verification)
   - `GOOGLE_AUDIENCE` (comma-separated Google OAuth Client IDs, required for Google ID token verification)
4. Optional Stripe billing envs:
   - `STRIPE_SECRET_KEY`
   - `STRIPE_WEBHOOK_SECRET`
   - `STRIPE_DEFAULT_PRICE_ID`
   - `STRIPE_SUCCESS_URL`
   - `STRIPE_CANCEL_URL`
5. Optional object storage envs for audio files:
   - `S3_ENDPOINT`
   - `S3_REGION`
   - `S3_BUCKET`
   - `S3_ACCESS_KEY_ID`
   - `S3_SECRET_ACCESS_KEY`
   - `S3_PUBLIC_BASE_URL`
6. Deploy. Use `/healthz` to verify.

CLI-first deployment (after `railway login`):

```bash
cd /Users/xianggui/Downloads/Echo
cp backend/.env.production.example backend/.env.production
# fill real values in backend/.env.production
./scripts/deploy_railway_backend.sh
```

## Stripe bootstrap automation

You can auto-create (or reuse) Echo product/prices and webhook by script:

```bash
cd /Users/xianggui/Downloads/Echo/backend
export STRIPE_SECRET_KEY=sk_live_xxx
export ECHO_API_BASE_URL=https://echo-api-production-c83b.up.railway.app
export RAILWAY_SYNC=true
export RAILWAY_SERVICE_NAME=echo-api
export RAILWAY_ENVIRONMENT=production
node scripts/bootstrap_stripe.mjs
```

Optional pricing overrides:

```bash
export ECHO_MONTHLY_USD_CENTS=999
export ECHO_YEARLY_USD_CENTS=9999
```

## 3) Connect iOS/macOS clients

In app settings:

- `Cloud API URL (Railway)` -> your Railway service URL
- `Upload audio to cloud` -> optional (off by default for privacy)

The app stays local-first:

- Local SQLite remains source of truth for active UX
- Cloud sync is additive, user-scoped, and can be turned off

## 4) Current API

- `POST /v1/auth/register`
- `POST /v1/auth/login`
- `POST /v1/auth/apple`
- `POST /v1/auth/google`
- `GET /v1/auth/me`
- `GET /v1/billing/status`
- `POST /v1/billing/create-checkout-session`
- `POST /v1/billing/create-portal-session`
- `POST /v1/billing/stripe/webhook`
- `POST /v1/sync/recordings`
- `GET /v1/sync/recordings`
- `GET /v1/sync/dictionary`
- `POST /v1/sync/dictionary`
- `DELETE /v1/sync/dictionary/:id`
