import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:rain_reporter/data/auth_service.dart';
import 'package:rain_reporter/data/rain_report_repository.dart';
import 'package:rain_reporter/domain/rain_intensity.dart';
import 'package:rain_reporter/domain/rain_report.dart';
import 'package:rain_reporter/main.dart';
import 'package:rain_reporter/ui/cluster_detail_bottom_sheet.dart';
import 'package:rain_reporter/ui/map_screen.dart';
import 'package:rain_reporter/ui/pin_detail_bottom_sheet.dart';

class _CountingRepository extends InMemoryRainReportRepository {
  int watchCalls = 0;
  double? lastWatchedLat;
  double? lastWatchedLng;
  double? lastSubmittedLat;
  double? lastSubmittedLng;

  @override
  Stream<List<RainReport>> watchActiveReports({
    required double centerLat,
    required double centerLng,
    double radiusMeters = 10000,
  }) {
    watchCalls++;
    lastWatchedLat = centerLat;
    lastWatchedLng = centerLng;
    return super.watchActiveReports(
      centerLat: centerLat,
      centerLng: centerLng,
      radiusMeters: radiusMeters,
    );
  }

  @override
  Future<RainReport> submitReport({
    required String uid,
    required RainIntensity intensity,
    required double rawLat,
    required double rawLng,
    String? note,
  }) {
    lastSubmittedLat = rawLat;
    lastSubmittedLng = rawLng;
    return super.submitReport(
      uid: uid,
      intensity: intensity,
      rawLat: rawLat,
      rawLng: rawLng,
      note: note,
    );
  }
}

void main() {
  testWidgets('MapScreen renders OpenStreetMap (FlutterMap), opens ReportBottomSheet, submits report, and does not recreate stream on rebuild', (tester) async {
    final repo = _CountingRepository();
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

    expect(find.byType(FlutterMap), findsOneWidget);
    final initialWatchCalls = repo.watchCalls;
    expect(find.text('Report Rain'), findsOneWidget);
    expect(find.text('0 active nearby'), findsOneWidget);

    await tester.tap(find.text('Report Rain'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Heavy'));
    await tester.pump();
    await tester.tap(find.text('Submit Report'));
    await tester.pumpAndSettle();

    expect(find.text('1 active nearby'), findsOneWidget);
    expect(repo.watchCalls, equals(initialWatchCalls));
  });

  testWidgets('blocks Report Rain with SnackBar when GPS is unavailable', (tester) async {
    final repo = _CountingRepository();
    final auth = FakeAuthService(uid: 'test-uid');

    await tester.pumpWidget(
      RainReporterApp(
        authService: auth,
        repository: repo,
        useNativeMapView: false,
        locationProvider: () async => null,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Report Rain'));
    await tester.pumpAndSettle();

    expect(
      find.text('Location access is required to report rain.'),
      findsOneWidget,
    );
    expect(find.text('Submit Report'), findsNothing);
    expect(repo.lastSubmittedLat, isNull);
  });

  testWidgets('blocks Report Rain gracefully when GPS provider throws', (tester) async {
    final repo = _CountingRepository();
    final auth = FakeAuthService(uid: 'test-uid');

    await tester.pumpWidget(
      RainReporterApp(
        authService: auth,
        repository: repo,
        useNativeMapView: false,
        locationProvider: () async => throw Exception('gps off'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Report Rain'));
    await tester.pumpAndSettle();

    expect(
      find.text('Location access is required to report rain.'),
      findsOneWidget,
    );
    expect(find.text('Submit Report'), findsNothing);
    expect(repo.lastSubmittedLat, isNull);
  });

  testWidgets('submits report at real GPS even after panning map elsewhere', (tester) async {
    final repo = _CountingRepository();
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

    final mapWidget = tester.widget<FlutterMap>(find.byType(FlutterMap));
    mapWidget.mapController!.move(const LatLng(-6.3000, 106.9000), 14);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Report Rain'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Heavy'));
    await tester.pump();
    await tester.tap(find.text('Submit Report'));
    await tester.pumpAndSettle();

    expect(repo.lastSubmittedLat, equals(-6.2000));
    expect(repo.lastSubmittedLng, equals(106.8166));
  });

  testWidgets('refreshes active reports stream after debounced pan beyond 500m', (tester) async {
    final repo = _CountingRepository();
    final auth = FakeAuthService(uid: 'test-uid');

    await tester.pumpWidget(
      MaterialApp(
        home: MapScreen(
          authService: auth,
          repository: repo,
          useNativeMapView: false,
          locationProvider: () async => (lat: -6.2000, lng: 106.8166),
          panDebounceDuration: const Duration(milliseconds: 200),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final initialWatchCalls = repo.watchCalls;
    final mapWidget = tester.widget<FlutterMap>(find.byType(FlutterMap));
    mapWidget.mapController!.move(const LatLng(-6.2200, 106.8166), 14);

    await tester.pump(const Duration(milliseconds: 100));
    expect(repo.watchCalls, equals(initialWatchCalls));

    await tester.pump(const Duration(milliseconds: 150));
    expect(repo.watchCalls, equals(initialWatchCalls + 1));
    expect(repo.lastWatchedLat, closeTo(-6.2200, 0.001));
    expect(repo.lastWatchedLng, closeTo(106.8166, 0.001));
  });

  testWidgets('does not refresh stream when pan distance is within 500m', (tester) async {
    final repo = _CountingRepository();
    final auth = FakeAuthService(uid: 'test-uid');

    await tester.pumpWidget(
      MaterialApp(
        home: MapScreen(
          authService: auth,
          repository: repo,
          useNativeMapView: false,
          locationProvider: () async => (lat: -6.2000, lng: 106.8166),
          panDebounceDuration: const Duration(milliseconds: 200),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final initialWatchCalls = repo.watchCalls;
    final mapWidget = tester.widget<FlutterMap>(find.byType(FlutterMap));
    // ~55m south
    mapWidget.mapController!.move(const LatLng(-6.2005, 106.8166), 14);

    await tester.pump(const Duration(milliseconds: 300));
    expect(repo.watchCalls, equals(initialWatchCalls));
  });

  testWidgets('coalesces rapid pans within debounce window into a single refresh', (tester) async {
    final repo = _CountingRepository();
    final auth = FakeAuthService(uid: 'test-uid');

    await tester.pumpWidget(
      MaterialApp(
        home: MapScreen(
          authService: auth,
          repository: repo,
          useNativeMapView: false,
          locationProvider: () async => (lat: -6.2000, lng: 106.8166),
          panDebounceDuration: const Duration(milliseconds: 200),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final initialWatchCalls = repo.watchCalls;
    final mapWidget = tester.widget<FlutterMap>(find.byType(FlutterMap));

    mapWidget.mapController!.move(const LatLng(-6.2200, 106.8166), 14);
    await tester.pump(const Duration(milliseconds: 100));
    mapWidget.mapController!.move(const LatLng(-6.2500, 106.8500), 14);

    await tester.pump(const Duration(milliseconds: 250));
    expect(repo.watchCalls, equals(initialWatchCalls + 1));
    expect(repo.lastWatchedLat, closeTo(-6.2500, 0.001));
    expect(repo.lastWatchedLng, closeTo(106.8500, 0.001));
  });

  testWidgets('cancels pending pan debounce timer on dispose', (tester) async {
    final repo = _CountingRepository();
    final auth = FakeAuthService(uid: 'test-uid');

    await tester.pumpWidget(
      MaterialApp(
        home: MapScreen(
          authService: auth,
          repository: repo,
          useNativeMapView: false,
          locationProvider: () async => (lat: -6.2000, lng: 106.8166),
          panDebounceDuration: const Duration(milliseconds: 200),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final mapWidget = tester.widget<FlutterMap>(find.byType(FlutterMap));
    mapWidget.mapController!.move(const LatLng(-6.2200, 106.8166), 14);

    // Unmount immediately while debounce timer is pending
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ignores duplicate Report Rain taps while GPS lookup is in flight', (tester) async {
    final repo = _CountingRepository();
    final auth = FakeAuthService(uid: 'test-uid');
    var calls = 0;
    final pendingGps = Completer<({double lat, double lng})?>();

    await tester.pumpWidget(
      RainReporterApp(
        authService: auth,
        repository: repo,
        useNativeMapView: false,
        locationProvider: () {
          calls++;
          if (calls == 1) {
            return Future.value((lat: -6.2000, lng: 106.8166));
          }
          return pendingGps.future;
        },
      ),
    );
    await tester.pumpAndSettle();

    // Tap Report Rain twice while GPS lookup is pending
    await tester.tap(find.text('Report Rain'));
    await tester.pump();
    await tester.tap(find.text('Report Rain'));
    await tester.pump();

    expect(calls, equals(2));

    pendingGps.complete((lat: -6.2000, lng: 106.8166));
    await tester.pumpAndSettle();

    expect(find.text('Submit Report'), findsOneWidget);
  });

  testWidgets('renders CircleLayer with 300m radius for a single active report and opens PinDetailBottomSheet on tap', (tester) async {
    final repo = _CountingRepository();
    final auth = FakeAuthService(uid: 'test-uid');
    await repo.submitReport(
      uid: 'u1',
      intensity: RainIntensity.heavy,
      rawLat: -6.2000,
      rawLng: 106.8166,
      note: 'Pouring hard',
    );

    await tester.pumpWidget(
      RainReporterApp(
        authService: auth,
        repository: repo,
        useNativeMapView: false,
        locationProvider: () async => (lat: -6.2000, lng: 106.8166),
      ),
    );
    await tester.pumpAndSettle();

    final circleLayer = tester.widget<CircleLayer>(find.byType(CircleLayer));
    expect(circleLayer.circles, hasLength(1));
    expect(circleLayer.circles.single.useRadiusInMeter, isTrue);
    expect(circleLayer.circles.single.radius, equals(300));

    await tester.tap(find.byIcon(Icons.location_on));
    await tester.pumpAndSettle();

    expect(find.byType(PinDetailBottomSheet), findsOneWidget);
    expect(find.text('Pouring hard'), findsOneWidget);
  });

  testWidgets('merges nearby reports into one larger CircleMarker and cluster badge that opens ClusterDetailBottomSheet', (tester) async {
    final repo = _CountingRepository();
    final auth = FakeAuthService(uid: 'voter-uid');
    await repo.submitReport(
      uid: 'u1',
      intensity: RainIntensity.light,
      rawLat: -6.2000,
      rawLng: 106.8166,
      note: 'Drizzling',
    );
    await repo.submitReport(
      uid: 'u2',
      intensity: RainIntensity.storm,
      rawLat: -6.2000,
      rawLng: 106.8166,
      note: 'Thunderstorm',
    );

    await tester.pumpWidget(
      RainReporterApp(
        authService: auth,
        repository: repo,
        useNativeMapView: false,
        locationProvider: () async => (lat: -6.2000, lng: 106.8166),
      ),
    );
    await tester.pumpAndSettle();

    final circleLayer = tester.widget<CircleLayer>(find.byType(CircleLayer));
    expect(circleLayer.circles, hasLength(1));
    expect(circleLayer.circles.single.useRadiusInMeter, isTrue);
    expect(circleLayer.circles.single.radius, greaterThan(300));

    expect(find.byIcon(Icons.location_on), findsNothing);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.text('2'));
    await tester.pumpAndSettle();

    expect(find.byType(ClusterDetailBottomSheet), findsOneWidget);
    expect(find.text('2 reports'), findsOneWidget);

    await tester.tap(find.text('Still raining').first);
    await tester.pumpAndSettle();

    final active = await repo
        .watchActiveReports(centerLat: -6.2000, centerLng: 106.8166)
        .first;
    expect(active.any((r) => r.confirmCount == 2), isTrue);
  });

  testWidgets('keeps distant reports (>600m apart) as separate CircleMarkers and individual pins', (tester) async {
    final repo = _CountingRepository();
    final auth = FakeAuthService(uid: 'test-uid');
    await repo.submitReport(
      uid: 'u1',
      intensity: RainIntensity.moderate,
      rawLat: -6.2000,
      rawLng: 106.8166,
    );
    // ~830m east (outside 600m merge threshold, visible at zoom 16)
    await repo.submitReport(
      uid: 'u2',
      intensity: RainIntensity.heavy,
      rawLat: -6.2000,
      rawLng: 106.8241,
    );

    await tester.pumpWidget(
      RainReporterApp(
        authService: auth,
        repository: repo,
        useNativeMapView: false,
        locationProvider: () async => (lat: -6.2000, lng: 106.8166),
      ),
    );
    await tester.pumpAndSettle();

    final circleLayer = tester.widget<CircleLayer>(find.byType(CircleLayer));
    expect(circleLayer.circles, hasLength(2));
    expect(find.byIcon(Icons.location_on), findsNWidgets(2));
  });

  testWidgets('preserves previous reports without flickering to 0 while refreshed stream is waiting', (tester) async {
    final controller1 = StreamController<List<RainReport>>.broadcast();
    final controller2 = StreamController<List<RainReport>>.broadcast();
    addTearDown(() async {
      await controller1.close();
      await controller2.close();
    });
    var watchCall = 0;

    final repo = _CustomStreamRepository((lat, lng) {
      watchCall++;
      return watchCall == 1 ? controller1.stream : controller2.stream;
    });
    final auth = FakeAuthService(uid: 'test-uid');

    await tester.pumpWidget(
      MaterialApp(
        home: MapScreen(
          authService: auth,
          repository: repo,
          useNativeMapView: false,
          locationProvider: () async => (lat: -6.9175, lng: 107.6191),
          panDebounceDuration: const Duration(milliseconds: 100),
        ),
      ),
    );
    await tester.pump();

    controller1.add([
      RainReport.create(
        id: 'r1',
        uid: 'u1',
        intensity: RainIntensity.heavy,
        lat: -6.9175,
        lng: 107.6191,
        createdAt: DateTime.now().toUtc(),
      ),
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('1 active nearby'), findsOneWidget);

    // Pan >500m to trigger a new stream that has not emitted yet
    final mapWidget = tester.widget<FlutterMap>(find.byType(FlutterMap));
    mapWidget.mapController!.move(const LatLng(-6.9300, 107.6191), 14);
    await tester.pump(const Duration(milliseconds: 150));

    // Must still display 1 active nearby instead of flickering to 0 while waiting
    expect(find.text('1 active nearby'), findsOneWidget);
  });

  testWidgets('animates zoom to 16 at user location, shows user dot, and recenters on tap', (tester) async {
    final repo = _CountingRepository();
    final auth = FakeAuthService(uid: 'test-uid');

    await tester.pumpWidget(
      RainReporterApp(
        authService: auth,
        repository: repo,
        useNativeMapView: false,
        locationProvider: () async => (lat: -6.9000, lng: 107.6000),
      ),
    );
    await tester.pumpAndSettle();

    final mapWidget = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(mapWidget.mapController!.camera.zoom, closeTo(16.0, 0.01));
    expect(mapWidget.mapController!.camera.center.latitude, closeTo(-6.9000, 0.0001));
    expect(mapWidget.mapController!.camera.center.longitude, closeTo(107.6000, 0.0001));
    expect(find.byKey(const Key('user_location_marker')), findsOneWidget);

    // Pan away, then tap recenter button
    mapWidget.mapController!.move(const LatLng(-6.9500, 107.6500), 13);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('recenter_button')));
    await tester.pumpAndSettle();

    expect(mapWidget.mapController!.camera.zoom, closeTo(16.0, 0.01));
    expect(mapWidget.mapController!.camera.center.latitude, closeTo(-6.9000, 0.0001));
    expect(mapWidget.mapController!.camera.center.longitude, closeTo(107.6000, 0.0001));
  });

  testWidgets('shows offline mode banner when isOfflineMode is true', (tester) async {
    final repo = _CountingRepository();
    final auth = FakeAuthService(uid: 'test-uid');

    await tester.pumpWidget(
      RainReporterApp(
        authService: auth,
        repository: repo,
        useNativeMapView: false,
        isOfflineMode: true,
        locationProvider: () async => (lat: -6.9175, lng: 107.6191),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Offline mode (local only)'), findsOneWidget);
  });
}

class _CustomStreamRepository extends InMemoryRainReportRepository {
  _CustomStreamRepository(this._streamFactory);

  final Stream<List<RainReport>> Function(double lat, double lng) _streamFactory;

  @override
  Stream<List<RainReport>> watchActiveReports({
    required double centerLat,
    required double centerLng,
    double radiusMeters = 10000,
  }) {
    return _streamFactory(centerLat, centerLng);
  }
}
