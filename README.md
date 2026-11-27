# Rain Reporter

A lightweight, crowd-sourced Android app for reporting and checking live local rain conditions on a Mapbox map.

## Features

- **Live Rain Map:** Opens on Bandung (`MapboxStyles.STANDARD`) and animates to your live GPS location with a pulsing location indicator.
- **One-Tap Rain Reporting:** Report `Light`, `Moderate`, `Heavy`, `Storm`, or `Stopped` rain with an optional short note (up to 140 characters). Submissions lock to your real device GPS.
- **Merged Rain Zones & Clusters:** Nearby reports within 600 m merge into a single expanded rain zone (`Circle`/GeoJSON polygon) and cluster count badge colored by the strongest reported intensity.
- **30-Minute Freshness & Crowd Verification:** Reports automatically expire after 30 minutes or when nearby users within 500 m confirm rain has stopped (`Stopped here`).
- **Zero-Friction Anonymous Auth:** Uses Firebase Anonymous Auth under the hood — no account signup required.

## Tech Stack

- **Mobile:** Flutter (Android)
- **Maps:** `mapbox_maps_flutter` (`MapboxStyles.STANDARD`, GeoJSON `FillLayer` / `LineLayer`, `PointAnnotationManager`)
- **Backend:** Firebase (Anonymous Auth + Cloud Firestore + Security Rules)
- **Location:** `geolocator`

## Running / Building Locally

1. Copy the Mapbox token template and add your public Mapbox token (`pk.*`):
   ```bash
   cp mapbox.example.json mapbox.json
   ```
2. Add your Mapbox downloads token (`sk.*` with `Downloads:Read` scope) to `~/.gradle/gradle.properties`:
   ```properties
   SDK_REGISTRY_TOKEN=sk.your_secret_token_here
   ```
3. Run tests or build the release APK:
   ```bash
   flutter test
   flutter build apk --release --dart-define-from-file=mapbox.json
   ```

## Push-notification hardening

The `rain-notifier` worker no longer trusts client-supplied rain data. When a
client posts to `POST /notify-rain` it now sends only a `reportId`; the worker
re-reads that report **authoritatively from Firestore** (via the same
service-account key it already uses for FCM) and derives the FCM topic cell,
intensity, note, and owner from the stored document. A report only alerts when
it still exists, is owned by the authenticated user, is not yet expired, and
its stored intensity is `heavy` or `storm`. This closes the spoofing path that
let any valid anonymous Firebase token forge alerts for arbitrary cells.

The service account used for FCM (`FIREBASE_CLIENT_EMAIL` /
`FIREBASE_PRIVATE_KEY`) must also be able to read the `reports` collection —
which is true for the project's Firebase admin service account by default.
