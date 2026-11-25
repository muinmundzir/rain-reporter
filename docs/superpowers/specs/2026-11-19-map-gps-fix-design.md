# Map vs. GPS Fix — Short Design Spec

**Date:** 2026-11-19  
**Scope:** Small change (bugfix in `rain-reporter`)

---

## 1. Intent & Why

[`MapScreen`](../../../lib/ui/map_screen.dart) currently uses a single `_center` field for both the map camera viewport and the user's GPS coordinates. As a result, panning the map silently changes where new rain reports get submitted, panning never reloads nearby pins for the new area, and denied GPS silently falls back to submitting reports in Jakarta (`-6.2, 106.816666`).

---

## 2. Goals, Non-Goals, and Anti-Goals

- **Goals:**
  - Separate map camera state (`_cameraCenter`) from real device GPS (`_userLocation`).
  - Lock **Report Rain** submissions to the user's real GPS location (with existing ~100–200 m privacy fuzzing via `LocationPrivacy.fuzzCoordinate`).
  - Block **Report Rain** and show a clear prompt/message when GPS is unavailable or permission is denied.
  - Automatically reload active rain pins around `_cameraCenter` when the user pans to a new area.
- **Non-Goals:**
  - True Firestore geohash range queries (tracked separately).
  - Map UI additions like user-location blue dot, recenter FAB, or clustering.
  - Changing the `LocationPrivacy.fuzzCoordinate` 100–200 m privacy range.
- **Anti-Goals:**
  - Never silently submit a report at the hardcoded fallback city or a panned map center.
  - Never hammer `watchActiveReports` on every frame of a pan gesture.

---

## 3. Constraints

- Keep `RainReporterApp` and `MapScreen` test injection hooks (`locationProvider`, `useNativeMapView`, `clock`) backwards-compatible.
- Dispose any debounce timer cleanly in `State.dispose()`.

---

## 4. Approaches Considered

1. **Debounced auto-refresh on pan (Picked):** Split `_center` into `_cameraCenter` and nullable `_userLocation`. When `onPositionChanged` moves `_cameraCenter`, debounce ~400 ms and re-subscribe `_reportsStream` only if the camera moved >500 m from the last queried center.
   - *Tradeoff:* Slightly more stream restarts if a user pans repeatedly, mitigated by debounce + 500 m threshold, in exchange for seamless commute-browsing UX.
2. **"Search this area" button on pan:** Show a floating pill when moved >500 m; refresh `_reportsStream` only on tap.
   - *Tradeoff:* Zero extra reads during pan, but requires an extra tap every time the user inspects a new neighborhood.

**Why Option 1:** Checking rain along a commute feels natural when pins follow the map automatically, and the debounce + 500 m threshold keeps Firestore reads cheap.

---

## 5. Decided Behavior

- **State split:**
  - `_cameraCenter`: starts at `_defaultCenter` (`-6.2, 106.816666`), updated on initial GPS fix and on map pan.
  - `_lastQueriedCenter`: coordinates used for the current `_reportsStream` subscription.
  - `_userLocation`: nullable `({double lat, double lng})?`, populated only from real GPS (`locationProvider` / `Geolocator`).
- **Reporting flow (`_openReportSheet`):**
  - Before submitting, resolve fresh real GPS (re-checking permission/service if `_userLocation` is null or stale).
  - If GPS is unavailable or permission is denied, do not submit; show a `SnackBar` prompting the user to enable location access.
  - When GPS is available, submit using those real coordinates (repository fuzzes ~100–200 m as before).
- **Panning flow (`onPositionChanged`):**
  - Update `_cameraCenter` immediately.
  - Schedule a ~400 ms debounce timer; when it fires, if `LocationPrivacy.distanceMeters(_lastQueriedCenter, _cameraCenter) > 500`, update `_lastQueriedCenter` and refresh `_reportsStream`.

---

## 6. Left to the Builder (Defaults)

- Exact debounce duration (default: `400ms`, injectable/configurable for deterministic widget tests).
- Whether GPS refresh on submit uses `_userLocation` directly when recent vs. re-calling `_resolveDeviceLocation()` (default: always resolve fresh location on submit so moving users get accurate coordinates, falling back to last known `_userLocation` only if needed—or blocking if null).
- Exact copy of the location-required `SnackBar` message.
