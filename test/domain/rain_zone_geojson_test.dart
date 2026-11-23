import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rain_reporter/domain/location_privacy.dart';
import 'package:rain_reporter/domain/rain_cluster.dart';
import 'package:rain_reporter/domain/rain_intensity.dart';
import 'package:rain_reporter/domain/rain_report.dart';
import 'package:rain_reporter/domain/rain_zone_geojson.dart';

RainCluster _singleCluster({
  required String id,
  required double lat,
  required double lng,
  RainIntensity intensity = RainIntensity.heavy,
  double radiusMeters = 300,
}) {
  final report = RainReport.create(
    id: id,
    uid: 'u-$id',
    intensity: intensity,
    lat: lat,
    lng: lng,
    createdAt: DateTime.utc(2026, 11, 23, 10, 0),
  );
  return RainCluster(
    centerLat: lat,
    centerLng: lng,
    radiusMeters: radiusMeters,
    strongestIntensity: intensity,
    reports: [report],
  );
}

void main() {
  group('RainZoneGeoJson', () {
    test('returns empty FeatureCollection when clusters is empty', () {
      final raw = RainZoneGeoJson.buildFeatureCollection(const []);
      final decoded = jsonDecode(raw) as Map<String, dynamic>;

      expect(decoded['type'], equals('FeatureCollection'));
      expect(decoded['features'], isEmpty);
    });

    test('builds closed 64-segment polygon at accurate radiusMeters from cluster center', () {
      final cluster = _singleCluster(
        id: 'c1',
        lat: -6.9175,
        lng: 107.6191,
        intensity: RainIntensity.heavy,
        radiusMeters: 300,
      );

      final raw = RainZoneGeoJson.buildFeatureCollection([cluster]);
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final features = decoded['features'] as List<dynamic>;
      expect(features, hasLength(1));

      final feature = features.single as Map<String, dynamic>;
      expect(feature['type'], equals('Feature'));

      final geometry = feature['geometry'] as Map<String, dynamic>;
      expect(geometry['type'], equals('Polygon'));

      final coordinates = geometry['coordinates'] as List<dynamic>;
      final ring = coordinates.single as List<dynamic>;
      expect(ring, hasLength(65));
      expect(ring.first, equals(ring.last));

      for (final pt in ring) {
        final pair = pt as List<dynamic>;
        final lng = (pair[0] as num).toDouble();
        final lat = (pair[1] as num).toDouble();
        final dist = LocationPrivacy.distanceMeters(
          cluster.centerLat,
          cluster.centerLng,
          lat,
          lng,
        );
        expect(dist, closeTo(300, 3.0));
      }

      final props = feature['properties'] as Map<String, dynamic>;
      expect(
        props['fillColor'],
        equals(RainZoneGeoJson.fillColorHex(RainIntensity.heavy)),
      );
      expect(
        props['borderColor'],
        equals(RainZoneGeoJson.borderColorHex(RainIntensity.heavy)),
      );
    });

    test('builds one feature per cluster with distinct intensity colors', () {
      final c1 = _singleCluster(
        id: 'c1',
        lat: -6.9175,
        lng: 107.6191,
        intensity: RainIntensity.light,
      );
      final c2 = _singleCluster(
        id: 'c2',
        lat: -6.9000,
        lng: 107.6000,
        intensity: RainIntensity.storm,
        radiusMeters: 500,
      );

      final decoded = jsonDecode(RainZoneGeoJson.buildFeatureCollection([c1, c2]))
          as Map<String, dynamic>;
      final features = decoded['features'] as List<dynamic>;
      expect(features, hasLength(2));

      final p0 = (features[0] as Map<String, dynamic>)['properties']
          as Map<String, dynamic>;
      final p1 = (features[1] as Map<String, dynamic>)['properties']
          as Map<String, dynamic>;
      expect(p0['fillColor'], equals('#03A9F4'));
      expect(p1['fillColor'], equals('#D32F2F'));
    });
  });
}
