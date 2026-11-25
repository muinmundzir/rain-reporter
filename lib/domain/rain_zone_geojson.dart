import 'dart:convert';
import 'dart:math';

import 'rain_cluster.dart';
import 'rain_intensity.dart';

class RainZoneGeoJson {
  static const double _earthRadiusMeters = 6371000.0;

  static String fillColorHex(RainIntensity intensity) {
    return switch (intensity) {
      RainIntensity.light => '#03A9F4',
      RainIntensity.moderate => '#1976D2',
      RainIntensity.heavy => '#673AB7',
      RainIntensity.storm => '#D32F2F',
      RainIntensity.stopped => '#4CAF50',
    };
  }

  static String borderColorHex(RainIntensity intensity) =>
      fillColorHex(intensity);

  /// Encodes [clusters] as a GeoJSON FeatureCollection of meter-accurate circle
  /// polygons with [segments] vertices per ring.
  static String buildFeatureCollection(
    List<RainCluster> clusters, {
    int segments = 64,
  }) {
    final features = <Map<String, dynamic>>[];
    for (var i = 0; i < clusters.length; i++) {
      final cluster = clusters[i];
      final ring = _buildCircleRing(
        centerLat: cluster.centerLat,
        centerLng: cluster.centerLng,
        radiusMeters: cluster.radiusMeters,
        segments: segments,
      );
      features.add({
        'type': 'Feature',
        'properties': {
          'clusterIndex': i,
          'fillColor': fillColorHex(cluster.strongestIntensity),
          'borderColor': borderColorHex(cluster.strongestIntensity),
        },
        'geometry': {
          'type': 'Polygon',
          'coordinates': [ring],
        },
      });
    }

    return jsonEncode({
      'type': 'FeatureCollection',
      'features': features,
    });
  }

  static List<List<double>> _buildCircleRing({
    required double centerLat,
    required double centerLng,
    required double radiusMeters,
    required int segments,
  }) {
    final latRad = centerLat * pi / 180.0;
    final lngRad = centerLng * pi / 180.0;
    final angularDist = radiusMeters / _earthRadiusMeters;

    final ring = <List<double>>[];
    for (var i = 0; i < segments; i++) {
      final bearing = (2 * pi * i) / segments;
      final newLatRad = asin(
        sin(latRad) * cos(angularDist) +
            cos(latRad) * sin(angularDist) * cos(bearing),
      );
      final newLngRad = lngRad +
          atan2(
            sin(bearing) * sin(angularDist) * cos(latRad),
            cos(angularDist) - sin(latRad) * sin(newLatRad),
          );

      final lat = (newLatRad * 180.0 / pi).clamp(-90.0, 90.0);
      var lng = newLngRad * 180.0 / pi;
      if (lng > 180.0) lng -= 360.0;
      if (lng < -180.0) lng += 360.0;
      ring.add([lng, lat]);
    }
    if (ring.isNotEmpty) {
      ring.add([ring.first[0], ring.first[1]]);
    }
    return ring;
  }
}
