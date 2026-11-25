import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;

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
  FcmNotificationService({
    required String workerUrl,
    http.Client? httpClient,
    Future<void> Function(String topic)? subscribeToTopic,
    Future<void> Function(String topic)? unsubscribeFromTopic,
    Future<String?> Function()? getIdToken,
    Duration requestTimeout = const Duration(seconds: 5),
  })  : _workerUrl = workerUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _subscribeToTopic = subscribeToTopic ??
            ((topic) => FirebaseMessaging.instance.subscribeToTopic(topic)),
        _unsubscribeFromTopic = unsubscribeFromTopic ??
            ((topic) => FirebaseMessaging.instance.unsubscribeFromTopic(topic)),
        _getIdToken = getIdToken ??
            (() async => FirebaseAuth.instance.currentUser?.getIdToken()),
        _requestTimeout = requestTimeout;

  final String _workerUrl;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Future<void> Function(String topic) _subscribeToTopic;
  final Future<void> Function(String topic) _unsubscribeFromTopic;
  final Future<String?> Function() _getIdToken;
  final Duration _requestTimeout;

  String? _currentTopic;
  StreamSubscription<RemoteMessage>? _openedAppSub;

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
    final geohash5 = LocationPrivacy.encodeGeohash(lat, lng, precision: 5);
    final nextTopic = 'rain_$geohash5';
    if (nextTopic == _currentTopic) return;

    final previousTopic = _currentTopic;
    try {
      await _subscribeToTopic(nextTopic);
      _currentTopic = nextTopic;
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

      final geohash5 = LocationPrivacy.encodeGeohash(
        report.lat,
        report.lng,
        precision: 5,
      );
      final uri = Uri.parse('$_workerUrl/notify-rain');
      final payload = <String, dynamic>{
        'geohash5': geohash5,
        'intensity': report.intensity.wireName,
        'lat': report.lat,
        'lng': report.lng,
        if (report.note != null) 'note': report.note,
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
          .timeout(_requestTimeout);
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
