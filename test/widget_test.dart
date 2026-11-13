import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rain_reporter/data/auth_service.dart';
import 'package:rain_reporter/data/rain_report_repository.dart';
import 'package:rain_reporter/domain/rain_report.dart';
import 'package:rain_reporter/main.dart';

class _CountingRepository extends InMemoryRainReportRepository {
  int watchCalls = 0;

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
}
