import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/location_privacy.dart';
import '../domain/rain_intensity.dart';
import '../domain/rain_report.dart';
import 'rain_report_repository.dart';

class FirestoreRainReportRepository implements RainReportRepository {
  FirestoreRainReportRepository({
    FirebaseFirestore? firestore,
    DateTime Function()? clock,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _clock = clock ?? (() => DateTime.now().toUtc());

  final FirebaseFirestore _firestore;
  final DateTime Function() _clock;

  @override
  Stream<List<RainReport>> watchActiveReports({
    required double centerLat,
    required double centerLng,
    double radiusMeters = 10000,
  }) {
    final now = _clock();
    return _firestore
        .collection('reports')
        .where('expiresAt', isGreaterThan: Timestamp.fromDate(now))
        .snapshots()
        .map((snapshot) {
      final currentNow = _clock();
      final allReports = snapshot.docs
          .map((doc) => RainReport.fromMap(doc.id, doc.data()))
          .toList();
      final active = LocationPrivacy.filterActiveReports(
        allReports,
        now: currentNow,
      );
      return active.where((r) {
        final dist = LocationPrivacy.distanceMeters(
          centerLat,
          centerLng,
          r.lat,
          r.lng,
        );
        return dist <= radiusMeters;
      }).toList();
    });
  }

  @override
  Future<RainReport> submitReport({
    required String uid,
    required RainIntensity intensity,
    required double rawLat,
    required double rawLng,
    String? note,
  }) async {
    final fuzzed = LocationPrivacy.fuzzCoordinate(lat: rawLat, lng: rawLng);
    final now = _clock();
    final docRef = _firestore.collection('reports').doc();
    final rateLimitRef = _firestore.collection('rateLimits').doc(uid);

    final report = RainReport.create(
      id: docRef.id,
      uid: uid,
      intensity: intensity,
      note: note,
      lat: fuzzed.lat,
      lng: fuzzed.lng,
      createdAt: now,
    );

    final batch = _firestore.batch();
    batch.set(docRef, {
      'uid': report.uid,
      'intensity': report.intensity.wireName,
      if (report.note != null) 'note': report.note,
      'lat': report.lat,
      'lng': report.lng,
      'geohash': report.geohash,
      'confirmCount': 1,
      'stoppedCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(report.expiresAt),
    });
    batch.set(rateLimitRef, {
      'lastReportAt': FieldValue.serverTimestamp(),
    });

    try {
      await batch.commit();
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw const RateLimitException();
      }
      rethrow;
    }
    return report;
  }

  @override
  Future<void> voteReport({
    required String reportId,
    required String uid,
    required bool isStillRaining,
  }) async {
    final reportRef = _firestore.collection('reports').doc(reportId);
    final voteRef = reportRef.collection('votes').doc(uid);

    try {
      await _firestore.runTransaction((tx) async {
        final existingVote = await tx.get(voteRef);
        if (existingVote.exists) {
          throw const DuplicateVoteException();
        }
        tx.set(voteRef, {
          'type': isStillRaining ? 'confirm' : 'stopped',
          'createdAt': FieldValue.serverTimestamp(),
        });
        tx.update(reportRef, {
          isStillRaining ? 'confirmCount' : 'stoppedCount':
              FieldValue.increment(1),
        });
      });
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied' || e.code == 'already-exists') {
        throw const DuplicateVoteException();
      }
      rethrow;
    }
  }
}
