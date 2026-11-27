import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:rain_reporter/data/auth_service.dart';
import 'package:rain_reporter/data/rain_report_repository.dart';
import 'package:rain_reporter/ui/map_screen.dart';
import 'package:rain_reporter/ui/radar_overlay.dart';

void main() {
  group('RadarConfig', () {
    test('is disabled by default (no build-time RADAR_TILES in tests)', () {
      expect(RadarConfig.hasSource, isFalse);
    });

    test('exposes the default raster opacity and tile size', () {
      expect(RadarConfig.opacity, closeTo(0.6, 1e-9));
      expect(RadarConfig.effectiveTileSize, 256);
    });

    test('classifies mapbox:// and .json sources as url', () {
      expect(RadarConfig.classifySource('mapbox://my-radar-tileset'),
          RadarSourceKind.url);
      expect(RadarConfig.classifySource('https://tiles.example/radar.json'),
          RadarSourceKind.url);
    });

    test('classifies XYZ templates as tiles', () {
      expect(RadarConfig.classifySource('https://tiles.example/{z}/{x}/{y}.png'),
          RadarSourceKind.tiles);
      expect(RadarConfig.classifySource('https://tiles.example/{z}/{x}/{y}'),
          RadarSourceKind.tiles);
    });

    test('buildLayer sits in the bottom slot, behind rain zones and pins', () {
      final layer = RadarConfig.buildLayer('radar-layer', 'radar-source');
      expect(layer.id, 'radar-layer');
      expect(layer.sourceId, 'radar-source');
      expect(layer.slot, LayerSlot.BOTTOM);
      expect(layer.rasterOpacity, closeTo(0.6, 1e-9));
    });

    test('buildSource returns a raster source with the given id', () {
      final source = RadarConfig.buildSource(
        'radar-source',
        url: 'https://tiles.example/{z}/{x}/{y}.png',
      );
      expect(source.id, 'radar-source');
      expect(source.getType(), 'raster');
    });
  });

  group('MapScreen radar toggle', () {
    testWidgets('shows an enable hint when no radar source is configured',
        (tester) async {
      final repo = InMemoryRainReportRepository();
      final auth = FakeAuthService(uid: 'test-uid');

      await tester.pumpWidget(
        MaterialApp(
          home: MapScreen(
            authService: auth,
            repository: repo,
            useNativeMapView: false,
            locationProvider: () async => (lat: -6.2000, lng: 106.8166),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('radar_toggle')), findsOneWidget);

      await tester.tap(find.byKey(const Key('radar_toggle')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Radar overlay is not configured'),
        findsOneWidget,
      );
    });
  });
}
