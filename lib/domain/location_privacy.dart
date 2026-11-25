import 'dart:math';
import 'rain_intensity.dart';
import 'rain_report.dart';

class LocationPrivacy {
  static const double _earthRadiusMeters = 6371000.0;
  static const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

  /// Displaces [lat]/[lng] by a random distance in [100m, 200m].
  static ({double lat, double lng}) fuzzCoordinate({
    required double lat,
    required double lng,
    Random? random,
  }) {
    final rng = random ?? Random.secure();
    // Uniform radius in [100, 200] meters
    final distanceMeters = 100.0 + rng.nextDouble() * 100.0;
    final bearingRadians = rng.nextDouble() * 2 * pi;

    final latRad = lat * pi / 180.0;
    final lngRad = lng * pi / 180.0;
    final angularDistance = distanceMeters / _earthRadiusMeters;

    final newLatRad = asin(
      sin(latRad) * cos(angularDistance) +
          cos(latRad) * sin(angularDistance) * cos(bearingRadians),
    );
    final newLngRad = lngRad +
        atan2(
          sin(bearingRadians) * sin(angularDistance) * cos(latRad),
          cos(angularDistance) - sin(latRad) * sin(newLatRad),
        );

    final newLat = (newLatRad * 180.0 / pi).clamp(-90.0, 90.0);
    var newLng = newLngRad * 180.0 / pi;
    if (newLng > 180.0) newLng -= 360.0;
    if (newLng < -180.0) newLng += 360.0;

    return (lat: newLat, lng: newLng);
  }

  /// Haversine distance in meters between two coordinates.
  static double distanceMeters(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLng = (lng2 - lng1) * pi / 180.0;
    final rLat1 = lat1 * pi / 180.0;
    final rLat2 = lat2 * pi / 180.0;

    final a = pow(sin(dLat / 2), 2) +
        cos(rLat1) * cos(rLat2) * pow(sin(dLng / 2), 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return _earthRadiusMeters * c;
  }

  /// Standard base32 geohash encoder.
  static String encodeGeohash(
    double lat,
    double lng, {
    int precision = 7,
  }) {
    var minLat = -90.0, maxLat = 90.0;
    var minLng = -180.0, maxLng = 180.0;
    var isEven = true;
    var bit = 0;
    var ch = 0;
    final buffer = StringBuffer();

    while (buffer.length < precision) {
      if (isEven) {
        final mid = (minLng + maxLng) / 2;
        if (lng >= mid) {
          ch |= (1 << (4 - bit));
          minLng = mid;
        } else {
          maxLng = mid;
        }
      } else {
        final mid = (minLat + maxLat) / 2;
        if (lat >= mid) {
          ch |= (1 << (4 - bit));
          minLat = mid;
        } else {
          maxLat = mid;
        }
      }
      isEven = !isEven;
      if (bit < 4) {
        bit++;
      } else {
        buffer.write(_base32[ch]);
        bit = 0;
        ch = 0;
      }
    }
    return buffer.toString();
  }

  /// Returns active non-stopped rain reports that have not expired at [now]
  /// and have not been superseded by a newer `'stopped'` report within [stoppedRadiusMeters].
  static List<RainReport> filterActiveReports(
    Iterable<RainReport> reports, {
    required DateTime now,
    double stoppedRadiusMeters = 300,
  }) {
    final unexpired = reports.where((r) => r.isActiveAt(now)).toList();
    final stoppedReports = unexpired
        .where((r) => r.intensity == RainIntensity.stopped || r.stoppedCount >= 1)
        .toList();

    return unexpired.where((report) {
      if (report.intensity == RainIntensity.stopped) return false;
      if (report.stoppedCount >= 1) return false;

      final supersededByStopped = stoppedReports.any((stopped) {
        if (!stopped.createdAt.isAfter(report.createdAt)) return false;
        final dist = distanceMeters(
          report.lat,
          report.lng,
          stopped.lat,
          stopped.lng,
        );
        return dist <= stoppedRadiusMeters;
      });
      return !supersededByStopped;
    }).toList();
  }
}
