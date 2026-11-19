import 'location_privacy.dart';
import 'rain_intensity.dart';

class RainReport {
  const RainReport({
    required this.id,
    required this.uid,
    required this.intensity,
    required this.note,
    required this.lat,
    required this.lng,
    required this.geohash,
    required this.confirmCount,
    required this.stoppedCount,
    required this.createdAt,
    required this.expiresAt,
  });

  factory RainReport.create({
    required String id,
    required String uid,
    required RainIntensity intensity,
    required double lat,
    required double lng,
    required DateTime createdAt,
    String? note,
    int confirmCount = 1,
    int stoppedCount = 0,
  }) {
    final trimmed = note?.trim();
    final normalizedNote = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    if (normalizedNote != null && normalizedNote.length > 140) {
      throw ArgumentError.value(
        normalizedNote,
        'note',
        'Note must be at most 140 characters',
      );
    }

    return RainReport(
      id: id,
      uid: uid,
      intensity: intensity,
      note: normalizedNote,
      lat: lat,
      lng: lng,
      geohash: LocationPrivacy.encodeGeohash(lat, lng),
      confirmCount: confirmCount,
      stoppedCount: stoppedCount,
      createdAt: createdAt,
      expiresAt: createdAt.add(const Duration(minutes: 30)),
    );
  }

  factory RainReport.fromMap(String id, Map<String, dynamic> map) {
    DateTime parseTime(dynamic value) {
      if (value is DateTime) return value.toUtc();
      if (value is String) return DateTime.parse(value).toUtc();
      if (value is int) return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
      // Support Firestore Timestamp duck-typing without importing cloud_firestore in domain
      // ignore: avoid_dynamic_calls
      return (value.toDate() as DateTime).toUtc();
    }

    final lat = (map['lat'] as num).toDouble();
    final lng = (map['lng'] as num).toDouble();

    final expiresAt = parseTime(map['expiresAt']);
    final createdAt = map['createdAt'] == null
        ? expiresAt.subtract(const Duration(minutes: 30))
        : parseTime(map['createdAt']);

    return RainReport(
      id: id,
      uid: map['uid'] as String? ?? '',
      intensity: RainIntensity.fromWire(map['intensity'] as String? ?? 'light'),
      note: map['note'] as String?,
      lat: lat,
      lng: lng,
      geohash: map['geohash'] as String? ?? LocationPrivacy.encodeGeohash(lat, lng),
      confirmCount: (map['confirmCount'] as num?)?.toInt() ?? 1,
      stoppedCount: (map['stoppedCount'] as num?)?.toInt() ?? 0,
      createdAt: createdAt,
      expiresAt: expiresAt,
    );
  }

  final String id;
  final String uid;
  final RainIntensity intensity;
  final String? note;
  final double lat;
  final double lng;
  final String geohash;
  final int confirmCount;
  final int stoppedCount;
  final DateTime createdAt;
  final DateTime expiresAt;

  bool isActiveAt(DateTime now) => expiresAt.isAfter(now);

  RainReport copyWith({
    int? confirmCount,
    int? stoppedCount,
  }) {
    return RainReport(
      id: id,
      uid: uid,
      intensity: intensity,
      note: note,
      lat: lat,
      lng: lng,
      geohash: geohash,
      confirmCount: confirmCount ?? this.confirmCount,
      stoppedCount: stoppedCount ?? this.stoppedCount,
      createdAt: createdAt,
      expiresAt: expiresAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'intensity': intensity.wireName,
      if (note != null) 'note': note,
      'lat': lat,
      'lng': lng,
      'geohash': geohash,
      'confirmCount': confirmCount,
      'stoppedCount': stoppedCount,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'expiresAt': expiresAt.toUtc().toIso8601String(),
    };
  }
}
