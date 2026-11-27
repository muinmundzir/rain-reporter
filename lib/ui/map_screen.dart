import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../data/auth_service.dart';
import '../data/notification_service.dart';
import '../data/rain_report_repository.dart';
import '../domain/location_privacy.dart';
import '../domain/rain_cluster.dart';
import '../domain/rain_intensity.dart';
import '../domain/rain_report.dart';
import '../domain/rain_zone_geojson.dart';
import 'cluster_detail_bottom_sheet.dart';
import 'mapbox_marker_icons.dart';
import 'pin_detail_bottom_sheet.dart';
import 'radar_overlay.dart';
import 'report_bottom_sheet.dart';

/// Lightweight controller exposed only when `useNativeMapView == false`
/// so headless `flutter test` suites can inspect camera state and simulate pans.
class MapTestController {
  double centerLat = -6.917500;
  double centerLng = 107.619100;
  double zoom = 12.0;
  bool hasUserLocation = false;
  List<RainCluster> clusters = const [];

  void Function(double lat, double lng, double zoom)? _onSimulatedMove;

  void simulateCameraMove(double lat, double lng, double newZoom) {
    centerLat = lat;
    centerLng = lng;
    zoom = newZoom;
    _onSimulatedMove?.call(lat, lng, newZoom);
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.authService,
    required this.repository,
    this.notificationService = const NoOpNotificationService(),
    this.locationProvider,
    this.useNativeMapView = true,
    this.isOfflineMode = false,
    this.clock,
    this.panDebounceDuration = const Duration(milliseconds: 400),
    this.panRefreshThresholdMeters = 500,
    this.stopVoteMaxDistanceMeters = 500,
    this.mapTestController,
  });

  final AuthService authService;
  final RainReportRepository repository;
  final NotificationService notificationService;
  final Future<({double lat, double lng})?> Function()? locationProvider;
  final bool useNativeMapView;
  final bool isOfflineMode;
  final DateTime Function()? clock;
  final Duration panDebounceDuration;
  final double panRefreshThresholdMeters;
  final double stopVoteMaxDistanceMeters;
  final MapTestController? mapTestController;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const ({double lat, double lng}) _defaultCenter = (
    lat: -6.917500,
    lng: 107.619100,
  );
  static const double _defaultOverviewZoom = 12.0;
  static const double _userFocusZoom = 16.0;

  static const String _rainZonesSourceId = 'rain-zones-source';
  static const String _rainZonesFillLayerId = 'rain-zones-fill';
  static const String _rainZonesLineLayerId = 'rain-zones-line';

  static const String _radarSourceId = 'rain-radar-source';
  static const String _radarLayerId = 'rain-radar-layer';

  ({double lat, double lng}) _cameraCenter = _defaultCenter;
  ({double lat, double lng}) _lastQueriedCenter = _defaultCenter;
  ({double lat, double lng})? _userLocation;
  ({double lat, double lng})? _pendingNotificationTarget;
  bool _hasNotificationFocus = false;
  late Stream<List<RainReport>> _reportsStream;
  List<RainReport> _latestReports = const <RainReport>[];
  List<RainCluster> _latestClusters = const <RainCluster>[];
  Timer? _panDebounceTimer;
  bool _isOpeningReportSheet = false;

  MapboxMap? _mapboxMap;
  PointAnnotationManager? _pointAnnotationManager;
  Cancelable? _annotationTapCancelable;
  bool _styleLoaded = false;
  int _annotationSyncGeneration = 0;
  String? _lastSyncedFingerprint;
  final Map<String, RainCluster> _annotationClusters = {};
  final MapboxMarkerIcons _markerIcons = MapboxMarkerIcons();
  bool _radarOn = false;

  @override
  void initState() {
    super.initState();
    // Show the radar overlay by default when a source was configured at build
    // time; the AppBar toggle can turn it off on demand.
    _radarOn = RadarConfig.hasSource;
    widget.mapTestController?._onSimulatedMove = (lat, lng, _) {
      _onCameraCenterChanged(lat, lng);
    };
    _reportsStream = widget.repository.watchActiveReports(
      centerLat: _lastQueriedCenter.lat,
      centerLng: _lastQueriedCenter.lng,
    );
    unawaited(
      widget.notificationService.initialize(
        onNotificationTap: _handleNotificationTap,
      ),
    );
    _initLocation();
  }

  @override
  void dispose() {
    _panDebounceTimer?.cancel();
    _annotationTapCancelable?.cancel();
    widget.notificationService.dispose();
    widget.mapTestController?._onSimulatedMove = null;
    super.dispose();
  }

  void _handleNotificationTap(double lat, double lng) {
    if (!mounted) return;
    _hasNotificationFocus = true;
    _pendingNotificationTarget = (lat: lat, lng: lng);
    _refreshReportsForCenter((lat: lat, lng: lng));
    _animateMapTo(lat, lng, _userFocusZoom);
    if (_mapboxMap != null) {
      _pendingNotificationTarget = null;
    }
  }

  void _refreshReportsForCenter(({double lat, double lng}) newCenter) {
    if (newCenter.lat == _lastQueriedCenter.lat &&
        newCenter.lng == _lastQueriedCenter.lng) {
      return;
    }
    _panDebounceTimer?.cancel();
    setState(() {
      _cameraCenter = newCenter;
      _lastQueriedCenter = newCenter;
      _reportsStream = widget.repository.watchActiveReports(
        centerLat: _lastQueriedCenter.lat,
        centerLng: _lastQueriedCenter.lng,
      );
    });
  }

  void _onCameraCenterChanged(double lat, double lng) {
    _cameraCenter = (lat: lat, lng: lng);
    _panDebounceTimer?.cancel();
    _panDebounceTimer = Timer(widget.panDebounceDuration, () {
      if (!mounted) return;
      final movedMeters = LocationPrivacy.distanceMeters(
        _lastQueriedCenter.lat,
        _lastQueriedCenter.lng,
        _cameraCenter.lat,
        _cameraCenter.lng,
      );
      if (movedMeters > widget.panRefreshThresholdMeters) {
        _refreshReportsForCenter(_cameraCenter);
      }
    });
  }

  Future<({double lat, double lng})?> _fetchDeviceLocation() async {
    try {
      return await (widget.locationProvider ?? _resolveDeviceLocation)();
    } catch (_) {
      return null;
    }
  }

  Future<void> _initLocation() async {
    final loc = await _fetchDeviceLocation();
    if (!mounted || loc == null) return;
    setState(() {
      _userLocation = loc;
    });
    widget.mapTestController?.hasUserLocation = true;
    unawaited(_enableLocationPuck());
    unawaited(
      widget.notificationService.updateLocationCell(
        lat: loc.lat,
        lng: loc.lng,
      ),
    );
    if (!_hasNotificationFocus) {
      _refreshReportsForCenter(loc);
      _animateMapTo(loc.lat, loc.lng, _userFocusZoom);
    }
  }

  void _animateMapTo(double lat, double lng, double zoom) {
    _cameraCenter = (lat: lat, lng: lng);
    if (widget.mapTestController != null) {
      widget.mapTestController!.centerLat = lat;
      widget.mapTestController!.centerLng = lng;
      widget.mapTestController!.zoom = zoom;
    }
    _mapboxMap?.easeTo(
      CameraOptions(
        center: Point(coordinates: Position(lng, lat)),
        zoom: zoom,
      ),
      MapAnimationOptions(duration: 550),
    );
  }

  Future<void> _recenterToUserLocation() async {
    final loc = await _fetchDeviceLocation();
    if (!mounted) return;
    if (loc == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Location access is required to center map.'),
        ),
      );
      return;
    }
    setState(() {
      _userLocation = loc;
    });
    widget.mapTestController?.hasUserLocation = true;
    _refreshReportsForCenter(loc);
    _animateMapTo(loc.lat, loc.lng, _userFocusZoom);
    unawaited(_enableLocationPuck());
    unawaited(
      widget.notificationService.updateLocationCell(
        lat: loc.lat,
        lng: loc.lng,
      ),
    );
  }

  Future<({double lat, double lng})?> _resolveDeviceLocation() async {
    final enabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!enabled) return null;

    var permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }
    if (permission == geo.LocationPermission.denied ||
        permission == geo.LocationPermission.deniedForever) {
      return null;
    }

    try {
      final pos = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return (lat: pos.latitude, lng: pos.longitude);
    } catch (_) {
      final lastKnown = await geo.Geolocator.getLastKnownPosition();
      if (lastKnown == null) return null;
      return (lat: lastKnown.latitude, lng: lastKnown.longitude);
    }
  }

  Future<void> _enableLocationPuck() async {
    final mapboxMap = _mapboxMap;
    if (!mounted || mapboxMap == null) return;
    try {
      await mapboxMap.location.updateSettings(
        LocationComponentSettings(
          enabled: true,
          pulsingEnabled: true,
        ),
      );
    } catch (_) {
      // Location puck requires runtime location permission; safe to ignore if denied.
    }
  }

  Future<void> _onMapCreated(MapboxMap mapboxMap) async {
    _mapboxMap = mapboxMap;
    await _enableLocationPuck();
    if (!mounted) return;

    final manager = await mapboxMap.annotations.createPointAnnotationManager();
    if (!mounted) return;
    _pointAnnotationManager = manager;
    _annotationTapCancelable = manager.tapEvents(
      onTap: (PointAnnotation annotation) {
        final cluster = _annotationClusters[annotation.id];
        if (cluster == null || !mounted) return;
        if (cluster.isCluster) {
          _openClusterDetails(cluster);
        } else {
          _openPinDetails(cluster.reports.first);
        }
      },
    );

    final pendingTarget = _pendingNotificationTarget;
    if (pendingTarget != null) {
      _pendingNotificationTarget = null;
      _animateMapTo(pendingTarget.lat, pendingTarget.lng, _userFocusZoom);
    } else if (_userLocation != null) {
      _animateMapTo(_userLocation!.lat, _userLocation!.lng, _userFocusZoom);
    }
    if (_styleLoaded) {
      _lastSyncedFingerprint = null;
      await _syncMapboxLayers(_latestClusters);
    }
  }

  Future<void> _onStyleLoaded(StyleLoadedEventData _) async {
    final mapboxMap = _mapboxMap;
    if (!mounted || mapboxMap == null) return;

    final initialGeoJson = RainZoneGeoJson.buildFeatureCollection(_latestClusters);

    if (!await mapboxMap.styleSourceExists(_rainZonesSourceId)) {
      await mapboxMap.addSource(
        GeoJsonSource(
          id: _rainZonesSourceId,
          data: initialGeoJson,
        ),
      );
    }
    if (!await mapboxMap.styleLayerExists(_rainZonesFillLayerId)) {
      await mapboxMap.addLayer(
        FillLayer(
          id: _rainZonesFillLayerId,
          sourceId: _rainZonesSourceId,
          slot: 'middle',
          fillOpacity: 0.28,
          fillColorExpression: ['get', 'fillColor'],
        ),
      );
    }
    if (!await mapboxMap.styleLayerExists(_rainZonesLineLayerId)) {
      await mapboxMap.addLayer(
        LineLayer(
          id: _rainZonesLineLayerId,
          sourceId: _rainZonesSourceId,
          slot: 'middle',
          lineOpacity: 0.75,
          lineWidth: 2.0,
          lineColorExpression: ['get', 'borderColor'],
        ),
      );
    }

    // Weather-radar raster, rendered *behind* the rain zones and pins.
    // Only when configured at build time; a failed tile load is ignored so
    // the rest of the map keeps working.
    if (RadarConfig.hasSource) {
      try {
        if (!await mapboxMap.styleSourceExists(_radarSourceId)) {
          await mapboxMap.addSource(
            RadarConfig.buildSource(_radarSourceId),
          );
        }
        if (_radarOn && !await mapboxMap.styleLayerExists(_radarLayerId)) {
          await mapboxMap.addLayer(
            RadarConfig.buildLayer(_radarLayerId, _radarSourceId),
          );
        }
      } catch (_) {
        // Radar source failed to load; degrade gracefully (no overlay).
      }
    }

    _styleLoaded = true;
    _lastSyncedFingerprint = null;
    await _syncMapboxLayers(_latestClusters);
  }

  Future<void> _showRadarLayer() async {
    final mapboxMap = _mapboxMap;
    if (!mounted || mapboxMap == null || !RadarConfig.hasSource) return;
    try {
      if (!await mapboxMap.styleSourceExists(_radarSourceId)) {
        await mapboxMap.addSource(
          RadarConfig.buildSource(_radarSourceId),
        );
      }
      if (!await mapboxMap.styleLayerExists(_radarLayerId)) {
        await mapboxMap.addLayer(
          RadarConfig.buildLayer(_radarLayerId, _radarSourceId),
        );
      }
    } catch (_) {
      // Ignore transient / unavailable radar tile errors.
    }
  }

  Future<void> _hideRadarLayer() async {
    final mapboxMap = _mapboxMap;
    if (!mounted || mapboxMap == null) return;
    try {
      if (await mapboxMap.styleLayerExists(_radarLayerId)) {
        await mapboxMap.removeStyleLayer(_radarLayerId);
      }
    } catch (_) {
      // Ignore errors when removing a radar layer that is not present.
    }
  }

  void _toggleRadar() {
    if (!RadarConfig.hasSource) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Radar overlay is not configured. Build with '
            '--dart-define RADAR_TILES=<tile-url> to enable it.',
          ),
        ),
      );
      return;
    }
    final turnOn = !_radarOn;
    setState(() => _radarOn = turnOn);
    if (turnOn) {
      _showRadarLayer();
    } else {
      _hideRadarLayer();
    }
  }

  String _clustersFingerprint(List<RainCluster> clusters) {
    final buffer = StringBuffer();
    for (final c in clusters) {
      buffer
        ..write(c.centerLat.toStringAsFixed(6))
        ..write(',')
        ..write(c.centerLng.toStringAsFixed(6))
        ..write(',')
        ..write(c.radiusMeters.toStringAsFixed(1))
        ..write(',')
        ..write(c.strongestIntensity.wireName)
        ..write(',')
        ..write(c.reports.length)
        ..write(':');
      for (final r in c.reports) {
        buffer
          ..write(r.id)
          ..write('#')
          ..write(r.confirmCount)
          ..write('#')
          ..write(r.stoppedCount)
          ..write(';');
      }
    }
    return buffer.toString();
  }

  Future<void> _syncMapboxLayers(List<RainCluster> clusters) async {
    final mapboxMap = _mapboxMap;
    if (!mounted || mapboxMap == null || !_styleLoaded) return;

    final fingerprint = _clustersFingerprint(clusters);
    if (fingerprint == _lastSyncedFingerprint) return;
    _lastSyncedFingerprint = fingerprint;

    final generation = ++_annotationSyncGeneration;

    final geoJson = RainZoneGeoJson.buildFeatureCollection(clusters);
    try {
      await mapboxMap.setStyleSourceProperty(
        _rainZonesSourceId,
        'data',
        geoJson,
      );
    } catch (_) {
      // Ignore transient style-not-ready errors.
    }

    final manager = _pointAnnotationManager;
    if (manager == null) return;

    final options = <PointAnnotationOptions>[];
    for (final cluster in clusters) {
      final color = _colorForIntensity(cluster.strongestIntensity);
      final image = cluster.isCluster
          ? await _markerIcons.getClusterBadgeIcon(
              cluster.strongestIntensity,
              color,
              cluster.reports.length,
            )
          : await _markerIcons.getPinIcon(
              cluster.strongestIntensity,
              color,
            );
      if (generation != _annotationSyncGeneration || !mounted) return;

      options.add(
        PointAnnotationOptions(
          geometry: Point(
            coordinates: Position(cluster.centerLng, cluster.centerLat),
          ),
          image: image,
          iconSize: 0.6,
          iconAnchor:
              cluster.isCluster ? IconAnchor.CENTER : IconAnchor.BOTTOM,
        ),
      );
    }

    if (generation != _annotationSyncGeneration || !mounted) return;
    try {
      await manager.deleteAll();
      if (generation != _annotationSyncGeneration || !mounted) return;
      _annotationClusters.clear();

      if (options.isEmpty) return;
      final created = await manager.createMulti(options);
      if (generation != _annotationSyncGeneration || !mounted) return;

      for (var i = 0; i < created.length && i < clusters.length; i++) {
        final annotation = created[i];
        if (annotation != null) {
          _annotationClusters[annotation.id] = clusters[i];
        }
      }
    } catch (_) {
      // Reset fingerprint so next stream update retries syncing annotations.
      if (generation == _annotationSyncGeneration) {
        _lastSyncedFingerprint = null;
      }
    }
  }

  Color _colorForIntensity(RainIntensity intensity) {
    return switch (intensity) {
      RainIntensity.light => Colors.lightBlue,
      RainIntensity.moderate => Colors.blue.shade700,
      RainIntensity.heavy => Colors.deepPurple,
      RainIntensity.storm => Colors.red.shade700,
      RainIntensity.stopped => Colors.green,
    };
  }

  Future<void> _openReportSheet() async {
    if (_isOpeningReportSheet) return;
    _isOpeningReportSheet = true;
    try {
      final loc = await _fetchDeviceLocation();
      if (!mounted) return;
      if (loc == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location access is required to report rain.'),
          ),
        );
        return;
      }

      final submission = await showModalBottomSheet<ReportSubmission>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => ReportBottomSheet(
          onSubmit: (value) => Navigator.of(ctx).pop(value),
        ),
      );
      if (submission == null || !mounted) return;

      try {
        final uid = await widget.authService.ensureAnonymousUid();
        final report = await widget.repository.submitReport(
          uid: uid,
          intensity: submission.intensity,
          rawLat: loc.lat,
          rawLng: loc.lng,
          note: submission.note,
        );
        unawaited(
          widget.notificationService.notifyRainReport(report: report),
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rain report submitted!')),
        );
      } on RateLimitException catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not submit report: $e')),
        );
      }
    } finally {
      _isOpeningReportSheet = false;
    }
  }

  Future<void> _openPinDetails(RainReport report) async {
    final now = (widget.clock ?? () => DateTime.now().toUtc())();
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => PinDetailBottomSheet(
        report: report,
        now: now,
        onConfirmStillRaining: () async {
          Navigator.of(ctx).pop();
          await _handleVote(report: report, isStillRaining: true);
        },
        onMarkStopped: () async {
          Navigator.of(ctx).pop();
          await _handleVote(report: report, isStillRaining: false);
        },
      ),
    );
  }

  Future<void> _openClusterDetails(RainCluster cluster) async {
    final now = (widget.clock ?? () => DateTime.now().toUtc())();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => ClusterDetailBottomSheet(
        cluster: cluster,
        now: now,
        onConfirmStillRaining: (report) async {
          Navigator.of(ctx).pop();
          await _handleVote(report: report, isStillRaining: true);
        },
        onMarkStopped: (report) async {
          Navigator.of(ctx).pop();
          await _handleVote(report: report, isStillRaining: false);
        },
      ),
    );
  }

  Future<void> _handleVote({
    required RainReport report,
    required bool isStillRaining,
  }) async {
    if (!isStillRaining) {
      final loc = await _fetchDeviceLocation();
      if (!mounted) return;
      if (loc == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location access is required to mark rain stopped.'),
          ),
        );
        return;
      }
      final dist = LocationPrivacy.distanceMeters(
        loc.lat,
        loc.lng,
        report.lat,
        report.lng,
      );
      if (dist > widget.stopVoteMaxDistanceMeters) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'You must be within ${widget.stopVoteMaxDistanceMeters.round()}m of this pin to mark it stopped.',
            ),
          ),
        );
        return;
      }
    }

    try {
      final uid = await widget.authService.ensureAnonymousUid();
      await widget.repository.voteReport(
        reportId: report.id,
        uid: uid,
        isStillRaining: isStillRaining,
      );
    } on DuplicateVoteException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }

  Widget _buildTestMapSurface(List<RainCluster> clusters) {
    return ColoredBox(
      key: const Key('mapbox_test_surface'),
      color: const Color(0xFFEFF3F6),
      child: Center(
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: [
            if (_userLocation != null)
              const SizedBox(
                key: Key('user_location_marker'),
                width: 14,
                height: 14,
              ),
            for (final cluster in clusters)
              if (!cluster.isCluster)
                GestureDetector(
                  onTap: () => _openPinDetails(cluster.reports.first),
                  child: Icon(
                    Icons.location_on,
                    size: 40,
                    color: _colorForIntensity(cluster.strongestIntensity),
                  ),
                )
              else
                GestureDetector(
                  onTap: () => _openClusterDetails(cluster),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _colorForIntensity(cluster.strongestIntensity),
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${cluster.reports.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<RainReport>>(
      stream: _reportsStream,
      initialData: _latestReports,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          _latestReports = snapshot.data!;
        }
        final reports = _latestReports;
        final clusters = RainClusterer.cluster(reports);
        _latestClusters = clusters;
        widget.mapTestController?.clusters = clusters;

        if (widget.useNativeMapView && _styleLoaded) {
          unawaited(_syncMapboxLayers(clusters));
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('Rain Reporter'),
            actions: [
              IconButton(
                key: const Key('radar_toggle'),
                tooltip: RadarConfig.hasSource
                    ? (_radarOn ? 'Hide radar' : 'Show radar')
                    : 'Radar not configured',
                color: _radarOn && RadarConfig.hasSource
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).hintColor,
                icon: const Icon(Icons.cloud),
                onPressed: _toggleRadar,
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Chip(
                  avatar: const Icon(Icons.cloud, size: 18),
                  label: Text('${reports.length} active nearby'),
                ),
              ),
            ],
          ),
          body: Stack(
            children: [
              if (widget.useNativeMapView)
                MapWidget(
                  key: const ValueKey('mapbox_map_widget'),
                  styleUri: MapboxStyles.STANDARD,
                  viewport: CameraViewportState(
                    center: Point(
                      coordinates: Position(
                        _defaultCenter.lng,
                        _defaultCenter.lat,
                      ),
                    ),
                    zoom: _defaultOverviewZoom,
                  ),
                  onMapCreated: _onMapCreated,
                  onStyleLoadedListener: _onStyleLoaded,
                  onMapLoadErrorListener: (MapLoadingErrorEventData error) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Map load error: ${error.message}'),
                      ),
                    );
                  },
                  onCameraChangeListener: (CameraChangedEventData event) {
                    final coords = event.cameraState.center.coordinates;
                    _onCameraCenterChanged(
                      coords.lat.toDouble(),
                      coords.lng.toDouble(),
                    );
                  },
                )
              else
                _buildTestMapSurface(clusters),
              if (widget.isOfflineMode)
                Positioned(
                  top: 8,
                  left: 12,
                  right: 12,
                  child: Material(
                    color: Colors.amber.shade100,
                    borderRadius: BorderRadius.circular(8),
                    elevation: 2,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.cloud_off, size: 18),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Offline mode (local only)',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          floatingActionButton: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FloatingActionButton.small(
                key: const Key('recenter_button'),
                heroTag: 'recenter_fab',
                onPressed: _recenterToUserLocation,
                tooltip: 'My location',
                child: const Icon(Icons.my_location),
              ),
              const SizedBox(height: 12),
              FloatingActionButton.extended(
                heroTag: 'report_rain_fab',
                onPressed: _openReportSheet,
                icon: const Icon(Icons.add_location_alt),
                label: const Text('Report Rain'),
              ),
            ],
          ),
        );
      },
    );
  }
}
