import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/location_privacy.dart';
import '../domain/rain_intensity.dart';
import '../domain/rain_report.dart';

typedef NotificationTapCallback = void Function(double lat, double lng);

abstract class NotificationService {
  Future<void> initialize({
    required NotificationTapCallback onNotificationTap,
  });

  Future<void> updateLocationCell({
    required double lat,
    required double lng,
  });

  Future<void> notifyRainReport({
    required RainReport report,
  });

  void dispose();
}

class NoOpNotificationService implements NotificationService {
  const NoOpNotificationService();

  @override
  Future<void> initialize({
    required NotificationTapCallback onNotificationTap,
  }) async {}

  @override
  Future<void> updateLocationCell({
    required double lat,
    required double lng,
  }) async {}

  @override
  Future<void> notifyRainReport({required RainReport report}) async {}

  @override
  void dispose() {}
}

class FcmNotificationService implements NotificationService {
  static const String _savedTopicKey = 'fcm_subscribed_geohash_topic';

  FcmNotificationService({
    required String workerUrl,
    http.Client? httpClient,
    Future<void> Function(String topic)? subscribeToTopic,
    Future<void> Function(String topic)? unsubscribeFromTopic,
    Future<String?> Function()? getIdToken,
    Future<String?> Function()? loadSavedTopic,
    Future<void> Function(String topic)? saveTopic,
    this.requestTimeout = const Duration(seconds: 5),
  })  : _workerUrl = workerUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _subscribeToTopic = subscribeToTopic ??
            ((topic) => FirebaseMessaging.instance.subscribeToTopic(topic)),
        _unsubscribeFromTopic = unsubscribeFromTopic ??
            ((topic) => FirebaseMessaging.instance.unsubscribeFromTopic(topic)),
        _getIdToken = getIdToken ??
            (() async => FirebaseAuth.instance.currentUser?.getIdToken()),
        _loadSavedTopic = loadSavedTopic ?? _defaultLoadSavedTopic,
        _saveTopic = saveTopic ?? _defaultSaveTopic;

  final String _workerUrl;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Future<void> Function(String topic) _subscribeToTopic;
  final Future<void> Function(String topic) _unsubscribeFromTopic;
  final Future<String?> Function() _getIdToken;
  final Future<String?> Function() _loadSavedTopic;
  final Future<void> Function(String topic) _saveTopic;
  final Duration requestTimeout;

  String? _currentTopic;
  bool _hydratedSavedTopic = false;
  StreamSubscription<RemoteMessage>? _openedAppSub;

  static Future<String?> _defaultLoadSavedTopic() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_savedTopicKey);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _defaultSaveTopic(String topic) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_savedTopicKey, topic);
    } catch (_) {
      // Best-effort persistence.
    }
  }

  @override
  Future<void> initialize({
    required NotificationTapCallback onNotificationTap,
  }) async {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();

      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        _dispatchMessageTap(initialMessage, onNotificationTap);
      }

      await _openedAppSub?.cancel();
      _openedAppSub = FirebaseMessaging.onMessageOpenedApp.listen((message) {
        _dispatchMessageTap(message, onNotificationTap);
      });
    } catch (_) {
      // Push setup is best-effort; never block map startup if FCM is unavailable.
    }
  }

  void _dispatchMessageTap(
    RemoteMessage message,
    NotificationTapCallback onNotificationTap,
  ) {
    final lat = double.tryParse('${message.data['lat'] ?? ''}');
    final lng = double.tryParse('${message.data['lng'] ?? ''}');
    if (lat != null && lng != null) {
      onNotificationTap(lat, lng);
    }
  }

  @override
  Future<void> updateLocationCell({
    required double lat,
    required double lng,
  }) async {
    if (!_hydratedSavedTopic) {
      _hydratedSavedTopic = true;
      _currentTopic = await _loadSavedTopic();
    }

    final geohash5 = LocationPrivacy.encodeGeohash(lat, lng, precision: 5);
    final nextTopic = 'rain_$geohash5';
    if (nextTopic == _currentTopic) return;

    final previousTopic = _currentTopic;
    try {
      await _subscribeToTopic(nextTopic);
      _currentTopic = nextTopic;
      await _saveTopic(nextTopic);
      if (previousTopic != null) {
        await _unsubscribeFromTopic(previousTopic);
      }
    } catch (_) {
      // Ignore transient topic subscription failures; next location update retries.
    }
  }

  @override
  Future<void> notifyRainReport({required RainReport report}) async {
    if (_workerUrl.isEmpty) return;
    if (report.intensity != RainIntensity.heavy &&
        report.intensity != RainIntensity.storm) {
      return;
    }

    try {
      final idToken = await _getIdToken();
      if (idToken == null || idToken.isEmpty) return;

      final uri = Uri.parse('$_workerUrl/notify-rain');
      // Only the report id is sent. The worker re-reads the authoritative
      // report (owner, intensity, location, freshness) from Firestore before
      // pushing, so the client can no longer spoof the alert content, target,
      // or location.
      final payload = <String, dynamic>{
        'reportId': report.id,
      };

      await _httpClient
          .post(
            uri,
            headers: {
              'authorization': 'Bearer $idToken',
              'content-type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(requestTimeout);
    } catch (_) {
      // Push trigger is best-effort and must never fail a rain report submission.
    }
  }

  @override
  void dispose() {
    _openedAppSub?.cancel();
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }
}
