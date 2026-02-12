# Echo Launch Runbook (No Firebase)

This runbook uses:

- API: Railway (`backend/`)
- DB: Railway Postgres
- Billing: Stripe
- Web: Vercel (optional control panel / marketing site)
- Clients: iOS + macOS (Xcode archives)

## 0) Confirm local build

```bash
cd /Users/xianggui/Downloads/Echo/backend
npm run typecheck

cd /Users/xianggui/Downloads/Echo
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16e' build
xcodebuild -project Echo.xcodeproj -scheme EchoMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## 1) Deploy API to Railway

1. Create a Railway project.
2. Add a PostgreSQL service.
3. Add a new service from this folder: `backend/`.
4. Set environment variables:
   - `DATABASE_URL`
   - `JWT_SECRET`
   - `CORS_ORIGIN`
   - `APPLE_AUDIENCE` (example: `com.xianggui.echo.app,com.echo.mac`)
   - `APPLE_ISSUER=https://appleid.apple.com`
   - optional storage:
     - `S3_ENDPOINT`
     - `S3_REGION`
     - `S3_BUCKET`
     - `S3_ACCESS_KEY_ID`
     - `S3_SECRET_ACCESS_KEY`
     - `S3_PUBLIC_BASE_URL`
5. Deploy and verify:
   - `GET https://<your-railway-domain>/healthz` returns `{ "ok": true }`.

CLI path (recommended once authenticated):

```bash
cd /Users/xianggui/Downloads/Echo
cp backend/.env.production.example backend/.env.production
# fill real values
./scripts/deploy_railway_backend.sh
```

## 2) Configure Stripe billing

1. In Stripe, create Product + recurring Price (monthly/yearly).
2. In Railway env, add:
   - `STRIPE_SECRET_KEY`
   - `STRIPE_DEFAULT_PRICE_ID`
   - `STRIPE_SUCCESS_URL`
   - `STRIPE_CANCEL_URL`
3. In Stripe Webhooks, add endpoint:
   - `https://<your-railway-domain>/v1/billing/stripe/webhook`
4. Subscribe to events:
   - `checkout.session.completed`
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
5. Add webhook secret to Railway:
   - `STRIPE_WEBHOOK_SECRET`

## 3) Optional: deploy website to Vercel

Use Vercel for marketing pages and account/checkout entry points.

1. Import repo into Vercel.
2. Set envs needed by your web app (API base URL, Stripe publishable key if web checkout is used).
3. Deploy production.

CLI path for static docs:

```bash
cd /Users/xianggui/Downloads/Echo
./scripts/deploy_docs_vercel.sh prod
```

## 4) Connect iOS/macOS apps to cloud

In Echo app Settings (iOS/macOS):

1. Set `Cloud API URL (Railway)` to your Railway HTTPS domain.
2. Turn on `Sync History to Cloud`.
3. Keep `Upload audio to cloud` OFF by default for privacy.
4. Sign in with Email or Apple.
5. Verify:
   - Account page shows plan status.
   - Home page sync card shows synced status after dictation.

## 5) App Store readiness checklist

1. iOS and macOS builds archive successfully in Xcode.
2. Privacy policy states:
   - local history storage
   - optional cloud metadata sync
   - optional cloud audio upload (if user enables)
3. Apple Sign In works in release build (matching `APPLE_AUDIENCE` bundle IDs).
4. Stripe purchase flow and webhook update plan status correctly.
5. Submit via Xcode Organizer to App Store Connect.

## 6) Firebase note

Firebase is not required for this architecture. Echo can ship fully with Railway + Postgres + Stripe + optional object storage.
