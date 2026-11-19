# Rain Zone Radius & Clustering — Short Design Spec

**Date:** 2026-11-19  
**Scope:** Small feature in `rain-reporter`

---

## 1. Intent & Why

A single rain pin only marks one fuzzed point on the map and does not convey the coverage area of rain or how many nearby users are reporting it. Showing a translucent radius around each rain pin—and merging nearby overlapping pins into a single larger rain zone with a cluster marker—makes active rain coverage immediately readable at a glance while keeping dense areas uncluttered.

---

## 2. Goals, Non-Goals, and Anti-Goals

- **Goals:**
  - Render a meter-accurate translucent radius around every active rain pin using `flutter_map`'s `CircleLayer` (`useRadiusInMeter: true`).
  - Automatically merge nearby active pins whose radii overlap into one combined `RainCluster` with a larger radius and a single cluster marker showing the report count.
  - Color each zone and marker by the strongest rain intensity in the cluster (`storm > heavy > moderate > light`).
  - Tapping a single-pin marker opens the existing `PinDetailBottomSheet`; tapping a multi-pin cluster marker opens a `ClusterDetailBottomSheet` summarizing the zone and letting users read notes and vote (`Still raining` / `Stopped here`) on each report.
- **Non-Goals:**
  - Freeform polygon/concave-hull rain shapes (`PolygonLayer`) or custom shader heatmaps.
  - Zoom-dependent screen-pixel clustering (clustering is meter-based so overlapping rain zones stay grouped regardless of zoom).
  - Server-side clustering in Firestore.
- **Anti-Goals:**
  - Never lose the ability to read notes or vote on individual reports when pins are merged into a cluster.
  - Never mutate the underlying `RainReport` data model or Firestore schema.

---

## 3. Constraints

- Pure Dart clustering logic in `lib/domain/` with zero Flutter/UI imports so it can be unit-tested directly.
- Use existing `flutter_map` `CircleLayer` (`useRadiusInMeter: true`) — no new third-party packages.
- Keep existing `MapScreen` test hooks (`locationProvider`, `useNativeMapView`, `clock`, `panDebounceDuration`, `panRefreshThresholdMeters`) backwards-compatible.

---

## 4. Approaches Considered

1. **Clustered Rain Zones via `CircleLayer` (Picked):** Group reports with overlapping base radii using union-find/single-linkage in pure Dart; render one `CircleMarker` (`useRadiusInMeter: true`) and one marker (single pin or cluster badge) per cluster.
   - *Tradeoff:* Always circular even if pins line up along one road, in exchange for zero extra dependencies, fast meter-accurate zoom scaling, and clean unit-testable domain logic.
2. **Organic Rain Blob via `PolygonLayer`:** Compute a buffered/smoothed hull around clustered pins.
   - *Tradeoff:* Better fit for elongated rain bands, but noticeably more geometry complexity and awkward 2-pin shapes.
3. **Overlapping Translucent Glow / Heatmap:** Draw per-pin radial circles that visually stack without merging.
   - *Tradeoff:* Simpler to draw, but overlapping opacities stack unevenly and radii do not clearly expand as a combined zone.

**Why Option 1:** `flutter_map`'s built-in `CircleLayer` handles meter-accurate scaling cleanly and keeps clustering math simple, deterministic, and easy to test.

---

## 5. Decided Behavior

- **Domain (`lib/domain/rain_cluster.dart`):**
  - `RainCluster` value object: `centerLat`, `centerLng`, `radiusMeters`, `strongestIntensity`, `reports` (sorted newest first).
  - `RainClusterer.cluster(List<RainReport> reports, {double baseRadiusMeters = 300})`:
    - Uses single-linkage (union-find): two reports merge if `LocationPrivacy.distanceMeters(a, b) <= baseRadiusMeters * 2`.
    - Center is the arithmetic mean of `lat` and `lng` of reports in the cluster.
    - Combined radius: for 1 report, `baseRadiusMeters` (`300m`). For `N > 1` reports, `max(maxDistanceFromCenter + baseRadiusMeters, baseRadiusMeters * sqrt(N))`, so both spread-out pins and co-located pins visibly enlarge the rain zone.
    - `strongestIntensity`: highest severity in `reports` (`storm > heavy > moderate > light`).
- **Map UI (`lib/ui/map_screen.dart`):**
  - Compute `clusters = RainClusterer.cluster(reports)` from the active reports stream.
  - Add `CircleLayer` beneath `MarkerLayer` with one `CircleMarker(useRadiusInMeter: true)` per cluster (translucent fill + border tinted by `strongestIntensity`).
  - In `MarkerLayer`:
    - `cluster.reports.length == 1`: render existing `Icons.location_on` pin; tap opens `PinDetailBottomSheet`.
    - `cluster.reports.length > 1`: render circular cluster badge showing `cluster.reports.length` tinted by `strongestIntensity`; tap opens `ClusterDetailBottomSheet`.
- **Cluster Sheet (`lib/ui/cluster_detail_bottom_sheet.dart`):**
  - Shows strongest intensity title, report count chip, approximate zone radius (`~XXXm zone`), and a scrollable list of the cluster's reports (newest first) with intensity, relative time (`Xm ago`), optional note, confirm count, and `Still raining` / `Stopped here` vote buttons.

---

## 6. Left to the Builder (Defaults)

- Base radius default: `300m` (merge distance `600m`).
- Circle styling: fill alpha `0.22`, border alpha `0.6`, border stroke `1.5`.
- Cluster badge visual sizing (e.g., `44x44` circular badge with white border and bold count label).
- Maximum sheet height constraint (e.g., `ConstrainedBox` / `Flexible` `ListView`) so clusters with many reports scroll cleanly.
