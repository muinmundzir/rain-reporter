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
