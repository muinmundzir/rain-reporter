# Rain Reporter — Design Spec

**Date:** 2026-11-13  
**Target Platform:** Android (Flutter, structured for future iOS support)

---

## 1. Intent & Why

People frequently need to know whether it is actually raining *right now* in a specific neighborhood or along a commute—faster and more accurately than coarse weather forecasts or radar delays. `rain-reporter` is a lightweight, community-powered mobile app where anyone can check live local rain conditions on a map and contribute a report in a few seconds with zero signup friction.

---

## 2. Goals, Non-Goals, and Anti-Goals

### Goals
- **Check rain in seconds:** Open the app directly into a live map showing active nearby rain pins.
- **Report in seconds:** One-tap Report flow with intensity selection (`Light`, `Moderate`, `Heavy`, `Storm`, `Stopped`) and an optional short note.
- **High signal, low staleness:** Reports automatically expire after 30 minutes or earlier when nearby users confirm rain has stopped.
- **Zero onboarding friction:** Anonymous authentication under the hood; no login screen required to view or report.
- **Location privacy:** Fuzz submitted GPS coordinates (~100–200 m) so users do not expose their exact home or workplace address.

### Non-Goals (Deferred to v2+)
- Push notifications / nearby rain alerts (FCM).
- iOS release and App Store setup (Flutter keeps the codebase portable, but Android is the sole target for MVP).
- User profiles, leaderboards, or social sign-in (Google Sign-In is optional for later).
- Photo uploads or media attachments.
- Historical rain logs or analytics dashboards beyond the live 30-minute window.

### Anti-Goals
- **Stale map clutter:** Never show hours-old rain pins as if they are live.
- **Mandatory login wall:** Never force account creation before viewing or submitting a first report.
- **Exact home tracking:** Never store or broadcast raw, unfuzzed user coordinates on public report documents.

---

## 3. Constraints

- **Platform:** Android only for MVP, built with Flutter (`google_maps_flutter`).
- **Google Maps Setup:** Requires a Google Cloud project with Maps SDK for Android enabled and a restricted Android API key configured in `android/app/src/main/AndroidManifest.xml`.
- **Backend:** Firebase (Cloud Firestore + Firebase Anonymous Auth).
- **Firestore TTL:** Firestore TTL policies delete expired documents asynchronously (typically within ~24–72 hours); therefore, **client queries and Firestore Security Rules must actively filter on `expiresAt > request.time`** so expired reports disappear immediately at the 30-minute mark.
- **Firestore Security Rules:** All `firestore.rules` authoring/modification must be delegated to the `firestore-rules-author` subagent during implementation.

---

## 4. Approaches Considered

### Mobile Framework
1. **Flutter (Picked):** Single Dart codebase targeting Android first, with straightforward path to iOS later without rewriting UI or Firebase integration. Trades slightly larger binary size and platform-channel dependency on `google_maps_flutter` for cross-platform readiness.
2. **Native Kotlin + Jetpack Compose:** Best-in-class Android-only ergonomics and Compose Maps integration, but requires a full rewrite to support iOS later.
3. **React Native / Expo:** Cross-platform, but native map + location background/permission handling often requires more native config friction than Flutter.

### Backend & Realtime Sync
1. **Firebase (Firestore + Anonymous Auth + Geoqueries) (Picked):** Zero server maintenance, built-in anonymous auth, native offline/realtime snapshot listeners in Flutter, and straightforward geohash-based bounding queries. Trades complex relational/spatial SQL queries (like PostGIS) for fast MVP delivery.
2. **Supabase (PostgreSQL + PostGIS + Realtime):** Strong spatial queries via PostGIS, but requires managing Postgres schemas/RLS/realtime subscriptions and auth token plumbing manually.
3. **Custom Go/Elixir API + WebSockets:** Full control over spatial indexing and rate-limiting, but excessive infrastructure overhead for an MVP.

### Map Provider
1. **Google Maps via `google_maps_flutter` (Picked):** Familiar Android map UX, reliable performance, and rich marker/camera controls. Trades free zero-config setup (`flutter_map`/OSM) for requiring a Google Cloud API key and billing account.
2. **OpenStreetMap via `flutter_map`:** No API key or billing needed, but less familiar Android map styling/tiles without a third-party tile provider.

---

## 5. Architecture & Decided Behavior

### Core Screens & Flow
1. **Live Map Screen (Home / Entry):**
   - Requests foreground location permission on launch; centers camera on user's current location (falls back to last known or default city view if denied, while still allowing browsing).
   - Displays active rain pins within the visible map region / nearby radius.
   - Pin styling reflects intensity (`Light`, `Moderate`, `Heavy`, `Storm`) and freshness.
   - Primary floating action: **"Report Rain"** button (one-tap trigger).
2. **Quick Report Bottom Sheet:**
   - Opens on tapping **Report Rain**.
   - Intensity selector: `Light`, `Moderate`, `Heavy`, `Storm`, `Stopped`.
   - Optional short text note (e.g., max 140 chars).
   - Submits report with fuzzed coordinates (~100–200 m random offset) and `expiresAt = createdAt + 30 minutes`.
3. **Pin Detail Bottom Sheet:**
   - Opens when tapping any active pin on the map.
   - Shows intensity, relative time ("4m ago"), optional note, and confirmation count.
   - Actions:
     - **"Still raining" (Confirm):** Increments confirmation count (one vote per anonymous `uid`, optionally extends/refreshes visibility within rules).
     - **"Stopped here":** Marks/submits stopped status so nearby stale rain reports are cleared or superseded.

### Data Model (Firestore)
- Collection: `reports/{reportId}`
  - `uid`: string (Firebase Anonymous Auth UID)
  - `intensity`: `'light' | 'moderate' | 'heavy' | 'storm' | 'stopped'`
  - `note`: string? (optional, max 140 chars)
  - `lat`: number (fuzzed ~100–200 m)
  - `lng`: number (fuzzed ~100–200 m)
  - `geohash`: string (for bounding-box / radius geoqueries)
  - `confirmCount`: number (default `1`)
  - `stoppedCount`: number (default `0`)
  - `createdAt`: timestamp (server timestamp)
  - `expiresAt`: timestamp (`createdAt + 30 minutes`, also configured as Firestore TTL field)
- Subcollection (or separate collection) for per-user vote deduplication & rate-limiting:
  - `reports/{reportId}/votes/{uid}`: `{ type: 'confirm' | 'stopped', createdAt }`
  - `rateLimits/{uid}`: `{ lastReportAt: timestamp }` (enforced in Firestore Security Rules, e.g., 1 report per 2–5 minutes per `uid`).

### Privacy & Anti-Spam
- **Coordinate Fuzzing:** Client applies a random offset of ~100–200 m before writing `lat`, `lng`, and `geohash` to Firestore.
- **Anonymous Auth:** App silently signs in with `FirebaseAuth.instance.signInAnonymously()` on startup.
- **Rate Limiting:** Firestore Security Rules enforce cooldown between reports per `uid` and one vote per `uid` per report.

---

## 6. Left to the Builder

- Exact Flutter project structure and state management choice (e.g., Riverpod / Provider / Bloc — keep it simple and idiomatic).
- Geohash library/helper selection for querying visible map bounds in Firestore.
- Custom map marker icons/colors and bottom sheet visual polish.
- Firebase project provisioning (`flutterfire configure`), Google Maps API key wiring, and Firestore composite indexes + TTL policy setup.
- Unit tests for coordinate fuzzing, expiration filtering, and widget tests for the report/pin sheets.
