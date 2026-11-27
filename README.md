# Rain Reporter

A lightweight, crowd-sourced Android app for reporting and checking live local rain conditions on a Mapbox map.

## Features

- **Live Rain Map:** Opens on Bandung (`MapboxStyles.STANDARD`) and animates to your live GPS location with a pulsing location indicator.
- **One-Tap Rain Reporting:** Report `Light`, `Moderate`, `Heavy`, `Storm`, or `Stopped` rain with an optional short note (up to 140 characters). Submissions lock to your real device GPS.
- **Merged Rain Zones & Clusters:** Nearby reports within 600 m merge into a single expanded rain zone (`Circle`/GeoJSON polygon) and cluster count badge colored by the strongest reported intensity.
- **30-Minute Freshness & Crowd Verification:** Reports automatically expire after 30 minutes or when nearby users within 500 m confirm rain has stopped (`Stopped here`).
- **Weather Radar Overlay (opt-in):** An optional Mapbox raster radar layer rendered *behind* the crowd rain zones and pins, toggled from the top bar. Enabled at build time via `--dart-define RADAR_TILES=...` (see below).
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

## Weather Radar Overlay

The radar overlay is **opt-in** and off by default: it only appears when you build
with a radar tile source. The layer is a Mapbox `RasterSource` + `RasterLayer`
in the `bottom` slot, so it sits above the base map but **behind** the crowd
rain zones (middle slot) and the annotation pins — exactly where you'd want a
radar backdrop.

Enable it by passing a radar tile source at build time:

```bash
# An XYZ template (https://…/{z}/{x}/{y}…)
flutter build apk --release --dart-define-from-file=mapbox.json \
  --dart-define RADAR_TILES="https://your-radar-host.example/{z}/{x}/{y}.png"

# Or a Mapbox-hosted tileset / TileJSON document
flutter build apk --release --dart-define RADAR_TILES="mapbox://my-radar-tileset"
```

Optional knobs:

- `RADAR_TILE_SIZE` (int, default `256`) — raster tile size in pixels.
- `RADAR_OPACITY` (double 0..1, default `0.6`) — overlay opacity.

The source must be reachable with your Mapbox token and must support the
`{z}/{x}/{y}` tile scheme (or be a `mapbox://` / TileJSON URL). If the tiles
fail to load, the overlay simply stays empty and the rest of the map keeps
working. In the app, the radar icon in the top bar toggles the overlay on/off.

## Continuous Integration

`.github/workflows/ci.yml` runs on push to `main` and on every pull request:

- **`flutter` job** — `flutter analyze` + `flutter test` (the whole Dart suite).
- **`worker` job** — `node --test` for the `rain-notifier` Cloudflare Worker.

No secrets are required; neither the Dart tests nor the worker tests need a
Mapbox token.

