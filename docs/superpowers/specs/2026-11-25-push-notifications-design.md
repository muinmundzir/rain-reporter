# Push Notifications (Geohash-Cell FCM + Cloudflare Worker) — Design Spec

**Date:** 2026-11-25  
**Scope:** Feature across Flutter Android app + Cloudflare Worker (`workers/rain-notifier/`)

---

## 1. Intent & Why

With a small user base in Bandung, friends rarely happen to open the app during the same 30-minute rain window. Sending instant push notifications when someone reports **Heavy** or **Storm** rain in the same ~5 km neighborhood brings nearby friends into the app right when it matters—without storing any user locations on a server and without upgrading Firebase to a paid/card-on-file Blaze plan.

---

## 2. Goals, Non-Goals, and Anti-Goals

- **Goals:**
  - Subscribe each Android device to a single 5-char geohash FCM topic (`rain_<geohash5>`, ~4.9 km × 4.9 km) based on its current GPS, unsubscribing from any previous cell when the user moves.
  - Trigger a push notification automatically when a user submits a `Heavy` or `Storm` rain report.
  - Authenticate push trigger requests in a free Cloudflare Worker by verifying the sender's Firebase Anonymous Auth ID token (RS256 JWT against Google's public JWKS) so unauthorized callers cannot spam FCM topics.
  - Deliver standard FCM `notification` + `data` payloads via FCM HTTP v1 API so Google Play Services wakes devices reliably on POCO HyperOS and Samsung One UI.
  - When a user taps a notification (from background or terminated state), open the app and center/zoom the map on the reported coordinates (`lat`, `lng`).
- **Non-Goals:**
  - Notifications for `Light`, `Moderate`, or `Stopped` reports.
  - 3×3 neighbor-cell topic subscriptions (single-cell only for MVP).
  - Server-side per-user location database or custom notification quiet hours.
  - iOS APNs provisioning.
- **Anti-Goals:**
  - Never embed Firebase Service Account keys or FCM server credentials inside the Flutter APK or commit them to git.
  - Never fail or block a rain report submission if the push Worker request fails or times out (push notification is best-effort after Firestore write succeeds).
  - Never show duplicate system popups to the reporter while they are in the foreground.

---

## 3. Constraints

- **Firebase Plan:** `rain-reporter-bdg` stays on the free Spark plan (no Cloud Functions, no billing card).
- **Cloudflare Worker:** Free tier (100k req/day, no card). Holds `FIREBASE_PROJECT_ID`, `FIREBASE_CLIENT_EMAIL`, and `FIREBASE_PRIVATE_KEY` as Wrangler secrets (never committed).
- **Android 13+ Permission:** Must declare `android.permission.POST_NOTIFICATIONS` in `AndroidManifest.xml` and request notification permission gracefully via `FirebaseMessaging.instance.requestPermission()`.
- **Worker URL Config:** Injected into Flutter via `--dart-define` in gitignored `mapbox.json` (or `env.json`, e.g., `NOTIFY_WORKER_URL`), with `mapbox.example.json` updated to document the key. If unset/empty, push triggering is a clean no-op.

---

## 4. Approaches Considered

1. **Standard FCM `notification` + `data` via Authenticated Cloudflare Worker (Picked):** Worker verifies Firebase ID token and sends a standard FCM `notification` + `data` message to `topic: "rain_<geohash5>"`.
   - *Tradeoff:* Relies on Android's native foreground suppression (so reporter doesn't get a popup while in-app) rather than strict client-side `uid` filtering, in exchange for rock-solid Google Play Services delivery on POCO HyperOS and Samsung One UI and zero extra local-notification plugins.
2. **Data-only FCM + `flutter_local_notifications`:** Worker sends a `data`-only message; a Dart background isolate filters `reporterUid != myUid` and posts a local notification.
   - *Tradeoff:* Strict self-suppression even if user immediately backgrounds the app, but OEM battery killers (HyperOS/One UI) frequently throttle background Flutter isolates.

**Why Option 1:** Delivery reliability on POCO and Samsung matters most for a small test group, and foreground suppression naturally avoids self-alerts.

---

## 5. Architecture & Decided Behavior

### A. Cloudflare Worker (`workers/rain-notifier/`)
- Endpoint: `POST /notify-rain`
- Auth: Requires `Authorization: Bearer <firebase-id-token>`. Verifies JWT signature (RS256) against Google's SecureToken JWKS (`https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com`), checks `aud == rain-reporter-bdg`, `iss == https://securetoken.google.com/rain-reporter-bdg`, and `exp > now`.
- Payload validation:
  - `intensity`: must be `'heavy'` or `'storm'` (returns `204` or `400` otherwise).
  - `geohash5`: must match `/^[0-9b-hjkmnp-z]{5}$/`.
  - `lat`, `lng`: valid numbers in `[-90, 90]` / `[-180, 180]`.
  - `note`: optional string, truncated to 140 chars.
- FCM HTTP v1 Send:
  - Signs a short-lived Google OAuth2 JWT using `FIREBASE_CLIENT_EMAIL` + `FIREBASE_PRIVATE_KEY` (Web Crypto API `RSASSA-PKCS1-v1_5` SHA-256), exchanges for an access token (`https://oauth2.googleapis.com/token` with scope `https://www.googleapis.com/auth/firebase.messaging`).
  - POSTs to `https://fcm.googleapis.com/v1/projects/rain-reporter-bdg/messages:send`:
    - `topic`: `rain_<geohash5>`
    - `notification`:
      - `title`: `'Heavy Rain Nearby'` or `'Storm Nearby'`
      - `body`: `note` if non-empty, else `'Reported in your area — tap to view map'`
    - `data`: `{ intensity, lat, lng, geohash5 }`
    - `android`: `{ priority: 'HIGH' }`

### B. Flutter Client (`lib/data/notification_service.dart`, `lib/ui/map_screen.dart`)
- **Interface (`NotificationService`):**
  - `Future<void> initialize({required void Function(double lat, double lng) onNotificationTap})`
  - `Future<void> updateLocationCell({required double lat, required double lng})`
  - `Future<void> notifyRainReport({required RainReport report})`
  - Provide `FcmNotificationService` (production) and `NoOpNotificationService` (tests & offline mode).
- **Topic Management:**
  - Computes `geohash5 = LocationPrivacy.encodeGeohash(lat, lng, precision: 5)` and topic `rain_$geohash5`.
  - Tracks current subscribed topic in memory (and `SharedPreferences` if persisted across restarts, or re-subscribes idempotently on launch); when the cell changes, unsubscribes old topic and subscribes new topic.
- **Triggering Push on Report:**
  - In `MapScreen._openReportSheet`, after `widget.repository.submitReport(...)` succeeds: if `intensity == RainIntensity.heavy || intensity == RainIntensity.storm`, calls `unawaited(widget.notificationService.notifyRainReport(report: report))` (errors swallowed so Firestore submission UX is never disrupted).
  - `FcmNotificationService.notifyRainReport` fetches `FirebaseAuth.instance.currentUser?.getIdToken()`, POSTs JSON to `NOTIFY_WORKER_URL/notify-rain` with 5s timeout.
- **Notification Tap Handling:**
  - Handles both `FirebaseMessaging.instance.getInitialMessage()` (app launched from terminated state) and `FirebaseMessaging.onMessageOpenedApp` (app resumed from background), animating the map camera to `(lat, lng)` at zoom `16`.

---

## 6. Left to the Builder (Defaults)

- Worker runtime: plain TypeScript Cloudflare Worker with `wrangler.toml` and `vitest` (or Node test) unit tests for payload/auth validation.
- In-memory OAuth access token caching inside the Worker isolate (reuse token until 60s before expiry).
- Exact Android notification channel ID (`rain_alerts`, high importance) in `AndroidManifest.xml`.
- Exact HTTP timeout (`5s`) for client-to-Worker push trigger call.
