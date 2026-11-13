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
