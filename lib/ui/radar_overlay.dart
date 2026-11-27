import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

/// How a radar tile URL should be wired into a [RasterSource].
enum RadarSourceKind {
  /// A `mapbox://` tileset or a TileJSON `.json` document — passed to `url`.
  url,

  /// An XYZ `https://…/{z}/{x}/{y}…` template — passed to `tiles`.
  tiles,
}

/// Builds a Mapbox **raster weather-radar** source + layer that renders
/// *behind* the crowd-sourced rain zones and pins.
///
/// The radar tile source is supplied at **build time** so the feature stays
/// opt-in and the app never ships a guessed/broken tile URL:
///
/// ```sh
/// flutter build apk --dart-define RADAR_TILES="https://…/{z}/{x}/{y}.png"
/// flutter build apk --dart-define RADAR_TILES="mapbox://my-radar-tileset"
/// ```
///
/// Optional build-time knobs:
/// - `RADAR_TILE_SIZE` (int, default 256)
/// - `RADAR_OPACITY`   (double 0..1, default 0.6)
///
/// When `RADAR_TILES` is unset the overlay is disabled: [hasSource] is false,
/// nothing is added to the map, and the UI shows a "how to enable" hint. The
/// app degrades gracefully — no crash, no fake data.
final class RadarConfig {
  RadarConfig._();

  /// Radar tile source, e.g. an XYZ template, a `mapbox://` tileset, or a
  /// TileJSON `.json` URL. Read from the `RADAR_TILES` build-time define
  /// (empty when unset).
  static const String tiles = String.fromEnvironment('RADAR_TILES');

  /// Zoom bounds in which the radar raster is meaningful.
  static const double minZoom = 3.0;
  static const double maxZoom = 14.0;

  /// Default raster opacity for the overlay.
  static const double _defaultOpacity = 0.6;

  /// True when a radar tile source was configured at build time.
  static bool get hasSource {
    return tiles.trim().isNotEmpty;
  }

  /// Raster tile size in pixels (falls back to 256 when unset or invalid).
  static int get effectiveTileSize {
    final value = int.fromEnvironment('RADAR_TILE_SIZE');
    return value > 0 ? value : 256;
  }

  /// Raster opacity, clamped to (0, 1]. Falls back to [defaultOpacity].
  static double get opacity {
    final parsed = double.tryParse(String.fromEnvironment('RADAR_OPACITY'));
    if (parsed == null || parsed <= 0 || parsed > 1) return _defaultOpacity;
    return parsed;
  }

  /// Decide whether [url] should be passed to `RasterSource.url` (a
  /// `mapbox://` tileset or TileJSON document) or to `RasterSource.tiles`
  /// (an XYZ `https://…/{z}/{x}/{y}…` template).
  static RadarSourceKind classifySource(String? url) {
    final value = url?.trim() ?? '';
    if (value.isEmpty) return RadarSourceKind.url;
    if (value.startsWith('mapbox://')) return RadarSourceKind.url;
    if (value.contains('{z}') ||
        value.contains('{x}') ||
        value.contains('{y}')) {
      return RadarSourceKind.tiles;
    }
    return RadarSourceKind.url;
  }

  /// Build the raster source that backs the radar layer.
  static RasterSource buildSource(String id, {String? url}) {
    final source = url ?? tiles;
    final tileSize = effectiveTileSize;
    if (classifySource(source) == RadarSourceKind.tiles) {
      return RasterSource(
        id: id,
        tiles: [source],
        tileSize: tileSize.toDouble(),
        minzoom: minZoom,
        maxzoom: maxZoom,
      );
    }
    return RasterSource(
      id: id,
      url: source,
      tileSize: tileSize.toDouble(),
      minzoom: minZoom,
      maxzoom: maxZoom,
    );
  }

  /// Build the radar layer. It sits in the [LayerSlot.BOTTOM] slot so it
  /// renders above the base map but *below* the rain-zone layers
  /// ([LayerSlot.MIDDLE]) and the annotation/pin layer, i.e. behind the
  /// crowd pins.
  static RasterLayer buildLayer(String id, String sourceId) {
    return RasterLayer(
      id: id,
      sourceId: sourceId,
      slot: LayerSlot.BOTTOM,
      rasterOpacity: opacity,
      rasterFadeDuration: 0,
    );
  }
}
