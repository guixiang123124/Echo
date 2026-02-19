# Google OAuth Setup Checklist (Echo iOS + macOS + Backend)

> Status: code integration complete. This checklist is for final credential wiring and live verification.

## 1) GCP Console

Open: `https://console.cloud.google.com/apis/credentials`

Create **two OAuth client IDs**:

- iOS client
  - App type: iOS
  - Bundle ID: `com.echo.app`
- macOS client
  - App type: macOS
  - Bundle ID: `com.echo.mac`

Copy both client IDs.

---

## 2) App configuration

Set in app Info.plist values (generated from `project.yml`):

- `GOOGLE_CLIENT_ID_IOS` = `<ios-client-id>`
- `GOOGLE_CLIENT_ID_MAC` = `<mac-client-id>`

Current source location:
- `project.yml` (EchoApp info properties)
- `project.yml` (EchoMac info properties)

---

## 3) Backend configuration

Set env var on backend deployment:

- `GOOGLE_AUDIENCE=<ios-client-id>,<mac-client-id>`

Backend endpoint already implemented:
- `POST /v1/auth/google`

Token verification:
- `google-auth-library` verifies `idToken`
- issuer and verified email checks enabled

---

## 4) Deploy + verify

1. Deploy backend with new env vars
2. Open Echo iOS/macOS AuthSheet
3. Tap **Sign in with Google**
4. Confirm returned user provider is `google`
5. Confirm account linking works (same email existing account should be linked, not duplicated)

---

## 5) Troubleshooting

- `invalid_google_token`:
  - Check `GOOGLE_AUDIENCE` includes the exact client ID used by app platform
  - Check Google client type matches platform (iOS vs macOS)
- Missing token in app:
  - Ensure `GOOGLE_CLIENT_ID_IOS` / `GOOGLE_CLIENT_ID_MAC` are populated
- Account mismatch:
  - Backend links by `google_sub` first, then by email as fallback
