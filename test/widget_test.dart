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
import 'package:rain_reporter/ui/map_screen.dart';

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
}
