# Rain Reporter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an Android Flutter app (`rain-reporter`) where users view live nearby rain pins on Google Maps and submit fuzzed-location rain intensity reports that auto-expire after 30 minutes.

**Architecture:** Clean 3-layer Flutter app (`domain`, `data`, `ui`). Domain holds immutable `RainReport` models, 100–200m coordinate fuzzing, geohash prefix helpers, and 30-minute/stopped filtering rules. Data defines `RainReportRepository` and `AuthService` interfaces backed by Firebase (`cloud_firestore`, `firebase_auth`) with an in-memory implementation for widget/unit tests and local unconfigured preview. UI provides `MapScreen` (`google_maps_flutter`), `ReportBottomSheet`, and `PinDetailBottomSheet`.

**Tech Stack:** Flutter (Dart 3, Android target), `google_maps_flutter`, `geolocator`, `firebase_core`, `firebase_auth`, `cloud_firestore`, `flutter_test`.

**Spec:** `/home/carbon/projects/learn/rain-reporter/docs/superpowers/specs/2026-11-13-rain-reporter-design.md`

## Global Constraints

- Target platform: Android only for MVP, built with Flutter (`google_maps_flutter`).
- Intensity values: `'light' | 'moderate' | 'heavy' | 'storm' | 'stopped'`.
- Optional note max length: 140 characters (`note.size() <= 140`).
- Coordinate privacy: fuzz submitted GPS coordinates by a random offset between 100m and 200m before storing or transmitting.
- Report TTL: `expiresAt = createdAt + 30 minutes`; client queries and Firestore Security Rules must actively filter on `expiresAt > request.time`.
- All `firestore.rules` authoring/modification MUST be delegated to the `firestore-rules-author` subagent.

## Review Focus

1. **Boundary expiration (`expiresAt <= now`):** A report whose `expiresAt` equals or is earlier than `now` must never be returned as active even before Firestore's asynchronous TTL deletion runs.
2. **Nearby `stopped` report superseding active rain:** Submitting a `'stopped'` report or marking a pin stopped must hide/supersede older active rain reports within 300m created before the `'stopped'` report.
3. **Note over-length or whitespace-only input:** Notes longer than 140 characters must be rejected/clamped, and whitespace-only notes must normalize to `null`.
4. **Coordinate fuzzing bounds (100m–200m):** Fuzzing must always displace the raw coordinate by at least 100m and at most 200m (never 0m, which leaks exact home address, and never >200m).
5. **Duplicate votes and rate-limit cooldown per `uid`:** The same `uid` tapping "Still raining" twice on a report must not increment `confirmCount` twice, and submitting two reports within the 2-minute cooldown window must throw a `RateLimitException`.

---

### Task 1: Project Scaffolding, Domain Models & Privacy/Geohash Utilities

**Files:**
- Create: `/home/carbon/projects/learn/rain-reporter/pubspec.yaml`
- Create: `/home/carbon/projects/learn/rain-reporter/lib/domain/rain_intensity.dart`
- Create: `/home/carbon/projects/learn/rain-reporter/lib/domain/rain_report.dart`
- Create: `/home/carbon/projects/learn/rain-reporter/lib/domain/location_privacy.dart`
- Test: `/home/carbon/projects/learn/rain-reporter/test/domain/rain_report_test.dart`
- Test: `/home/carbon/projects/learn/rain-reporter/test/domain/location_privacy_test.dart`

**Interfaces:**
- Consumes: none
- Produces:
  - `enum RainIntensity { light, moderate, heavy, storm, stopped }` with `String get wireName`, `String get label`, and `static RainIntensity fromWire(String value)`
  - `class RainReport` with fields `id`, `uid`, `intensity`, `note`, `lat`, `lng`, `geohash`, `confirmCount`, `stoppedCount`, `createdAt`, `expiresAt`, plus `Map<String, dynamic> toMap()`, `factory RainReport.fromMap(String id, Map<String, dynamic> map)`, `bool isActiveAt(DateTime now)`
  - `class LocationPrivacy` with:
    - `static ({double lat, double lng}) fuzzCoordinate({required double lat, required double lng, Random? random})` (displaces by 100m–200m)
    - `static double distanceMeters(double lat1, double lng1, double lat2, double lng2)` (Haversine)
    - `static String encodeGeohash(double lat, double lng, {int precision = 7})`
    - `static List<RainReport> filterActiveReports(Iterable<RainReport> reports, {required DateTime now, double stoppedRadiusMeters = 300})`

- [ ] **Step 1: Scaffold Flutter Android project and initialize git repository**

Run:
```bash
flutter create --platforms=android --org com.example.rainreporter /home/carbon/projects/learn/rain-reporter
cd /home/carbon/projects/learn/rain-reporter && git init
```
Expected: Flutter project created in `/home/carbon/projects/learn/rain-reporter` and git repository initialized.

- [ ] **Step 2: Configure dependencies in `pubspec.yaml` and fetch packages**

Add dependencies to `/home/carbon/projects/learn/rain-reporter/pubspec.yaml`:
`firebase_core`, `firebase_auth`, `cloud_firestore`, `google_maps_flutter`, `geolocator` and run `flutter pub get`.

- [ ] **Step 3: Write failing unit tests in `test/domain/location_privacy_test.dart` and `test/domain/rain_report_test.dart`**

```dart
// test/domain/location_privacy_test.dart
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:rain_reporter/domain/location_privacy.dart';

void main() {
  test('fuzzCoordinate displaces point between 100m and 200m across seeds', () {
    const rawLat = -6.200000;
    const rawLng = 106.816666;
    for (var seed = 0; seed < 100; seed++) {
      final fuzzed = LocationPrivacy.fuzzCoordinate(
        lat: rawLat,
        lng: rawLng,
        random: Random(seed),
      );
      final dist = LocationPrivacy.distanceMeters(
        rawLat,
        rawLng,
        fuzzed.lat,
        fuzzed.lng,
      );
      expect(dist, greaterThanOrEqualTo(100.0));
      expect(dist, lessThanOrEqualTo(200.5));
    }
  });

  test('encodeGeohash produces deterministic 7-char geohash', () {
    final hash = LocationPrivacy.encodeGeohash(-6.200000, 106.816666, precision: 7);
    expect(hash.length, 7);
    expect(hash, equals(LocationPrivacy.encodeGeohash(-6.200000, 106.816666, precision: 7)));
  });
}
```

```dart
// test/domain/rain_report_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rain_reporter/domain/location_privacy.dart';
import 'package:rain_reporter/domain/rain_intensity.dart';
import 'package:rain_reporter/domain/rain_report.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 13, 10, 0);

  test('RainReport trims whitespace-only note to null and enforces 140 char limit', () {
    final emptyNoteReport = RainReport.create(
      id: 'r1',
      uid: 'u1',
      intensity: RainIntensity.heavy,
      note: '   ',
      lat: -6.2,
      lng: 106.8,
      createdAt: t0,
    );
    expect(emptyNoteReport.note, isNull);
    expect(emptyNoteReport.expiresAt, equals(t0.add(const Duration(minutes: 30))));

    expect(
      () => RainReport.create(
        id: 'r2',
        uid: 'u1',
        intensity: RainIntensity.light,
        note: 'a' * 141,
        lat: -6.2,
        lng: 106.8,
        createdAt: t0,
      ),
      throwsArgumentError,
    );
  });

  test('filterActiveReports excludes reports at or past 30m boundary and those superseded by newer nearby stopped report', () {
    final activeRain = RainReport.create(
      id: 'rain-old',
      uid: 'u1',
      intensity: RainIntensity.heavy,
      lat: -6.2000,
      lng: 106.8166,
      createdAt: t0,
    );
    final expiredRain = RainReport.create(
      id: 'rain-expired',
      uid: 'u2',
      intensity: RainIntensity.moderate,
      lat: -6.2100,
      lng: 106.8266,
      createdAt: t0.subtract(const Duration(minutes: 25)),
    );
    final stoppedNearby = RainReport.create(
      id: 'stopped-new',
      uid: 'u3',
      intensity: RainIntensity.stopped,
      lat: -6.2005, // ~55m away from activeRain
      lng: 106.8166,
      createdAt: t0.add(const Duration(minutes: 5)),
    );

    final now = t0.add(const Duration(minutes: 5));
    final visible = LocationPrivacy.filterActiveReports(
      [activeRain, expiredRain, stoppedNearby],
      now: now,
    );
    expect(visible.map((r) => r.id), isEmpty);
  });
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `cd /home/carbon/projects/learn/rain-reporter && flutter test test/domain/`
Expected: FAIL (missing `rain_intensity.dart`, `rain_report.dart`, `location_privacy.dart`).

- [ ] **Step 5: Implement `RainIntensity`, `RainReport`, and `LocationPrivacy`**

Implement `/home/carbon/projects/learn/rain-reporter/lib/domain/rain_intensity.dart`, `/home/carbon/projects/learn/rain-reporter/lib/domain/rain_report.dart`, and `/home/carbon/projects/learn/rain-reporter/lib/domain/location_privacy.dart`.
- `RainReport.create` sets `expiresAt = createdAt.add(const Duration(minutes: 30))`, normalizes blank notes to `null`, throws `ArgumentError` if trimmed note length > 140, and computes `geohash` via `LocationPrivacy.encodeGeohash`.
- `LocationPrivacy.filterActiveReports` filters out reports where `!report.isActiveAt(now)` (`expiresAt.isAfter(now)`), filters out reports with `intensity == RainIntensity.stopped` or `stoppedCount >= 2` from active rain pin display, and hides any rain report that has a newer (`stopped.createdAt.isAfter(rain.createdAt)`) active `stopped` report within `stoppedRadiusMeters` (default `300m`).

- [ ] **Step 6: Run domain tests to verify they pass**

Run: `cd /home/carbon/projects/learn/rain-reporter && flutter test test/domain/`
Expected: PASS (all domain tests green).

- [ ] **Step 7: Commit Task 1**

```bash
cd /home/carbon/projects/learn/rain-reporter
git add .
git commit -m "feat(domain): scaffold project and add rain report model with coordinate fuzzing"
```

---

### Task 2: Firestore Security Rules & Firebase Configuration Files

**Files:**
- Create: `/home/carbon/projects/learn/rain-reporter/firestore.rules` (via `firestore-rules-author` subagent)
- Create: `/home/carbon/projects/learn/rain-reporter/firestore.indexes.json`
- Create: `/home/carbon/projects/learn/rain-reporter/firebase.json`

**Interfaces:**
- Consumes: Firestore schema from Spec Section 5 (`reports/{reportId}`, `reports/{reportId}/votes/{uid}`, `rateLimits/{uid}`)
- Produces: Production-grade `firestore.rules`, composite index configuration `firestore.indexes.json`, and `firebase.json`

- [ ] **Step 1: Delegate `firestore.rules` creation to `firestore-rules-author` subagent**

Invoke `firestore-rules-author` to create `/home/carbon/projects/learn/rain-reporter/firestore.rules` enforcing:
- `reports/{reportId}`:
  - `read`: allowed when `resource.data.expiresAt > request.time`
  - `create`: requires `request.auth != null`, `request.resource.data.uid == request.auth.uid`, `intensity in ['light', 'moderate', 'heavy', 'storm', 'stopped']`, optional `note` string with `size() <= 140`, valid `lat`/`lng`/`geohash`, `confirmCount == 1`, `stoppedCount == 0`, `createdAt == request.time`, `expiresAt == request.time + duration.value(30, 'm')`, and rate-limit check via `rateLimits/{uid}` (at least 2 minutes since prior report).
  - `update`: only allows incrementing `confirmCount` or `stoppedCount` by 1 when accompanied by creating a matching vote document under `reports/{reportId}/votes/{request.auth.uid}`.
- `reports/{reportId}/votes/{uid}`:
  - `create`: requires `request.auth != null && request.auth.uid == uid`, document does not already exist, `type in ['confirm', 'stopped']`.
- `rateLimits/{uid}`:
  - `write`: requires `request.auth != null && request.auth.uid == uid`, `lastReportAt == request.time`, and either document does not exist or `request.time >= resource.data.lastReportAt + duration.value(2, 'm')`.

- [ ] **Step 2: Create `firestore.indexes.json` and `firebase.json`**

Create `/home/carbon/projects/learn/rain-reporter/firestore.indexes.json` with composite index on `reports` (`geohash` ASC, `expiresAt` ASC) and TTL policy on `expiresAt`, plus `/home/carbon/projects/learn/rain-reporter/firebase.json` pointing to `firestore.rules` and `firestore.indexes.json`.

- [ ] **Step 3: Verify rules and config files exist and are non-empty**

Run: `ls -la /home/carbon/projects/learn/rain-reporter/firestore.rules /home/carbon/projects/learn/rain-reporter/firestore.indexes.json /home/carbon/projects/learn/rain-reporter/firebase.json`
Expected: All three files exist and contain valid rules/JSON.

- [ ] **Step 4: Commit Task 2**

```bash
cd /home/carbon/projects/learn/rain-reporter
git add firestore.rules firestore.indexes.json firebase.json
git commit -m "feat(firebase): add Firestore security rules and index config"
```

---

### Task 3: Auth Service & Rain Report Repository (Firestore + In-Memory Implementation)

**Files:**
- Create: `/home/carbon/projects/learn/rain-reporter/lib/data/auth_service.dart`
- Create: `/home/carbon/projects/learn/rain-reporter/lib/data/rain_report_repository.dart`
- Create: `/home/carbon/projects/learn/rain-reporter/lib/data/firestore_rain_report_repository.dart`
- Test: `/home/carbon/projects/learn/rain-reporter/test/data/rain_report_repository_test.dart`

**Interfaces:**
- Consumes: `RainIntensity`, `RainReport`, `LocationPrivacy` from Task 1
- Produces:
  - `class RateLimitException implements Exception`
  - `class DuplicateVoteException implements Exception`
  - `abstract class AuthService { Future<String> ensureAnonymousUid(); }`
  - `class FirebaseAuthService implements AuthService`
  - `class FakeAuthService implements AuthService`
  - `abstract class RainReportRepository`:
    - `Stream<List<RainReport>> watchActiveReports({required double centerLat, required double centerLng, double radiusMeters = 10000})`
    - `Future<RainReport> submitReport({required String uid, required RainIntensity intensity, required double rawLat, required double rawLng, String? note})`
    - `Future<void> voteReport({required String reportId, required String uid, required bool isStillRaining})`
  - `class InMemoryRainReportRepository implements RainReportRepository`
  - `class FirestoreRainReportRepository implements RainReportRepository`

- [ ] **Step 1: Write failing unit tests in `test/data/rain_report_repository_test.dart`**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rain_reporter/data/rain_report_repository.dart';
import 'package:rain_reporter/domain/location_privacy.dart';
import 'package:rain_reporter/domain/rain_intensity.dart';

void main() {
  late DateTime currentTime;
  late InMemoryRainReportRepository repo;

  setUp(() {
    currentTime = DateTime.utc(2026, 11, 13, 10, 0);
    repo = InMemoryRainReportRepository(clock: () => currentTime);
  });

  test('submitReport fuzzes coordinates (100-200m) and emits active report', () async {
    final report = await repo.submitReport(
      uid: 'user-1',
      intensity: RainIntensity.heavy,
      rawLat: -6.2000,
      rawLng: 106.8166,
      note: 'Pouring near station',
    );

    final dist = LocationPrivacy.distanceMeters(-6.2000, 106.8166, report.lat, report.lng);
    expect(dist, inInclusiveRange(100.0, 200.5));

    final active = await repo.watchActiveReports(centerLat: -6.2000, centerLng: 106.8166).first;
    expect(active.length, 1);
    expect(active.first.id, report.id);
  });

  test('submitReport enforces 2-minute rate limit per uid', () async {
    await repo.submitReport(
      uid: 'user-1',
      intensity: RainIntensity.light,
      rawLat: -6.2000,
      rawLng: 106.8166,
    );

    expect(
      () => repo.submitReport(
        uid: 'user-1',
        intensity: RainIntensity.moderate,
        rawLat: -6.2000,
        rawLng: 106.8166,
      ),
      throwsA(isA<RateLimitException>()),
    );
  });

  test('voteReport increments confirmCount once per uid and rejects duplicate vote', () async {
    final report = await repo.submitReport(
      uid: 'user-1',
      intensity: RainIntensity.moderate,
      rawLat: -6.2000,
      rawLng: 106.8166,
    );

    await repo.voteReport(reportId: report.id, uid: 'user-2', isStillRaining: true);
    final updated = await repo.watchActiveReports(centerLat: -6.2000, centerLng: 106.8166).first;
    expect(updated.first.confirmCount, 2);

    expect(
      () => repo.voteReport(reportId: report.id, uid: 'user-2', isStillRaining: true),
      throwsA(isA<DuplicateVoteException>()),
    );
  });
}
```

- [ ] **Step 2: Run repository tests to verify they fail**

Run: `cd /home/carbon/projects/learn/rain-reporter && flutter test test/data/rain_report_repository_test.dart`
Expected: FAIL (missing data files).

- [ ] **Step 3: Implement `AuthService`, `RainReportRepository`, `InMemoryRainReportRepository`, and `FirestoreRainReportRepository`**

Implement `/home/carbon/projects/learn/rain-reporter/lib/data/auth_service.dart`, `/home/carbon/projects/learn/rain-reporter/lib/data/rain_report_repository.dart`, and `/home/carbon/projects/learn/rain-reporter/lib/data/firestore_rain_report_repository.dart`.
- Both repositories apply `LocationPrivacy.fuzzCoordinate` on `rawLat`/`rawLng` before persisting, enforce the 2-minute per-`uid` cooldown (`RateLimitException`), prevent duplicate votes per `(reportId, uid)` (`DuplicateVoteException`), and filter emitted reports through `LocationPrivacy.filterActiveReports`.

- [ ] **Step 4: Run repository tests to verify they pass**

Run: `cd /home/carbon/projects/learn/rain-reporter && flutter test test/data/rain_report_repository_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit Task 3**

```bash
cd /home/carbon/projects/learn/rain-reporter
git add lib/data/ test/data/
git commit -m "feat(data): add auth service and rain report repositories"
```

---

### Task 4: Quick Report & Pin Detail Bottom Sheets

**Files:**
- Create: `/home/carbon/projects/learn/rain-reporter/lib/ui/report_bottom_sheet.dart`
- Create: `/home/carbon/projects/learn/rain-reporter/lib/ui/pin_detail_bottom_sheet.dart`
- Test: `/home/carbon/projects/learn/rain-reporter/test/ui/sheets_test.dart`

**Interfaces:**
- Consumes: `RainIntensity`, `RainReport` from Task 1
- Produces:
  - `class ReportSubmission { final RainIntensity intensity; final String? note; }`
  - `class ReportBottomSheet extends StatefulWidget` with `final ValueChanged<ReportSubmission> onSubmit`
  - `class PinDetailBottomSheet extends StatelessWidget` with `final RainReport report`, `final DateTime now`, `final VoidCallback onConfirmStillRaining`, `final VoidCallback onMarkStopped`

- [ ] **Step 1: Write failing widget tests in `test/ui/sheets_test.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rain_reporter/domain/rain_intensity.dart';
import 'package:rain_reporter/domain/rain_report.dart';
import 'package:rain_reporter/ui/pin_detail_bottom_sheet.dart';
import 'package:rain_reporter/ui/report_bottom_sheet.dart';

void main() {
  testWidgets('ReportBottomSheet selects intensity and submits note', (tester) async {
    ReportSubmission? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportBottomSheet(
            onSubmit: (value) => submitted = value,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Heavy'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Visibility low');
    await tester.tap(find.text('Submit Report'));
    await tester.pump();

    expect(submitted, isNotNull);
    expect(submitted!.intensity, RainIntensity.heavy);
    expect(submitted!.note, 'Visibility low');
  });

  testWidgets('PinDetailBottomSheet displays report details and triggers vote callbacks', (tester) async {
    var confirmed = false;
    var stopped = false;
    final t0 = DateTime.utc(2026, 11, 13, 10, 0);
    final report = RainReport.create(
      id: 'r1',
      uid: 'u1',
      intensity: RainIntensity.storm,
      note: 'Thunder and heavy wind',
      lat: -6.2,
      lng: 106.8,
      createdAt: t0,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinDetailBottomSheet(
            report: report,
            now: t0.add(const Duration(minutes: 4)),
            onConfirmStillRaining: () => confirmed = true,
            onMarkStopped: () => stopped = true,
          ),
        ),
      ),
    );

    expect(find.textContaining('Storm'), findsOneWidget);
    expect(find.text('Thunder and heavy wind'), findsOneWidget);
    expect(find.textContaining('4m ago'), findsOneWidget);

    await tester.tap(find.text('Still raining'));
    expect(confirmed, isTrue);

    await tester.tap(find.text('Stopped here'));
    expect(stopped, isTrue);
  });
}
```

- [ ] **Step 2: Run sheet widget tests to verify they fail**

Run: `cd /home/carbon/projects/learn/rain-reporter && flutter test test/ui/sheets_test.dart`
Expected: FAIL (missing `report_bottom_sheet.dart` and `pin_detail_bottom_sheet.dart`).

- [ ] **Step 3: Implement `ReportBottomSheet` and `PinDetailBottomSheet`**

Implement `/home/carbon/projects/learn/rain-reporter/lib/ui/report_bottom_sheet.dart` (ChoiceChips for `Light`, `Moderate`, `Heavy`, `Storm`, `Stopped`, `TextField` with `maxLength: 140`, and `'Submit Report'` button) and `/home/carbon/projects/learn/rain-reporter/lib/ui/pin_detail_bottom_sheet.dart` (displays intensity label, relative age `${now.difference(report.createdAt).inMinutes}m ago`, optional note, confirmation badge, `'Still raining'` button, and `'Stopped here'` button).

- [ ] **Step 4: Run sheet widget tests to verify they pass**

Run: `cd /home/carbon/projects/learn/rain-reporter && flutter test test/ui/sheets_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit Task 4**

```bash
cd /home/carbon/projects/learn/rain-reporter
git add lib/ui/ test/ui/sheets_test.dart
git commit -m "feat(ui): add quick report and pin detail bottom sheets"
```

---

### Task 5: Live Map Screen, Android Manifest Configuration & App Entrypoint

**Files:**
- Modify: `/home/carbon/projects/learn/rain-reporter/android/app/src/main/AndroidManifest.xml`
- Create: `/home/carbon/projects/learn/rain-reporter/lib/ui/map_screen.dart`
- Modify: `/home/carbon/projects/learn/rain-reporter/lib/main.dart`
- Modify: `/home/carbon/projects/learn/rain-reporter/test/widget_test.dart`

**Interfaces:**
- Consumes: `AuthService`, `RainReportRepository` from Task 3; `ReportBottomSheet`, `PinDetailBottomSheet` from Task 4
- Produces:
  - `class MapScreen extends StatefulWidget` accepting `AuthService authService`, `RainReportRepository repository`, optional `Future<({double lat, double lng})> Function()? locationProvider`, and `bool useNativeMapView` (defaults to `true`, allows widget testing marker list/interactions without platform view channels when `false` or overlays active pin count + quick-report trigger).
  - `class RainReporterApp extends StatelessWidget` in `lib/main.dart`

- [ ] **Step 1: Write failing widget test in `test/widget_test.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rain_reporter/data/auth_service.dart';
import 'package:rain_reporter/data/rain_report_repository.dart';
import 'package:rain_reporter/main.dart';

void main() {
  testWidgets('MapScreen renders active report count, opens ReportBottomSheet, and submits report', (tester) async {
    final repo = InMemoryRainReportRepository();
    final auth = FakeAuthService(uid: 'test-uid');

    await tester.pumpWidget(
      RainReporterApp(
        authService: auth,
        repository: repo,
        useNativeMapView: false,
        locationProvider: () async => (lat: -6.2000, lng: 106.8166),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Report Rain'), findsOneWidget);
    expect(find.text('0 active nearby'), findsOneWidget);

    await tester.tap(find.text('Report Rain'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Heavy'));
    await tester.pump();
    await tester.tap(find.text('Submit Report'));
    await tester.pumpAndSettle();

    expect(find.text('1 active nearby'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run widget test to verify it fails**

Run: `cd /home/carbon/projects/learn/rain-reporter && flutter test test/widget_test.dart`
Expected: FAIL.

- [ ] **Step 3: Configure Android permissions & Google Maps metadata in `AndroidManifest.xml`, and implement `MapScreen` and `main.dart`**

1. In `/home/carbon/projects/learn/rain-reporter/android/app/src/main/AndroidManifest.xml`, add `ACCESS_FINE_LOCATION` and `ACCESS_COARSE_LOCATION` `<uses-permission>` entries and `<meta-data android:name="com.google.android.geo.API_KEY" android:value="${MAPS_API_KEY}"/>` with a default placeholder in `android/app/build.gradle.kts` (`manifestPlaceholders["MAPS_API_KEY"] = System.getenv("MAPS_API_KEY") ?: "YOUR_GOOGLE_MAPS_API_KEY"`).
2. Implement `/home/carbon/projects/learn/rain-reporter/lib/ui/map_screen.dart` with:
   - Google Map view (`GoogleMap` with `Marker`s colored by `RainIntensity` hue, or a lightweight fallback canvas when `useNativeMapView == false` in widget tests).
   - Top status pill showing `'${reports.length} active nearby'` and tapping a marker/chip opens `PinDetailBottomSheet`.
   - Floating action button `'Report Rain'` opening `ReportBottomSheet`, submitting via `repository.submitReport(...)`, and showing a `SnackBar` on `RateLimitException` or `DuplicateVoteException`.
3. Update `/home/carbon/projects/learn/rain-reporter/lib/main.dart` to attempt `Firebase.initializeApp()` and use `FirestoreRainReportRepository` + `FirebaseAuthService`, falling back cleanly to `InMemoryRainReportRepository` + `FakeAuthService` if Firebase is not yet configured on the local machine.

- [ ] **Step 4: Run all tests and static analysis**

Run: `cd /home/carbon/projects/learn/rain-reporter && flutter test && flutter analyze`
Expected: All tests PASS and `flutter analyze` reports `No issues found!`.

- [ ] **Step 5: Commit Task 5**

```bash
cd /home/carbon/projects/learn/rain-reporter
git add .
git commit -m "feat(app): wire Google Maps screen, Android manifest permissions, and main entrypoint"
```
