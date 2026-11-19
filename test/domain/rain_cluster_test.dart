import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rain_reporter/domain/location_privacy.dart';
import 'package:rain_reporter/domain/rain_cluster.dart';
import 'package:rain_reporter/domain/rain_intensity.dart';
import 'package:rain_reporter/domain/rain_report.dart';

RainReport _makeReport({
  required String id,
  required double lat,
  required double lng,
  RainIntensity intensity = RainIntensity.moderate,
  DateTime? createdAt,
  String? note,
}) {
  return RainReport.create(
    id: id,
    uid: 'user-$id',
    intensity: intensity,
    lat: lat,
    lng: lng,
    note: note,
    createdAt: createdAt ?? DateTime.utc(2026, 11, 19, 10, 0),
  );
}

void main() {
  group('RainClusterer', () {
    test('returns empty list when reports is empty', () {
      expect(RainClusterer.cluster(const []), isEmpty);
    });

    test('creates single-pin cluster with baseRadiusMeters (300m) for one report', () {
      final report = _makeReport(
        id: 'r1',
        lat: -6.2000,
        lng: 106.8166,
        intensity: RainIntensity.heavy,
      );

      final clusters = RainClusterer.cluster([report]);

      expect(clusters, hasLength(1));
      final cluster = clusters.single;
      expect(cluster.centerLat, equals(-6.2000));
      expect(cluster.centerLng, equals(106.8166));
      expect(cluster.radiusMeters, equals(300));
      expect(cluster.strongestIntensity, equals(RainIntensity.heavy));
      expect(cluster.isCluster, isFalse);
      expect(cluster.reports, equals([report]));
    });

    test('merges two reports within 600m into one cluster with combined radius, strongest intensity, and newest-first order', () {
      final older = _makeReport(
        id: 'r1',
        lat: -6.2000,
        lng: 106.8166,
        intensity: RainIntensity.light,
        createdAt: DateTime.utc(2026, 11, 19, 10, 0),
      );
      // ~445m south (within 600m merge threshold)
      final newer = _makeReport(
        id: 'r2',
        lat: -6.2040,
        lng: 106.8166,
        intensity: RainIntensity.storm,
        createdAt: DateTime.utc(2026, 11, 19, 10, 5),
      );

      final clusters = RainClusterer.cluster([older, newer]);

      expect(clusters, hasLength(1));
      final cluster = clusters.single;
      expect(cluster.isCluster, isTrue);
      expect(cluster.strongestIntensity, equals(RainIntensity.storm));
      expect(cluster.reports.map((r) => r.id).toList(), equals(['r2', 'r1']));
      expect(cluster.centerLat, closeTo(-6.2020, 1e-6));
      expect(cluster.centerLng, closeTo(106.8166, 1e-6));

      final distToCenter = LocationPrivacy.distanceMeters(
        cluster.centerLat,
        cluster.centerLng,
        older.lat,
        older.lng,
      );
      expect(cluster.radiusMeters, closeTo(distToCenter + 300, 1e-3));
      expect(cluster.radiusMeters, greaterThan(500));
    });

    test('grows radius for co-located reports (0m apart) using baseRadiusMeters * sqrt(N)', () {
      final r1 = _makeReport(id: 'r1', lat: -6.2000, lng: 106.8166);
      final r2 = _makeReport(id: 'r2', lat: -6.2000, lng: 106.8166);

      final clusters = RainClusterer.cluster([r1, r2]);

      expect(clusters, hasLength(1));
      expect(clusters.single.isCluster, isTrue);
      expect(clusters.single.radiusMeters, closeTo(300 * sqrt(2), 1e-6));
    });

    test('merges transitive chain (A-B <= 600m, B-C <= 600m, A-C > 600m) into one cluster covering all pins', () {
      final a = _makeReport(id: 'a', lat: -6.2000, lng: 106.8166);
      // ~445m south of A
      final b = _makeReport(id: 'b', lat: -6.2040, lng: 106.8166);
      // ~445m south of B (~890m south of A > 600m)
      final c = _makeReport(id: 'c', lat: -6.2080, lng: 106.8166);

      final clusters = RainClusterer.cluster([a, b, c]);

      expect(clusters, hasLength(1));
      final cluster = clusters.single;
      expect(cluster.reports, hasLength(3));
      for (final r in [a, b, c]) {
        final dist = LocationPrivacy.distanceMeters(
          cluster.centerLat,
          cluster.centerLng,
          r.lat,
          r.lng,
        );
        expect(cluster.radiusMeters, greaterThanOrEqualTo(dist + 300 - 1e-6));
      }
    });

    test('keeps reports more than 600m apart in separate clusters', () {
      final north = _makeReport(id: 'n', lat: -6.2000, lng: 106.8166);
      // ~1.1km south (> 600m)
      final south = _makeReport(id: 's', lat: -6.2100, lng: 106.8166);

      final clusters = RainClusterer.cluster([north, south]);

      expect(clusters, hasLength(2));
      expect(clusters.every((c) => !c.isCluster), isTrue);
      expect(clusters.every((c) => c.radiusMeters == 300), isTrue);
    });
  });
}
