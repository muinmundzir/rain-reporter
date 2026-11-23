# Mapbox Native SDK Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `rain-reporter` from `flutter_map` + Esri raster tiles to the official native Mapbox Maps SDK (`mapbox_maps_flutter`) with `MapboxStyles.STANDARD`, meter-accurate GeoJSON rain zones, `PointAnnotationManager` pins/cluster badges, and native pulsing user location.

**Architecture:** Extract pure-Dart GeoJSON circle polygon generation (`lib/domain/rain_zone_geojson.dart`) and `dart:ui` PNG marker rendering (`lib/ui/mapbox_marker_icons.dart`). Wire `mapbox_maps_flutter` + Mapbox Maven repo + gitignored `mapbox.json` (`--dart-define-from-file=mapbox.json`). Refactor `MapScreen` to render `mapbox_maps_flutter`'s `MapWidget` in production (`useNativeMapView: true`) and a lightweight test surface driven by `MapTestController` in headless `flutter test` (`useNativeMapView: false`).

**Tech Stack:** Flutter, Dart, `mapbox_maps_flutter`, `geolocator`, `flutter_test`, Android Gradle Kotlin DSL.

**Spec:** `docs/superpowers/specs/2026-11-23-mapbox-migration-design.md`

## Global Constraints

- Never commit `pk.*` or `sk.*` Mapbox tokens to git (`mapbox.json` must be in `.gitignore`; `SDK_REGISTRY_TOKEN` stays in `~/.gradle/gradle.properties`).
- Keep `lib/domain/rain_zone_geojson.dart` pure Dart with zero Flutter/Mapbox imports.
- Use `MapboxStyles.STANDARD` as the Mapbox style.
- Preserve all existing UX behaviors: Bandung overview (`zoom: 12`) → animated zoom to user GPS (`zoom: 16`), **My Location** recenter FAB, `400ms` / `500m` debounced pan refresh, GPS-locked **Report Rain**, `500m` GPS range restriction on **Stopped here** votes, `_latestReports` flicker guard, and `Offline mode (local only)` banner.
- All `flutter test` suites and `dart analyze` must pass cleanly.

## Review Focus

- **Token leak check:** `git status` and `git diff` must contain zero `pk.ey` or `sk.ey` strings; `mapbox.json` must be ignored by git (covered in Task 3).
- **GeoJSON circle accuracy & winding:** Polygon rings must be closed (first coordinate == last coordinate, 65 vertices for 64 segments) and each vertex must lie at `radiusMeters` from `(centerLat, centerLng)` (covered in Task 1).
- **Empty cluster list updates:** When active reports drop to `0` (e.g., after marking stopped), GeoJSON source must update to an empty `FeatureCollection` and `PointAnnotationManager.deleteAll()` must clear old pins cleanly (covered in Task 4).
- **Style load timing:** Adding GeoJSON sources/layers before Mapbox style finishes loading can fail; layers/annotations must be initialized in `onStyleLoadedListener` (or after `onMapCreated` + style load) and safely guarded against `mounted == false` (covered in Task 4).
- **Annotation tap mapping:** Tapping a `PointAnnotation` must map reliably back to its `RainCluster` (even after stream updates replace annotations) to open `PinDetailBottomSheet` vs `ClusterDetailBottomSheet` (covered in Task 4).

---

### Task 1: Pure-Dart GeoJSON rain zone circle builder

**Files:**
- Create: `lib/domain/rain_zone_geojson.dart`
- Test: `test/domain/rain_zone_geojson_test.dart`

**Interfaces:**
- Consumes: `RainCluster` (`lib/domain/rain_cluster.dart`), `RainIntensity` (`lib/domain/rain_intensity.dart`), `LocationPrivacy.distanceMeters` (`lib/domain/location_privacy.dart`).
- Produces:
  - `class RainZoneGeoJson`:
    - `static String buildFeatureCollection(List<RainCluster> clusters, {int segments = 64})`
    - `static String fillColorHex(RainIntensity intensity)`
    - `static String borderColorHex(RainIntensity intensity)`

- [ ] **Step 1: Write failing unit tests in `test/domain/rain_zone_geojson_test.dart`**

Cover:
- `returns empty FeatureCollection when clusters is empty`
- `builds closed 64-segment polygon at accurate radiusMeters from cluster center` (decode JSON, verify 1 feature, `geometry.type == 'Polygon'`, ring length == 65, first == last, every vertex distance from center within 1% of `300m`, and `properties.fillColor` matches `RainZoneGeoJson.fillColorHex`)
- `builds one feature per cluster with distinct intensity colors`

- [ ] **Step 2: Run unit tests to verify they fail**

Run: `flutter test test/domain/rain_zone_geojson_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: FAIL (missing `rain_zone_geojson.dart`).

- [ ] **Step 3: Implement `RainZoneGeoJson` in `lib/domain/rain_zone_geojson.dart`**

- Use spherical destination formula (same `_earthRadiusMeters = 6371000.0` as `LocationPrivacy`) to compute `[lng, lat]` pairs for `i = 0..segments` (closing the ring at `i == segments` with the exact first coordinate).
- Map `RainIntensity` to hex strings matching existing intensity palette (`light`: `#03A9F4`, `moderate`: `#1976D2`, `heavy`: `#673AB7`, `storm`: `#D32F2F`, `stopped`: `#4CAF50`).
- Encode with `dart:convert` `jsonEncode`.

- [ ] **Step 4: Run unit tests to verify they pass**

Run: `flutter test test/domain/rain_zone_geojson_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/rain_zone_geojson.dart test/domain/rain_zone_geojson_test.dart
git commit -m "feat(domain): add RainZoneGeoJson meter-accurate circle polygon builder"
```

---

### Task 2: `dart:ui` PNG marker icon renderer for Mapbox annotations

**Files:**
- Create: `lib/ui/mapbox_marker_icons.dart`
- Test: `test/ui/mapbox_marker_icons_test.dart`

**Interfaces:**
- Consumes: `RainIntensity` (`lib/domain/rain_intensity.dart`).
- Produces:
  - `class MapboxMarkerIcons`:
    - `Future<Uint8List> getPinIcon(RainIntensity intensity, Color color)`
    - `Future<Uint8List> getClusterBadgeIcon(RainIntensity intensity, Color color, int count)`

- [ ] **Step 1: Write failing tests in `test/ui/mapbox_marker_icons_test.dart`**

Cover:
- `renders valid PNG bytes for single pin and caches repeated calls` (verify bytes start with PNG magic `[137, 80, 78, 71]` and second call returns `identical` instance).
- `renders valid PNG bytes for cluster badge with count and caches by (intensity, count)`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/ui/mapbox_marker_icons_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: FAIL (missing `mapbox_marker_icons.dart`).

- [ ] **Step 3: Implement `MapboxMarkerIcons` in `lib/ui/mapbox_marker_icons.dart`**

- Use `ui.PictureRecorder` + `Canvas` at `2.0x` scale (`88x88` px):
  - `getPinIcon`: colored teardrop pin with white inner dot and subtle drop shadow.
  - `getClusterBadgeIcon`: colored circle with white border, subtle shadow, and centered bold white count text (`TextPainter`).
- Cache results in a `Map<String, Uint8List>`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/ui/mapbox_marker_icons_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/mapbox_marker_icons.dart test/ui/mapbox_marker_icons_test.dart
git commit -m "feat(ui): add MapboxMarkerIcons PNG renderer with caching"
```

---

### Task 3: Add `mapbox_maps_flutter`, configure Android Gradle Maven repo, and wire token config

**Files:**
- Modify: `pubspec.yaml`
- Modify: `android/build.gradle.kts`
- Modify: `.gitignore`
- Create: `mapbox.example.json` (committed), `mapbox.json` (gitignored, local only)
- Modify: `lib/main.dart`

**Interfaces:**
- Produces: `mapbox_maps_flutter` dependency installed, `MapboxOptions.setAccessToken` initialized in `main()` from `const String.fromEnvironment('MAPBOX_ACCESS_TOKEN')`.

- [ ] **Step 1: Update `pubspec.yaml` to replace `flutter_map` and `latlong2` with `mapbox_maps_flutter` and run `flutter pub get`**

Run: `flutter pub add mapbox_maps_flutter && flutter pub remove flutter_map latlong2` in `/home/carbon/projects/learn/rain-reporter`
Expected: `pubspec.yaml` and `pubspec.lock` resolve cleanly without version conflicts.

- [ ] **Step 2: Add Mapbox Maven repository to `android/build.gradle.kts`**

Add inside `allprojects { repositories { ... } }` in `android/build.gradle.kts`:
- URL: `https://api.mapbox.com/downloads/v2/releases/maven`
- Basic auth username `"mapbox"`, password resolved from Gradle property `SDK_REGISTRY_TOKEN`, falling back to `MAPBOX_DOWNLOADS_TOKEN`, then `System.getenv("SDK_REGISTRY_TOKEN")` / `System.getenv("MAPBOX_DOWNLOADS_TOKEN")` / `""`.

- [ ] **Step 3: Configure gitignored `mapbox.json`, committed `mapbox.example.json`, and `MapboxOptions.setAccessToken` in `lib/main.dart`**

- Append `mapbox.json` to `.gitignore`.
- Create `mapbox.example.json` with `{"MAPBOX_ACCESS_TOKEN": "pk.YOUR_MAPBOX_PUBLIC_TOKEN"}`.
- Create local `mapbox.json` (untracked/ignored) with the user's `pk.*` token.
- In `lib/main.dart`: read `const mapboxToken = String.fromEnvironment('MAPBOX_ACCESS_TOKEN');` and if `mapboxToken.isNotEmpty`, call `MapboxOptions.setAccessToken(mapboxToken);` before `runApp`.

- [ ] **Step 4: Verify `mapbox.json` is ignored by git and commit**

Run: `git status --short` (confirm `mapbox.json` does NOT appear!)
```bash
git add pubspec.yaml pubspec.lock android/build.gradle.kts .gitignore mapbox.example.json lib/main.dart
git commit -m "chore(mapbox): add mapbox_maps_flutter, Gradle Maven repo, and token config"
```

---

### Task 4: Migrate `MapScreen` to `mapbox_maps_flutter` + `MapTestController` and update widget tests

**Files:**
- Modify: `lib/ui/map_screen.dart`
- Modify: `lib/main.dart` (pass optional `mapTestController` if needed)
- Modify: `test/widget_test.dart`

**Interfaces:**
- Consumes: `RainZoneGeoJson` (Task 1), `MapboxMarkerIcons` (Task 2), `mapbox_maps_flutter` (Task 3).
- Produces:
  - `class MapTestController` exposing `centerLat`, `centerLng`, `zoom`, `clusters`, `hasUserLocation`, `simulateCameraMove(double lat, double lng, double zoom)` for headless `flutter test`.
  - `MapScreen` using native `MapWidget(styleUri: MapboxStyles.STANDARD)` when `useNativeMapView == true` and interactive test surface when `useNativeMapView == false`.

- [ ] **Step 1: Update `test/widget_test.dart` to target `MapTestController` / Mapbox-backed `MapScreen`**

Preserve all existing 17 widget test cases:
- Renders map surface, opens `ReportBottomSheet`, submits report, does not recreate stream on rebuild.
- Blocks `Report Rain` when GPS is unavailable or throws; submits at real GPS after panning elsewhere.
- Refreshes active reports after debounced pan >500m, skips <=500m, coalesces rapid pans, cancels timer on dispose.
- Duplicate `Report Rain` tap guard.
- Single report shows 300m zone and opens `PinDetailBottomSheet`; nearby reports merge into larger zone + cluster badge `'2'` opening `ClusterDetailBottomSheet` with working vote; distant reports stay separate.
- Preserves previous reports without flickering to 0 while refreshed stream is waiting.
- Zooms to 16 at user location, shows user location indicator, recenters on tap.
- Shows `Offline mode (local only)` banner when `isOfflineMode: true`.
- `Stopped here` blocks when GPS unavailable or >500m away, allows within 500m.

- [ ] **Step 2: Implement native `MapWidget` + `MapTestController` in `lib/ui/map_screen.dart`**

- Remove `flutter_map` and `latlong2` imports; import `package:mapbox_maps_flutter/mapbox_maps_flutter.dart`, `../domain/rain_zone_geojson.dart`, and `mapbox_marker_icons.dart`.
- Native Mapbox lifecycle (`useNativeMapView == true`):
  - `MapWidget` with `styleUri: MapboxStyles.STANDARD`, initial `CameraOptions(center: Point(coordinates: Position(_cameraCenter.lng, _cameraCenter.lat)), zoom: _defaultOverviewZoom)`.
  - `onMapCreated`: save `MapboxMap`, enable `location.updateSettings(LocationComponentSettings(enabled: true, pulsingEnabled: true))`, create `PointAnnotationManager` and register `tapEvents` listener mapping annotation ID → `RainCluster` (opening `_openPinDetails` or `_openClusterDetails`).
  - `onStyleLoadedListener`: add `GeoJsonSource(id: 'rain-zones-source', data: RainZoneGeoJson.buildFeatureCollection(...))`, `FillLayer(id: 'rain-zones-fill', sourceId: 'rain-zones-source', ...)` using data-driven `['get', 'fillColor']` and `fillOpacity: 0.28`, and `LineLayer(id: 'rain-zones-line', sourceId: 'rain-zones-source', ...)` using `['get', 'borderColor']`, `lineOpacity: 0.75`, `lineWidth: 2.0`. Then sync current clusters.
  - `onCameraChangeListener`: read `cameraState.center.coordinates` (`lat`, `lng`) and feed into `_onMapPositionChanged`.
  - `_animateMapTo(lat, lng, zoom)`: call `_mapboxMap?.easeTo(CameraOptions(center: Point(coordinates: Position(lng, lat)), zoom: zoom), MapAnimationOptions(duration: 550))`.
  - `_syncMapboxLayers(List<RainCluster> clusters)`: update GeoJSON source via `style.setStyleSourceProperty('rain-zones-source', 'data', geoJson)` and rebuild `PointAnnotationManager` annotations (guarded by generation counter so rapid stream updates don't race).
- Test mode (`useNativeMapView == false`): render lightweight Stack with clickable single-pin (`Icons.location_on`) and cluster badge (`'${cluster.reports.length}'`) widgets and `user_location_marker`, syncing state to `MapTestController`.

- [ ] **Step 3: Run full test suite and static analysis**

Run: `flutter test && dart analyze` in `/home/carbon/projects/learn/rain-reporter`
Expected: All tests pass and `dart analyze` reports zero issues.

- [ ] **Step 4: Build release APK with `mapbox.json` to verify Android Gradle + Mapbox SDK**

Run: `flutter build apk --release --dart-define-from-file=mapbox.json` in `/home/carbon/projects/learn/rain-reporter`
Expected: `✓ Built build/app/outputs/flutter-apk/app-release.apk`.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/map_screen.dart lib/main.dart test/widget_test.dart
git commit -m "feat(map): migrate MapScreen from flutter_map to native mapbox_maps_flutter"
```
