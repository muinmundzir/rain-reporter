# Map vs. GPS Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate map camera state from device GPS in `MapScreen` so rain reports always lock to real GPS (blocking if unavailable) and panning automatically reloads nearby pins after a debounced 500 m move.

**Architecture:** Split `MapScreen`'s overloaded `_center` field into `_cameraCenter` (viewport), `_lastQueriedCenter` (active stream query), and nullable `_userLocation` (real GPS). Make `locationProvider` return a nullable coordinate record so denied/failed GPS never silently falls back to Jakarta, and wire a cancellable 400 ms debounce timer on `FlutterMap.options.onPositionChanged` with a 500 m distance threshold.

**Tech Stack:** Flutter, Dart, `flutter_map`, `geolocator`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-11-19-map-gps-fix-design.md`

## Global Constraints

- Keep `RainReporterApp` and `MapScreen` test injection hooks (`locationProvider`, `useNativeMapView`, `clock`) backwards-compatible.
- Never silently submit a report at the hardcoded fallback city (`-6.2, 106.816666`) or a panned map center.
- Keep existing `LocationPrivacy.fuzzCoordinate` 100–200 m privacy fuzzing unchanged.
- Dispose any debounce timer cleanly in `State.dispose()`.
- Default pan debounce duration: `400ms`; default distance threshold: `500m`.

## Review Focus

- **Denied/unavailable GPS on report:** `locationProvider` returns `null` -> browsing still works at default center, tapping `Report Rain` shows SnackBar and submits zero reports (covered in Task 1).
- **GPS lookup throws an exception:** `locationProvider` throws -> handled cleanly like `null`, shows SnackBar, no uncaught error (covered in Task 1).
- **Report after panning away:** user pans >1 km away and taps `Report Rain` -> submitted coordinates match real GPS (within fuzz radius), not panned camera center (covered in Task 1).
- **Sub-threshold pan / rapid pan jitter:** panning <=500 m does not restart `_reportsStream`; multiple rapid pans within 400 ms coalesce into one stream refresh (covered in Task 2).
- **Widget disposed mid-debounce:** `MapScreen` unmounted while debounce timer is active -> timer cancelled in `dispose()`, no pending-timer test failure or `setState` after dispose (covered in Task 2).

---

### Task 1: Lock Report Rain to real GPS and block when unavailable

**Files:**
- Modify: `lib/main.dart:32-62`
- Modify: `lib/ui/map_screen.dart:13-136,214-234`
- Test: `test/widget_test.dart`

**Interfaces:**
- Consumes: `LocationPrivacy.distanceMeters` (`lib/domain/location_privacy.dart:43-58`), `RainReportRepository.submitReport` (`lib/data/rain_report_repository.dart:35-41`).
- Produces:
  - `RainReporterApp.locationProvider` with type `Future<({double lat, double lng})?> Function()?`
  - `MapScreen.locationProvider` with type `Future<({double lat, double lng})?> Function()?`
  - `_MapScreenState._cameraCenter` (`({double lat, double lng})`) and `_MapScreenState._userLocation` (`({double lat, double lng})?`)

- [ ] **Step 1: Write failing widget tests for GPS-locked reporting, denied GPS, and throwing GPS**

Add to `test/widget_test.dart`:
- Extend `_CountingRepository` to record `lastSubmittedLat` and `lastSubmittedLng` in `submitReport`.
- `testWidgets('blocks Report Rain with SnackBar when GPS is unavailable')`: mount `RainReporterApp` with `locationProvider: () async => null`, tap `'Report Rain'`, assert `find.text('Location access is required to report rain.')` finds one widget, `find.text('Submit Report')` finds nothing, and `repo.lastSubmittedLat` is `null`.
- `testWidgets('blocks Report Rain gracefully when GPS provider throws')`: mount with `locationProvider: () async => throw Exception('gps off')`, tap `'Report Rain'`, assert SnackBar text appears and `repo.lastSubmittedLat` is `null`.
- `testWidgets('submits report at real GPS even after panning map elsewhere')`: mount with `locationProvider: () async => (lat: -6.2000, lng: 106.8166)`, pan/move the `FlutterMap`'s `MapController` (or drag map) to `(-6.3000, 106.9000)`, tap `'Report Rain'`, select `'Heavy'`, tap `'Submit Report'`, assert `repo.lastSubmittedLat` is `-6.2000` and `repo.lastSubmittedLng` is `106.8166`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/widget_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: FAIL (compile error on nullable `locationProvider` or assertion failure because report uses panned/fallback center).

- [ ] **Step 3: Separate `_cameraCenter` from `_userLocation` and enforce real GPS on report**

- In `lib/main.dart` and `lib/ui/map_screen.dart`, widen `locationProvider` type to `Future<({double lat, double lng})?> Function()?`.
- In `lib/ui/map_screen.dart`:
  - Replace `_center` with `({double lat, double lng}) _cameraCenter = _defaultCenter;` and `({double lat, double lng})? _userLocation;`.
  - Change `_resolveDeviceLocation()` to return `Future<({double lat, double lng})?>` and return `null` (instead of `_defaultCenter`) when location service is disabled or permission is `denied`/`deniedForever`.
  - Add helper `Future<({double lat, double lng})?> _fetchDeviceLocation()` that awaits `(widget.locationProvider ?? _resolveDeviceLocation)()` inside `try/catch`, returning `null` on error.
  - In `_initLocation()`, call `_fetchDeviceLocation()`; only update `_userLocation`, `_cameraCenter`, `_reportsStream`, and `_mapController.move(...)` when non-null.
  - In `_openReportSheet()`, call `_fetchDeviceLocation()` first. If `null` (and `mounted`), show `SnackBar(content: Text('Location access is required to report rain.'))` and return without opening `ReportBottomSheet`. Otherwise store `_userLocation = loc`, open `ReportBottomSheet`, and pass `rawLat: loc.lat, rawLng: loc.lng` to `widget.repository.submitReport(...)`.
  - In `FlutterMap.options.onPositionChanged`, update `_cameraCenter` only (do not touch `_userLocation`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/widget_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: PASS (all existing and new tests green).

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart lib/ui/map_screen.dart test/widget_test.dart
git commit -m "fix(map): lock rain reports to real GPS and block when unavailable"
```

---

### Task 2: Debounced auto-refresh of nearby pins on map pan

**Files:**
- Modify: `lib/ui/map_screen.dart:13-75,210-245`
- Test: `test/widget_test.dart`

**Interfaces:**
- Consumes: `_MapScreenState._cameraCenter` from Task 1, `LocationPrivacy.distanceMeters` (`lib/domain/location_privacy.dart:43-58`).
- Produces:
  - `MapScreen({..., Duration panDebounceDuration = const Duration(milliseconds: 400), double panRefreshThresholdMeters = 500})`

- [ ] **Step 1: Write failing widget tests for pan refresh, threshold, coalescing, and dispose**

Add to `test/widget_test.dart`:
- Extend `_CountingRepository` to record `lastWatchedLat` and `lastWatchedLng` in `watchActiveReports`.
- `testWidgets('refreshes active reports stream after debounced pan beyond 500m')`: mount `MapScreen` (with `panDebounceDuration: const Duration(milliseconds: 200)`), move `FlutterMap` camera >1 km away (e.g. from `(-6.2000, 106.8166)` to `(-6.2200, 106.8166)`), assert `repo.watchCalls` has not incremented before debounce elapses (`tester.pump(const Duration(milliseconds: 100))`), then `tester.pump(const Duration(milliseconds: 150))`, assert `repo.watchCalls == initialWatchCalls + 1` and `repo.lastWatchedLat` is close to `-6.2200`.
- `testWidgets('does not refresh stream when pan distance is within 500m')`: move camera ~100 m (`(-6.2005, 106.8166)`), pump past debounce, assert `repo.watchCalls == initialWatchCalls`.
- `testWidgets('coalesces rapid pans within debounce window into a single refresh')`: trigger two camera moves >1 km apart separated by `100ms`, then pump past debounce, assert `repo.watchCalls == initialWatchCalls + 1` and `repo.lastWatchedLat` reflects the final position.
- `testWidgets('cancels pending pan debounce timer on dispose')`: trigger camera move >1 km, immediately replace widget tree with `const SizedBox.shrink()`, pump past debounce, verify no error or pending timer failure.

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/widget_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: FAIL (missing `panDebounceDuration` parameter or `watchCalls` not incremented on pan).

- [ ] **Step 3: Implement debounced pan refresh and timer cleanup in `lib/ui/map_screen.dart`**

- Add `dart:async` import and `../domain/location_privacy.dart` import.
- Add constructor parameters to `MapScreen`:
  - `this.panDebounceDuration = const Duration(milliseconds: 400)`
  - `this.panRefreshThresholdMeters = 500`
- Track `({double lat, double lng}) _lastQueriedCenter = _defaultCenter;` and `Timer? _panDebounceTimer;`.
- Update `_updateCenter` (or replace with `_refreshReportsForCenter(({double lat, double lng}) center)`) so `_lastQueriedCenter` stays in sync whenever `_reportsStream` is created.
- In `onPositionChanged`: update `_cameraCenter`, cancel `_panDebounceTimer`, and start a new `Timer(widget.panDebounceDuration, () { ... })` that checks `mounted` and `LocationPrivacy.distanceMeters(_lastQueriedCenter.lat, _lastQueriedCenter.lng, _cameraCenter.lat, _cameraCenter.lng) > widget.panRefreshThresholdMeters` before calling `setState` to update `_lastQueriedCenter` and `_reportsStream`.
- Override `dispose()` to call `_panDebounceTimer?.cancel()` and `super.dispose()`.

- [ ] **Step 4: Run full test suite and static analysis**

Run: `flutter test && dart analyze` in `/home/carbon/projects/learn/rain-reporter`
Expected: All tests pass and `dart analyze` reports zero issues.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/map_screen.dart test/widget_test.dart
git commit -m "feat(map): debounce and refresh nearby rain reports on map pan"
```
