import 'package:flutter_test/flutter_test.dart';
import 'package:rain_reporter/data/rain_report_repository.dart';
import 'package:rain_reporter/domain/rain_intensity.dart';

void main() {
  late DateTime currentTime;
  late InMemoryRainReportRepository repo;

  setUp(() {
    currentTime = DateTime.utc(2026, 11, 13, 10, 0);
    repo = InMemoryRainReportRepository(clock: () => currentTime);
  });

  test('submitReport uses exact coordinates and emits active report', () async {
    final report = await repo.submitReport(
      uid: 'user-1',
      intensity: RainIntensity.heavy,
      rawLat: -6.2000,
      rawLng: 106.8166,
      note: 'Pouring near station',
    );

    expect(report.lat, equals(-6.2000));
    expect(report.lng, equals(106.8166));

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
