# Push Notifications (Geohash-Cell FCM + Cloudflare Worker) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver instant Android push notifications for `Heavy` and `Storm` rain reports within the same 5-char geohash cell (`rain_<geohash5>`) using FCM HTTP v1 triggered by an authenticated free Cloudflare Worker.

**Architecture:** Add a self-contained Cloudflare Worker in `workers/rain-notifier/` that verifies Firebase Auth ID tokens (RS256 against Google JWKS) and sends high-priority FCM HTTP v1 topic notifications. On the Flutter side, add `firebase_messaging` + `http`, introduce a testable `NotificationService` abstraction (`FcmNotificationService` + `NoOpNotificationService`), and wire topic subscription, best-effort push triggering, and notification-tap map centering into `MapScreen` and `main.dart`.

**Tech Stack:** TypeScript (Cloudflare Workers + Web Crypto API + `node --test`), Flutter, Dart, `firebase_messaging`, `http`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-11-25-push-notifications-design.md`

## Global Constraints

- Never commit Firebase Service Account keys, FCM secrets, or live Worker URLs in git (`mapbox.json` stays gitignored; Worker secrets live in Wrangler secrets only).
- Trigger push notifications ONLY for `RainIntensity.heavy` and `RainIntensity.storm` (never `light`, `moderate`, or `stopped`).
- Single-cell 5-char geohash topic format: `rain_<geohash5>` (matching `/^[0-9b-hjkmnp-z]{5}$/`).
- Push notification trigger is best-effort (`5s` timeout): failure must never block or fail a Firestore rain report submission.
- Keep all existing `MapScreen` and `RainReporterApp` test hooks backwards-compatible (default `notificationService` to `NoOpNotificationService()` in tests when omitted).

## Review Focus

- **Unauthorized Worker calls:** Missing, malformed, expired, wrong-`aud`, or bad-signature `Authorization: Bearer` tokens must return `401` and never call FCM (covered in Task 1).
- **Malformed/spam payloads:** Non-`heavy`/`storm` intensity, invalid `geohash5`, out-of-range `lat`/`lng`, or non-JSON body must return `400`; notes >140 chars are safely truncated (covered in Task 1).
- **Cell movement unsubscribe/subscribe:** Moving from cell A to cell B must unsubscribe `rain_<A>` and subscribe `rain_<B>`; staying in cell A must not re-subscribe redundantly (covered in Task 2).
- **Push failure isolation:** If the Worker returns `500`, times out, or throws a socket error, `submitReport` still succeeds and shows `'Rain report submitted!'` without crashing (covered in Task 2 & Task 3).
- **Notification tap navigation:** Tapping a push notification (from background or terminated state) with `lat`/`lng` in `data` must center/zoom the map to `(lat, lng)` at zoom `16` and refresh active reports for that area (covered in Task 3).

---

### Task 1: Cloudflare Worker (`workers/rain-notifier/`) with Firebase JWT auth & FCM HTTP v1

**Files:**
- Create: `workers/rain-notifier/package.json`
- Create: `workers/rain-notifier/wrangler.toml`
- Create: `workers/rain-notifier/src/validation.ts`
- Create: `workers/rain-notifier/src/firebase_auth.ts`
- Create: `workers/rain-notifier/src/fcm.ts`
- Create: `workers/rain-notifier/src/index.ts`
- Create: `workers/rain-notifier/README.md`
- Test: `workers/rain-notifier/test/worker.test.mjs`

**Interfaces:**
- Produces:
  - HTTP endpoint `POST /notify-rain` expecting `Authorization: Bearer <firebase-id-token>` and JSON `{ geohash5, intensity, lat, lng, note? }`.
  - Pure testable `handleRequest(request, env, deps)` handler accepting injectable `verifyToken` and `sendFcm` dependencies.

- [ ] **Step 1: Scaffold `workers/rain-notifier/` (`package.json`, `wrangler.toml`) and write failing tests in `workers/rain-notifier/test/worker.test.mjs`**

Tests cover:
- Returns `405` for non-POST requests and `404` for unknown paths.
- Returns `401` when `Authorization` header is missing or token verification fails.
- Returns `400` for invalid JSON, non-`heavy`/`storm` intensity (`light`, `moderate`, `stopped`), invalid `geohash5`, or out-of-range `lat`/`lng`.
- Calls `sendFcm` with `topic: "rain_<geohash5>"`, `title: "Heavy Rain Nearby"` / `"Storm Nearby"`, truncated `body` (<=140 chars or default fallback), and `data: { intensity, lat, lng, geohash5 }`, returning `200`.

- [ ] **Step 2: Run Worker tests to verify they fail**

Run: `node --test test/worker.test.mjs` in `/home/carbon/projects/learn/rain-reporter/workers/rain-notifier`
Expected: FAIL (missing `src/index.mjs` or `src/handler.mjs`).

- [ ] **Step 3: Implement Worker (`src/validation.mjs`, `src/firebase_auth.mjs`, `src/fcm.mjs`, `src/index.mjs`) and `README.md`**

*(Use clean ES modules `.mjs` with JSDoc types so `wrangler deploy` and `node --test` both run natively with zero build step or extra dev dependencies!)*
- `validation.mjs`: validates `intensity in ['heavy', 'storm']`, `geohash5` matching `/^[0-9b-hjkmnp-z]{5}$/`, finite `lat` in `[-90, 90]`, finite `lng` in `[-180, 180]`, optional `note` trimmed & truncated to 140 chars.
- `firebase_auth.mjs`: fetches & caches Google SecureToken JWKS (`https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com`), imports JWK via `crypto.subtle.importKey`, verifies RS256 signature, and checks `aud == projectId`, `iss == https://securetoken.google.com/${projectId}`, `exp > now`, `sub` non-empty.
- `fcm.mjs`: signs short-lived RS256 OAuth2 assertion with `FIREBASE_CLIENT_EMAIL` + `FIREBASE_PRIVATE_KEY` via Web Crypto API, caches OAuth access token in isolate memory until 60s before expiry, and POSTs high-priority `notification` + `data` message to `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`.
- `index.mjs`: exports `createHandler(deps)` and default `{ fetch }`.
- `README.md`: 3-step deploy guide (`wrangler login`, `wrangler secret put ...`, `wrangler deploy`).

- [ ] **Step 4: Run Worker tests to verify they pass**

Run: `node --test test/worker.test.mjs` in `/home/carbon/projects/learn/rain-reporter/workers/rain-notifier`
Expected: PASS (all tests green).

- [ ] **Step 5: Commit**

```bash
git add workers/rain-notifier
git commit -m "feat(worker): add authenticated Cloudflare Worker for geohash-cell FCM push"
```

---

### Task 2: Flutter `NotificationService` (`FcmNotificationService` + `NoOpNotificationService`) & Android manifest setup

**Files:**
- Modify: `pubspec.yaml`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `mapbox.example.json`
- Create: `lib/data/notification_service.dart`
- Test: `test/data/notification_service_test.dart`

**Interfaces:**
- Consumes: `RainReport` (`lib/domain/rain_report.dart`), `RainIntensity` (`lib/domain/rain_intensity.dart`), `LocationPrivacy.encodeGeohash` (`lib/domain/location_privacy.dart`).
- Produces:
  - `abstract class NotificationService`:
    - `Future<void> initialize({required void Function(double lat, double lng) onNotificationTap})`
    - `Future<void> updateLocationCell({required double lat, required double lng})`
    - `Future<void> notifyRainReport({required RainReport report})`
  - `class NoOpNotificationService implements NotificationService`
  - `class FcmNotificationService implements NotificationService` (with injectable `subscribeToTopic`, `unsubscribeFromTopic`, `getIdToken`, and `http.Client` for deterministic unit tests).

- [ ] **Step 1: Add `firebase_messaging` and `http` packages, update `AndroidManifest.xml` and `mapbox.example.json`**

- Run `flutter pub add firebase_messaging http`.
- Add `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />` and `<meta-data android:name="com.google.firebase.messaging.default_notification_channel_id" android:value="rain_alerts" />` to `android/app/src/main/AndroidManifest.xml`.
- Add `"NOTIFY_WORKER_URL": "https://rain-notifier.YOUR_SUBDOMAIN.workers.dev"` to `mapbox.example.json`.

- [ ] **Step 2: Write failing unit tests in `test/data/notification_service_test.dart`**

Cover:
- `updateLocationCell subscribes to rain_<geohash5> and avoids redundant re-subscribe for same cell`
- `updateLocationCell unsubscribes previous cell topic when moving to a new cell`
- `notifyRainReport posts to /notify-rain with Bearer token for heavy and storm reports`
- `notifyRainReport is a no-op for light, moderate, and stopped reports`
- `notifyRainReport is a no-op when workerUrl is empty and swallows HTTP errors without throwing`

- [ ] **Step 3: Run unit tests to verify they fail**

Run: `flutter test test/data/notification_service_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: FAIL (missing `notification_service.dart`).

- [ ] **Step 4: Implement `lib/data/notification_service.dart` and verify tests pass**

Run: `flutter test test/data/notification_service_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock android/app/src/main/AndroidManifest.xml mapbox.example.json lib/data/notification_service.dart test/data/notification_service_test.dart
git commit -m "feat(data): add NotificationService with geohash topic sync and Worker push client"
```

---

### Task 3: Wire `NotificationService` into `MapScreen` and `main.dart`

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/ui/map_screen.dart`
- Modify: `test/widget_test.dart`

**Interfaces:**
- Consumes: `NotificationService`, `FcmNotificationService`, `NoOpNotificationService` (Task 2).
- Produces: `RainReporterApp` and `MapScreen` accept optional `NotificationService? notificationService` (defaulting to `const NoOpNotificationService()` when omitted).

- [ ] **Step 1: Write failing widget tests in `test/widget_test.dart`**

Add tests with a `_RecordingNotificationService` spy:
- `initializes notification service, subscribes to location cell on GPS fix, and notifies on Heavy report (not Light)`
- `centers map and refreshes reports when notification tap callback fires`

- [ ] **Step 2: Run widget tests to verify they fail**

Run: `flutter test test/widget_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: FAIL (missing `notificationService` parameter).

- [ ] **Step 3: Wire `NotificationService` in `lib/main.dart` and `lib/ui/map_screen.dart`**

- In `lib/main.dart`: read `const notifyWorkerUrl = String.fromEnvironment('NOTIFY_WORKER_URL');`. When Firebase initializes, construct `FcmNotificationService(workerUrl: notifyWorkerUrl)`; in offline fallback, use `const NoOpNotificationService()`. Pass `notificationService` into `RainReporterApp` → `MapScreen`.
- In `lib/ui/map_screen.dart`:
  - Call `widget.notificationService.initialize(onNotificationTap: _handleNotificationTap)` in `initState()`.
  - Call `unawaited(widget.notificationService.updateLocationCell(lat: loc.lat, lng: loc.lng))` in `_initLocation()` and `_recenterToUserLocation()` when `loc != null`.
  - In `_openReportSheet()`, capture `final report = await widget.repository.submitReport(...)` and call `unawaited(widget.notificationService.notifyRainReport(report: report))` (best-effort, never blocks SnackBar).
  - Add `_handleNotificationTap(double lat, double lng)`: refreshes reports for `(lat, lng)` and animates map camera to `(lat, lng)` at `_userFocusZoom` (`16.0`).

- [ ] **Step 4: Run full test suite (Flutter + Worker) and `dart analyze`**

Run: `flutter test && dart analyze && (cd workers/rain-notifier && node --test test/worker.test.mjs)` in `/home/carbon/projects/learn/rain-reporter`
Expected: All Flutter and Worker tests pass, `dart analyze` reports zero issues.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart lib/ui/map_screen.dart test/widget_test.dart
git commit -m "feat(map): wire geohash push subscriptions, report triggers, and notification tap navigation"
```
