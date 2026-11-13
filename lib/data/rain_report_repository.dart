import 'dart:async';
import 'dart:math';

import '../domain/location_privacy.dart';
import '../domain/rain_intensity.dart';
import '../domain/rain_report.dart';

class RateLimitException implements Exception {
  const RateLimitException([
    this.message = 'Please wait 2 minutes before submitting another report.',
  ]);
  final String message;

  @override
  String toString() => 'RateLimitException: $message';
}

class DuplicateVoteException implements Exception {
  const DuplicateVoteException([
    this.message = 'You have already voted on this report.',
  ]);
  final String message;

  @override
  String toString() => 'DuplicateVoteException: $message';
}

abstract class RainReportRepository {
  Stream<List<RainReport>> watchActiveReports({
    required double centerLat,
    required double centerLng,
    double radiusMeters = 10000,
  });

  Future<RainReport> submitReport({
    required String uid,
    required RainIntensity intensity,
    required double rawLat,
    required double rawLng,
    String? note,
  });

  Future<void> voteReport({
    required String reportId,
    required String uid,
    required bool isStillRaining,
  });
}

class InMemoryRainReportRepository implements RainReportRepository {
  InMemoryRainReportRepository({
    DateTime Function()? clock,
    Random? random,
  })  : _clock = clock ?? (() => DateTime.now().toUtc()),
        _random = random ?? Random(42);

  final DateTime Function() _clock;
  final Random _random;
  final List<RainReport> _reports = [];
  final Map<String, DateTime> _lastReportByUid = {};
  final Set<String> _votes = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  int _nextId = 1;

  List<RainReport> _computeActive({
    required double centerLat,
    required double centerLng,
    required double radiusMeters,
  }) {
    final now = _clock();
    final active = LocationPrivacy.filterActiveReports(_reports, now: now);
    return active.where((r) {
      final dist = LocationPrivacy.distanceMeters(
        centerLat,
        centerLng,
        r.lat,
        r.lng,
      );
      return dist <= radiusMeters;
    }).toList();
  }

  @override
  Stream<List<RainReport>> watchActiveReports({
    required double centerLat,
    required double centerLng,
    double radiusMeters = 10000,
  }) async* {
    yield _computeActive(
      centerLat: centerLat,
      centerLng: centerLng,
      radiusMeters: radiusMeters,
    );
    await for (final _ in _changes.stream) {
      yield _computeActive(
        centerLat: centerLat,
        centerLng: centerLng,
        radiusMeters: radiusMeters,
      );
    }
  }

  @override
  Future<RainReport> submitReport({
    required String uid,
    required RainIntensity intensity,
    required double rawLat,
    required double rawLng,
    String? note,
  }) async {
    final now = _clock();
    final last = _lastReportByUid[uid];
    if (last != null && now.difference(last) < const Duration(minutes: 2)) {
      throw const RateLimitException();
    }

    final fuzzed = LocationPrivacy.fuzzCoordinate(
      lat: rawLat,
      lng: rawLng,
      random: _random,
    );

    final report = RainReport.create(
      id: 'report-${_nextId++}',
      uid: uid,
      intensity: intensity,
      note: note,
      lat: fuzzed.lat,
      lng: fuzzed.lng,
      createdAt: now,
    );

    _lastReportByUid[uid] = now;
    _reports.add(report);
    _changes.add(null);
    return report;
  }

  @override
  Future<void> voteReport({
    required String reportId,
    required String uid,
    required bool isStillRaining,
  }) async {
    final voteKey = '$reportId:$uid';
    if (_votes.contains(voteKey)) {
      throw const DuplicateVoteException();
    }

    final index = _reports.indexWhere((r) => r.id == reportId);
    if (index == -1) {
      throw StateError('Report not found: $reportId');
    }

    _votes.add(voteKey);
    final current = _reports[index];
    _reports[index] = isStillRaining
        ? current.copyWith(confirmCount: current.confirmCount + 1)
        : current.copyWith(stoppedCount: current.stoppedCount + 1);
    _changes.add(null);
  }
}
