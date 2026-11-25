import 'dart:math';

import 'location_privacy.dart';
import 'rain_intensity.dart';
import 'rain_report.dart';

class RainCluster {
  RainCluster({
    required this.centerLat,
    required this.centerLng,
    required this.radiusMeters,
    required this.strongestIntensity,
    required List<RainReport> reports,
  }) : reports = List<RainReport>.unmodifiable(reports);

  final double centerLat;
  final double centerLng;
  final double radiusMeters;
  final RainIntensity strongestIntensity;
  final List<RainReport> reports;

  bool get isCluster => reports.length > 1;
}

class RainClusterer {
  static int _severityRank(RainIntensity intensity) {
    return switch (intensity) {
      RainIntensity.stopped => 0,
      RainIntensity.light => 1,
      RainIntensity.moderate => 2,
      RainIntensity.heavy => 3,
      RainIntensity.storm => 4,
    };
  }

  /// Groups active [reports] whose [baseRadiusMeters] zones overlap (distance <=
  /// `baseRadiusMeters * 2`) into combined [RainCluster]s.
  static List<RainCluster> cluster(
    List<RainReport> reports, {
    double baseRadiusMeters = 300,
  }) {
    if (reports.isEmpty) return const [];

    final n = reports.length;
    final parent = List<int>.generate(n, (i) => i);

    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
      }
      return x;
    }

    void union(int a, int b) {
      final ra = find(a);
      final rb = find(b);
      if (ra != rb) {
        parent[rb] = ra;
      }
    }

    final mergeDistanceMeters = baseRadiusMeters * 2;
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        final dist = LocationPrivacy.distanceMeters(
          reports[i].lat,
          reports[i].lng,
          reports[j].lat,
          reports[j].lng,
        );
        if (dist <= mergeDistanceMeters) {
          union(i, j);
        }
      }
    }

    final groups = <int, List<RainReport>>{};
    for (var i = 0; i < n; i++) {
      groups.putIfAbsent(find(i), () => []).add(reports[i]);
    }

    return groups.values.map((group) {
      final sorted = List<RainReport>.of(group)
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      if (sorted.length == 1) {
        final single = sorted.first;
        return RainCluster(
          centerLat: single.lat,
          centerLng: single.lng,
          radiusMeters: baseRadiusMeters,
          strongestIntensity: single.intensity,
          reports: sorted,
        );
      }

      var sumLat = 0.0;
      var sumLng = 0.0;
      var strongest = sorted.first.intensity;
      for (final r in sorted) {
        sumLat += r.lat;
        sumLng += r.lng;
        if (_severityRank(r.intensity) > _severityRank(strongest)) {
          strongest = r.intensity;
        }
      }
      final centerLat = sumLat / sorted.length;
      final centerLng = sumLng / sorted.length;

      var maxDistFromCenter = 0.0;
      for (final r in sorted) {
        final dist = LocationPrivacy.distanceMeters(
          centerLat,
          centerLng,
          r.lat,
          r.lng,
        );
        if (dist > maxDistFromCenter) {
          maxDistFromCenter = dist;
        }
      }

      final combinedRadius = max(
        maxDistFromCenter + baseRadiusMeters,
        baseRadiusMeters * sqrt(sorted.length),
      );

      return RainCluster(
        centerLat: centerLat,
        centerLng: centerLng,
        radiusMeters: combinedRadius,
        strongestIntensity: strongest,
        reports: sorted,
      );
    }).toList();
  }
}
