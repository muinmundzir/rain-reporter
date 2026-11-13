import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../data/auth_service.dart';
import '../data/rain_report_repository.dart';
import '../domain/rain_intensity.dart';
import '../domain/rain_report.dart';
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
  });

  final AuthService authService;
  final RainReportRepository repository;
  final Future<({double lat, double lng})> Function()? locationProvider;
  final bool useNativeMapView;
  final DateTime Function()? clock;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const ({double lat, double lng}) _defaultCenter = (
    lat: -6.200000,
    lng: 106.816666,
  );

  ({double lat, double lng}) _center = _defaultCenter;
  GoogleMapController? _mapController;
  late Stream<List<RainReport>> _reportsStream;

  @override
  void initState() {
    super.initState();
    _reportsStream = widget.repository.watchActiveReports(
      centerLat: _center.lat,
      centerLng: _center.lng,
    );
    _initLocation();
  }

  void _updateCenter(({double lat, double lng}) newCenter) {
    if (newCenter.lat == _center.lat && newCenter.lng == _center.lng) return;
    setState(() {
      _center = newCenter;
      _reportsStream = widget.repository.watchActiveReports(
        centerLat: _center.lat,
        centerLng: _center.lng,
      );
    });
  }

  Future<void> _initLocation() async {
    try {
      final loc = await (widget.locationProvider ?? _resolveDeviceLocation)();
      if (!mounted) return;
      _updateCenter(loc);
      _mapController?.animateCamera(
        CameraUpdate.newLatLng(LatLng(loc.lat, loc.lng)),
      );
    } catch (_) {
      // Fall back to default center when location permission/service is unavailable
    }
  }

  Future<({double lat, double lng})> _resolveDeviceLocation() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return _defaultCenter;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return _defaultCenter;
    }

    final pos = await Geolocator.getCurrentPosition();
    return (lat: pos.latitude, lng: pos.longitude);
  }

  double _hueForIntensity(RainIntensity intensity) {
    return switch (intensity) {
      RainIntensity.light => BitmapDescriptor.hueAzure,
      RainIntensity.moderate => BitmapDescriptor.hueBlue,
      RainIntensity.heavy => BitmapDescriptor.hueViolet,
      RainIntensity.storm => BitmapDescriptor.hueRed,
      RainIntensity.stopped => BitmapDescriptor.hueGreen,
    };
  }

  Future<void> _openReportSheet() async {
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
        rawLat: _center.lat,
        rawLng: _center.lng,
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
        final markers = reports.map((report) {
          return Marker(
            markerId: MarkerId(report.id),
            position: LatLng(report.lat, report.lng),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              _hueForIntensity(report.intensity),
            ),
            infoWindow: InfoWindow(
              title: '${report.intensity.label} Rain',
              snippet: report.note,
            ),
            onTap: () => _openPinDetails(report),
          );
        }).toSet();

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
          body: Stack(
            children: [
              if (widget.useNativeMapView)
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: LatLng(_center.lat, _center.lng),
                    zoom: 14,
                  ),
                  myLocationEnabled: true,
                  myLocationButtonEnabled: true,
                  markers: markers,
                  onMapCreated: (controller) => _mapController = controller,
                  onCameraMove: (pos) {
                    _center = (
                      lat: pos.target.latitude,
                      lng: pos.target.longitude,
                    );
                  },
                )
              else
                ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: reports.length,
                  itemBuilder: (context, index) {
                    final r = reports[index];
                    return ListTile(
                      leading: const Icon(Icons.water_drop),
                      title: Text('${r.intensity.label} Rain'),
                      subtitle: r.note != null ? Text(r.note!) : null,
                      onTap: () => _openPinDetails(r),
                    );
                  },
                ),
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
