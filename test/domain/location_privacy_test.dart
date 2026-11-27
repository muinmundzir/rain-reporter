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

  test('encodeGeohash at precision 4 matches known Bandung-area cells', () {
    expect(LocationPrivacy.encodeGeohash(-6.200000, 106.816666, precision: 4), 'qqgu');
    expect(LocationPrivacy.encodeGeohash(-6.917500, 107.619100, precision: 4), 'qqu8');
  });

  test('geohashCellBounds returns a box that contains the point that encoded to it', () {
    final lat = -6.9175;
    final lng = 107.6191;
    final cell = LocationPrivacy.encodeGeohash(lat, lng, precision: 4);
    final b = LocationPrivacy.geohashCellBounds(cell);
    expect(b.minLat, lessThanOrEqualTo(lat));
    expect(b.maxLat, greaterThanOrEqualTo(lat));
    expect(b.minLng, lessThanOrEqualTo(lng));
    expect(b.maxLng, greaterThanOrEqualTo(lng));
    // A cell is small: a 4-char cell is at most a few tens of kilometres.
    expect((b.maxLat - b.minLat) * 111000, lessThan(50000));
    expect((b.maxLng - b.minLng) * 111000, lessThan(50000));
  });

  test('watchCells returns 9 distinct coarse cells that include the center cell', () {
    final lat = -6.9175;
    final lng = 107.6191;
    final cells = LocationPrivacy.watchCells(lat, lng, precision: 4);
    final unique = cells.toSet();
    expect(cells.length, 9);
    expect(unique.length, 9);
    expect(
      unique,
      contains(LocationPrivacy.encodeGeohash(lat, lng, precision: 4)),
    );
    // Every returned cell is a 4-char geohash.
    for (final c in cells) {
      expect(c.length, 4);
    }
  });

  test('watchCells neighborhood covers the center point', () {
    final lat = -6.2;
    final lng = 106.8166;
    final cells = LocationPrivacy.watchCells(lat, lng, precision: 4);
    // The center point must lie inside at least one of the 9 cells' bounds.
    final covers = cells.any((c) {
      final b = LocationPrivacy.geohashCellBounds(c);
      return b.minLat <= lat && lat <= b.maxLat && b.minLng <= lng && lng <= b.maxLng;
    });
    expect(covers, isTrue);
  });
}
