import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rain_reporter/domain/rain_intensity.dart';
import 'package:rain_reporter/ui/mapbox_marker_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MapboxMarkerIcons', () {
    test('renders valid PNG bytes for single pin and caches repeated calls', () async {
      final icons = MapboxMarkerIcons();

      final first = await icons.getPinIcon(RainIntensity.heavy, Colors.deepPurple);
      final second = await icons.getPinIcon(RainIntensity.heavy, Colors.deepPurple);

      expect(first.length, greaterThan(8));
      expect(first.sublist(0, 4), equals([137, 80, 78, 71]));
      expect(identical(first, second), isTrue);
    });

    test('renders valid PNG bytes for cluster badge with count and caches by (intensity, count)', () async {
      final icons = MapboxMarkerIcons();

      final badge2 = await icons.getClusterBadgeIcon(
        RainIntensity.storm,
        Colors.red.shade700,
        2,
      );
      final badge2Again = await icons.getClusterBadgeIcon(
        RainIntensity.storm,
        Colors.red.shade700,
        2,
      );
      final badge5 = await icons.getClusterBadgeIcon(
        RainIntensity.storm,
        Colors.red.shade700,
        5,
      );

      expect(badge2.sublist(0, 4), equals([137, 80, 78, 71]));
      expect(identical(badge2, badge2Again), isTrue);
      expect(identical(badge2, badge5), isFalse);
    });
  });
}
