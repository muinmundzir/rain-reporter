import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:rain_reporter/data/auth_service.dart';
import 'package:rain_reporter/data/rain_report_repository.dart';
import 'package:rain_reporter/domain/rain_intensity.dart';
import 'package:rain_reporter/domain/rain_report.dart';
import 'package:rain_reporter/main.dart';

class _CountingRepository extends InMemoryRainReportRepository {
  int watchCalls = 0;
  double? lastSubmittedLat;
  double? lastSubmittedLng;

  @override
  Stream<List<RainReport>> watchActiveReports({
    required double centerLat,
    required double centerLng,
    double radiusMeters = 10000,
  }) {
    watchCalls++;
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
}
