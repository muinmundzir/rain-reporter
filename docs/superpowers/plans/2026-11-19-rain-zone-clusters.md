# Rain Zone Radius & Clustering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render meter-accurate translucent rain zones around active pins and merge nearby overlapping pins into combined larger zones with tappable cluster badges and a cluster detail bottom sheet.

**Architecture:** Add pure-Dart union-find spatial clustering in `lib/domain/rain_cluster.dart`, add a scrollable `ClusterDetailBottomSheet` widget in `lib/ui/cluster_detail_bottom_sheet.dart`, and wire `CircleLayer` (`useRadiusInMeter: true`) + single/cluster markers in `lib/ui/map_screen.dart`.

**Tech Stack:** Flutter, Dart, `flutter_map`, `latlong2`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-11-19-rain-zone-clusters-design.md`

## Global Constraints

- Keep `lib/domain/rain_cluster.dart` pure Dart with zero Flutter/UI imports.
- Do not add any third-party packages; use `flutter_map`'s built-in `CircleLayer` (`useRadiusInMeter: true`).
- Do not mutate `RainReport` data model or Firestore schema.
- Default `baseRadiusMeters = 300` (merge distance `baseRadiusMeters * 2 = 600m`).
- Keep `MapScreen` test injection hooks (`locationProvider`, `useNativeMapView`, `clock`, `panDebounceDuration`, `panRefreshThresholdMeters`) backwards-compatible.

## Review Focus

- **Co-located pins (0 m apart):** Two reports at identical coordinates must still grow the combined radius (`300 * sqrt(2) ≈ 424.26m`) rather than staying at `300m` (covered in Task 1).
- **Transitive cluster chain:** A is 500 m from B and B is 500 m from C (A–C = 1000 m > 600 m) -> union-find merges all three into one cluster whose radius covers the farthest pin + 300 m (covered in Task 1).
- **Large cluster sheet overflow:** A cluster with 10+ reports inside `ClusterDetailBottomSheet` must scroll cleanly without `RenderFlex` overflow (covered in Task 2).
- **Voting inside a cluster sheet:** Tapping `Still raining` or `Stopped here` on one report in `ClusterDetailBottomSheet` votes on that specific `report.id` and handles `DuplicateVoteException` via SnackBar just like single-pin voting (covered in Task 2 & Task 3).
- **CircleLayer does not swallow marker taps:** `CircleLayer` must be placed before `MarkerLayer` in `FlutterMap.children` so tapping a pin or cluster badge always triggers its detail sheet (covered in Task 3).

---

### Task 1: Pure-Dart `RainCluster` and `RainClusterer` domain logic

**Files:**
- Create: `lib/domain/rain_cluster.dart`
- Test: `test/domain/rain_cluster_test.dart`

**Interfaces:**
- Consumes: `RainReport` (`lib/domain/rain_report.dart`), `RainIntensity` (`lib/domain/rain_intensity.dart`), `LocationPrivacy.distanceMeters` (`lib/domain/location_privacy.dart:43-58`).
- Produces:
  - `class RainCluster`: `final double centerLat`, `final double centerLng`, `final double radiusMeters`, `final RainIntensity strongestIntensity`, `final List<RainReport> reports` (unmodifiable, sorted newest `createdAt` first), `bool get isCluster => reports.length > 1`.
  - `class RainClusterer`: `static List<RainCluster> cluster(List<RainReport> reports, {double baseRadiusMeters = 300})`.

- [ ] **Step 1: Write failing unit tests in `test/domain/rain_cluster_test.dart`**

Cover:
- `returns empty list when reports is empty`
- `creates single-pin cluster with baseRadiusMeters (300m) for one report`
- `merges two reports within 600m into one cluster with combined radius, strongest intensity, and newest-first order`
- `grows radius for co-located reports (0m apart) using baseRadiusMeters * sqrt(N)`
- `merges transitive chain (A-B <= 600m, B-C <= 600m, A-C > 600m) into one cluster covering all pins`
- `keeps reports more than 600m apart in separate clusters`

- [ ] **Step 2: Run unit tests to verify they fail**

Run: `flutter test test/domain/rain_cluster_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: FAIL (missing `package:rain_reporter/domain/rain_cluster.dart`).

- [ ] **Step 3: Implement `RainCluster` and `RainClusterer` in `lib/domain/rain_cluster.dart`**

- Define severity rank (`light: 1, moderate: 2, heavy: 3, storm: 4, stopped: 0`).
- Use union-find over report indices: union `(i, j)` whenever `LocationPrivacy.distanceMeters(reports[i].lat, reports[i].lng, reports[j].lat, reports[j].lng) <= baseRadiusMeters * 2`.
- Group indices by root; for each group:
  - Sort reports by `b.createdAt.compareTo(a.createdAt)` (newest first).
  - Compute mean `centerLat`, `centerLng`.
  - For 1 report, `radiusMeters = baseRadiusMeters`. For `N > 1`, `radiusMeters = max(maxDistFromCenter + baseRadiusMeters, baseRadiusMeters * sqrt(N))`.
  - Pick `strongestIntensity` by highest severity rank.

- [ ] **Step 4: Run unit tests to verify they pass**

Run: `flutter test test/domain/rain_cluster_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: PASS (all 6 tests green).

- [ ] **Step 5: Commit**

```bash
git add lib/domain/rain_cluster.dart test/domain/rain_cluster_test.dart
git commit -m "feat(domain): add RainCluster and RainClusterer spatial clustering"
```

---

### Task 2: `ClusterDetailBottomSheet` widget

**Files:**
- Create: `lib/ui/cluster_detail_bottom_sheet.dart`
- Modify: `test/ui/sheets_test.dart`

**Interfaces:**
- Consumes: `RainCluster` (`lib/domain/rain_cluster.dart`), `RainReport` (`lib/domain/rain_report.dart`).
- Produces:
  - `ClusterDetailBottomSheet({super.key, required RainCluster cluster, required DateTime now, required ValueChanged<RainReport> onConfirmStillRaining, required ValueChanged<RainReport> onMarkStopped})`

- [ ] **Step 1: Write failing widget tests in `test/ui/sheets_test.dart`**

Add tests:
- `ClusterDetailBottomSheet displays strongest intensity, report count, zone radius, notes, and fires vote callbacks for specific report`: build a 2-report `RainCluster` (`heavy` and `storm` with distinct notes), assert `'Storm Rain'`, `'2 reports'`, `'~424m zone'` (or rounded radius), both notes, tap `'Still raining'` on the first report and `'Stopped here'` on the second, assert callbacks receive the exact `RainReport` instances.
- `ClusterDetailBottomSheet scrolls cleanly with 12 reports without overflow`: mount inside a `SizedBox(height: 500)` / bottom sheet with 12 reports, assert `tester.takeException()` is `null`.

- [ ] **Step 2: Run widget tests to verify they fail**

Run: `flutter test test/ui/sheets_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: FAIL (missing `cluster_detail_bottom_sheet.dart`).

- [ ] **Step 3: Implement `ClusterDetailBottomSheet` in `lib/ui/cluster_detail_bottom_sheet.dart`**

- Constrain sheet height (e.g., `SafeArea` + `ConstrainedBox(constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.65))`).
- Header row: `'${cluster.strongestIntensity.label} Rain'` (`titleLarge`), `Chip(label: Text('${cluster.reports.length} reports'))`, subtitle `'~${cluster.radiusMeters.round()}m zone'`.
- `Flexible` `ListView.separated` rendering one card/tile per `RainReport` in `cluster.reports`: intensity label, `'${minutesAgo}m ago'`, optional `report.note`, `'Confirmed by ${report.confirmCount} user(s)'`, and `'Still raining'` + `'Stopped here'` buttons invoking `onConfirmStillRaining(report)` and `onMarkStopped(report)`.

- [ ] **Step 4: Run widget tests to verify they pass**

Run: `flutter test test/ui/sheets_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/cluster_detail_bottom_sheet.dart test/ui/sheets_test.dart
git commit -m "feat(ui): add ClusterDetailBottomSheet for merged rain zones"
```

---

### Task 3: Render `CircleLayer`, cluster badges, and wire `ClusterDetailBottomSheet` in `MapScreen`

**Files:**
- Modify: `lib/ui/map_screen.dart`
- Modify: `test/widget_test.dart`

**Interfaces:**
- Consumes: `RainCluster` & `RainClusterer.cluster` (Task 1), `ClusterDetailBottomSheet` (Task 2).
- Produces: `MapScreen` renders `CircleLayer` (`useRadiusInMeter: true`) + single pin / cluster badge markers in `MarkerLayer`, opening `PinDetailBottomSheet` for single pins and `ClusterDetailBottomSheet` for clusters.

- [ ] **Step 1: Write failing widget tests in `test/widget_test.dart`**

Add tests:
- `renders CircleLayer with 300m radius for a single active report and opens PinDetailBottomSheet on tap`: seed 1 report in repo, mount `MapScreen`, verify `CircleLayer` has 1 `CircleMarker` with `useRadiusInMeter == true` and `radius == 300`, tap `Icons.location_on`, verify `PinDetailBottomSheet` appears.
- `merges nearby reports into one larger CircleMarker and cluster badge that opens ClusterDetailBottomSheet`: seed 2 reports ~100 m apart in repo (using two distinct `uid`s so rate-limit doesn't trigger), mount `MapScreen`, verify `CircleLayer` has 1 `CircleMarker` with `radius > 300`, verify `Icons.location_on` finds nothing, verify `find.text('2')` finds one widget, tap `find.text('2')`, verify `ClusterDetailBottomSheet` opens with `'2 reports'`, tap `'Still raining'` on the first report and verify `confirmCount` increments.
- `keeps distant reports (>600m apart) as separate CircleMarkers and individual pins`: seed 2 reports ~2 km apart, verify `CircleLayer` has 2 `CircleMarker`s and `Icons.location_on` finds 2 widgets.

- [ ] **Step 2: Run widget tests to verify they fail**

Run: `flutter test test/widget_test.dart` in `/home/carbon/projects/learn/rain-reporter`
Expected: FAIL (`CircleLayer` not found or cluster badge `'2'` not found).

- [ ] **Step 3: Wire `RainClusterer`, `CircleLayer`, cluster badges, and `ClusterDetailBottomSheet` in `lib/ui/map_screen.dart`**

- Import `../domain/rain_cluster.dart` and `cluster_detail_bottom_sheet.dart`.
- Compute `final clusters = RainClusterer.cluster(reports);` inside `StreamBuilder`.
- Build `circles`: one `CircleMarker` per `RainCluster` with `point: LatLng(cluster.centerLat, cluster.centerLng)`, `radius: cluster.radiusMeters`, `useRadiusInMeter: true`, `color: color.withValues(alpha: 0.22)`, `borderColor: color.withValues(alpha: 0.6)`, `borderStrokeWidth: 1.5`.
- Build `markers`: for each `RainCluster`:
  - If `!cluster.isCluster`: existing `Icons.location_on` marker tapping `_openPinDetails(cluster.reports.first)`.
  - If `cluster.isCluster`: `44x44` circular badge (`BoxDecoration(shape: BoxShape.circle, color: color, border: Border.all(color: Colors.white, width: 2))`) with centered white bold `'${cluster.reports.length}'`, tapping `_openClusterDetails(cluster)`.
- Add `CircleLayer(circles: circles)` immediately before `MarkerLayer(markers: markers)` in `FlutterMap.children`.
- Add `_openClusterDetails(RainCluster cluster)` opening `showModalBottomSheet` with `isScrollControlled: true` and `ClusterDetailBottomSheet` wired to `_handleVote`.

- [ ] **Step 4: Run full test suite and static analysis**

Run: `flutter test && dart analyze` in `/home/carbon/projects/learn/rain-reporter`
Expected: All tests pass and `dart analyze` reports zero issues.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/map_screen.dart test/widget_test.dart
git commit -m "feat(map): render rain zone circles and merged cluster markers"
```
