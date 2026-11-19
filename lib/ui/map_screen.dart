import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../data/auth_service.dart';
import '../data/rain_report_repository.dart';
import '../domain/location_privacy.dart';
import '../domain/rain_cluster.dart';
import '../domain/rain_intensity.dart';
import '../domain/rain_report.dart';
import 'cluster_detail_bottom_sheet.dart';
import 'pin_detail_bottom_sheet.dart';
import 'report_bottom_sheet.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.authService,
    required this.repository,
    this.locationProvider,
    this.useNativeMapView = true,
    this.clock,
    this.panDebounceDuration = const Duration(milliseconds: 400),
    this.panRefreshThresholdMeters = 500,
  });

  final AuthService authService;
  final RainReportRepository repository;
  final Future<({double lat, double lng})?> Function()? locationProvider;
  final bool useNativeMapView;
  final DateTime Function()? clock;
  final Duration panDebounceDuration;
  final double panRefreshThresholdMeters;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const ({double lat, double lng}) _defaultCenter = (
    lat: -6.917500,
    lng: 107.619100,
  );

  ({double lat, double lng}) _cameraCenter = _defaultCenter;
  ({double lat, double lng}) _lastQueriedCenter = _defaultCenter;
  final MapController _mapController = MapController();
  late Stream<List<RainReport>> _reportsStream;
  Timer? _panDebounceTimer;
  bool _isOpeningReportSheet = false;

  @override
  void initState() {
    super.initState();
    _reportsStream = widget.repository.watchActiveReports(
      centerLat: _lastQueriedCenter.lat,
      centerLng: _lastQueriedCenter.lng,
    );
    _initLocation();
  }

  @override
  void dispose() {
    _panDebounceTimer?.cancel();
    super.dispose();
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

  void _onMapPositionChanged(MapCamera camera) {
    _cameraCenter = (
      lat: camera.center.latitude,
      lng: camera.center.longitude,
    );
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
    _refreshReportsForCenter(loc);
    _mapController.move(LatLng(loc.lat, loc.lng), 14);
  }

  Future<({double lat, double lng})?> _resolveDeviceLocation() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return null;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }

    final pos = await Geolocator.getCurrentPosition();
    return (lat: pos.latitude, lng: pos.longitude);
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
        await widget.repository.submitReport(
          uid: uid,
          intensity: submission.intensity,
          rawLat: loc.lat,
          rawLng: loc.lng,
          note: submission.note,
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

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<RainReport>>(
      stream: _reportsStream,
      builder: (context, snapshot) {
        final reports = snapshot.data ?? const <RainReport>[];
        final clusters = RainClusterer.cluster(reports);
        final circles = clusters.map((cluster) {
          final color = _colorForIntensity(cluster.strongestIntensity);
          return CircleMarker(
            point: LatLng(cluster.centerLat, cluster.centerLng),
            radius: cluster.radiusMeters,
            useRadiusInMeter: true,
            color: color.withValues(alpha: 0.22),
            borderColor: color.withValues(alpha: 0.6),
            borderStrokeWidth: 1.5,
          );
        }).toList();

        final markers = clusters.map((cluster) {
          final color = _colorForIntensity(cluster.strongestIntensity);
          if (!cluster.isCluster) {
            final report = cluster.reports.first;
            return Marker(
              point: LatLng(cluster.centerLat, cluster.centerLng),
              width: 44,
              height: 44,
              child: GestureDetector(
                onTap: () => _openPinDetails(report),
                child: Tooltip(
                  message: '${report.intensity.label} Rain',
                  child: Icon(
                    Icons.location_on,
                    size: 40,
                    color: color,
                  ),
                ),
              ),
            );
          }

          return Marker(
            point: LatLng(cluster.centerLat, cluster.centerLng),
            width: 44,
            height: 44,
            child: GestureDetector(
              onTap: () => _openClusterDetails(cluster),
              child: Tooltip(
                message:
                    '${cluster.strongestIntensity.label} Rain (${cluster.reports.length} reports)',
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 4,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${cluster.reports.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList();

        return Scaffold(
          appBar: AppBar(
            title: const Text('Rain Reporter'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Chip(
                  avatar: const Icon(Icons.cloud, size: 18),
                  label: Text('${reports.length} active nearby'),
                ),
              ),
            ],
          ),
          body: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: LatLng(_cameraCenter.lat, _cameraCenter.lng),
              initialZoom: 14,
              onPositionChanged: (camera, _) => _onMapPositionChanged(camera),
            ),
            children: [
              if (widget.useNativeMapView)
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.rainreporter.rain_reporter',
                ),
              CircleLayer(circles: circles),
              MarkerLayer(markers: markers),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _openReportSheet,
            icon: const Icon(Icons.add_location_alt),
            label: const Text('Report Rain'),
          ),
        );
      },
    );
  }
}
