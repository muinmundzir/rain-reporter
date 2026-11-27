import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rain_reporter/data/notification_service.dart';
import 'package:rain_reporter/domain/location_privacy.dart';
import 'package:rain_reporter/domain/rain_intensity.dart';
import 'package:rain_reporter/domain/rain_report.dart';

RainReport _report({
  required RainIntensity intensity,
  String? note,
}) {
  return RainReport.create(
    id: 'r1',
    uid: 'u1',
    intensity: intensity,
    lat: -6.9175,
    lng: 107.6191,
    note: note,
    createdAt: DateTime.utc(2026, 11, 25, 10, 0),
  );
}

void main() {
  group('FcmNotificationService', () {
    test('updateLocationCell subscribes to rain_<geohash5> and skips redundant subscribe for same cell', () async {
      final subscribed = <String>[];
      final unsubscribed = <String>[];

      final service = FcmNotificationService(
        workerUrl: '',
        subscribeToTopic: (t) async => subscribed.add(t),
        unsubscribeFromTopic: (t) async => unsubscribed.add(t),
      );

      final expectedHash = LocationPrivacy.encodeGeohash(-6.9175, 107.6191, precision: 5);
      await service.updateLocationCell(lat: -6.9175, lng: 107.6191);
      await service.updateLocationCell(lat: -6.9176, lng: 107.6192);

      expect(subscribed, equals(['rain_$expectedHash']));
      expect(unsubscribed, isEmpty);
    });

    test('updateLocationCell unsubscribes previous cell topic when moving to a new cell', () async {
      final subscribed = <String>[];
      final unsubscribed = <String>[];

      final service = FcmNotificationService(
        workerUrl: '',
        subscribeToTopic: (t) async => subscribed.add(t),
        unsubscribeFromTopic: (t) async => unsubscribed.add(t),
      );

      final hashBandung = LocationPrivacy.encodeGeohash(-6.9175, 107.6191, precision: 5);
      final hashJakarta = LocationPrivacy.encodeGeohash(-6.2000, 106.8166, precision: 5);

      await service.updateLocationCell(lat: -6.9175, lng: 107.6191);
      await service.updateLocationCell(lat: -6.2000, lng: 106.8166);

      expect(subscribed, equals(['rain_$hashBandung', 'rain_$hashJakarta']));
      expect(unsubscribed, equals(['rain_$hashBandung']));
    });

    test('updateLocationCell unsubscribes persisted previous topic across app restart', () async {
      final hashBandung = LocationPrivacy.encodeGeohash(-6.9175, 107.6191, precision: 5);
      final hashJakarta = LocationPrivacy.encodeGeohash(-6.2000, 106.8166, precision: 5);
      String? persistedTopic = 'rain_$hashBandung';
      final subscribed = <String>[];
      final unsubscribed = <String>[];

      final restartedService = FcmNotificationService(
        workerUrl: '',
        subscribeToTopic: (t) async => subscribed.add(t),
        unsubscribeFromTopic: (t) async => unsubscribed.add(t),
        loadSavedTopic: () async => persistedTopic,
        saveTopic: (t) async => persistedTopic = t,
      );

      await restartedService.updateLocationCell(lat: -6.2000, lng: 106.8166);

      expect(subscribed, equals(['rain_$hashJakarta']));
      expect(unsubscribed, equals(['rain_$hashBandung']));
      expect(persistedTopic, equals('rain_$hashJakarta'));
    });

    test('notifyRainReport posts to /notify-rain with Bearer token for heavy and storm reports', () async {
      final requests = <http.Request>[];
      final client = MockClient((req) async {
        requests.add(req);
        return http.Response('{"ok":true}', 200);
      });

      final service = FcmNotificationService(
        workerUrl: 'https://rain-notifier.example.workers.dev/',
        httpClient: client,
        getIdToken: () async => 'firebase-jwt-123',
      );

      await service.notifyRainReport(
        report: _report(intensity: RainIntensity.heavy, note: 'Flooding near station'),
      );
      await service.notifyRainReport(
        report: _report(intensity: RainIntensity.storm),
      );

      expect(requests, hasLength(2));
      expect(
        requests[0].url.toString(),
        equals('https://rain-notifier.example.workers.dev/notify-rain'),
      );
      expect(requests[0].headers['authorization'], equals('Bearer firebase-jwt-123'));

      final body0 = jsonDecode(requests[0].body) as Map<String, dynamic>;
      // Only the report id is sent. Intensity, geohash and note are no longer
      // supplied by the client — the worker re-reads them authoritatively from
      // Firestore — so the payload must contain nothing but the id.
      expect(body0['reportId'], equals('r1'));
      expect(body0.keys, equals({'reportId'}));

      final body1 = jsonDecode(requests[1].body) as Map<String, dynamic>;
      expect(body1['reportId'], equals('r1'));
      expect(body1.keys, equals({'reportId'}));
    });

    test('notifyRainReport is a no-op for light, moderate, and stopped reports', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('{"ok":true}', 200);
      });

      final service = FcmNotificationService(
        workerUrl: 'https://rain-notifier.example.workers.dev',
        httpClient: client,
        getIdToken: () async => 'firebase-jwt-123',
      );

      await service.notifyRainReport(report: _report(intensity: RainIntensity.light));
      await service.notifyRainReport(report: _report(intensity: RainIntensity.moderate));
      await service.notifyRainReport(report: _report(intensity: RainIntensity.stopped));

      expect(called, isFalse);
    });

    test('notifyRainReport is a no-op when workerUrl is empty and swallows HTTP errors', () async {
      final failingClient = MockClient((_) async => throw Exception('network down'));

      final emptyUrlService = FcmNotificationService(
        workerUrl: '',
        httpClient: failingClient,
        getIdToken: () async => 'firebase-jwt-123',
      );
      await emptyUrlService.notifyRainReport(report: _report(intensity: RainIntensity.storm));

      final failingService = FcmNotificationService(
        workerUrl: 'https://rain-notifier.example.workers.dev',
        httpClient: failingClient,
        getIdToken: () async => 'firebase-jwt-123',
      );
      await expectLater(
        failingService.notifyRainReport(report: _report(intensity: RainIntensity.storm)),
        completes,
      );
    });
  });
}
