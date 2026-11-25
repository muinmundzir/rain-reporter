import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import 'data/auth_service.dart';
import 'data/firestore_rain_report_repository.dart';
import 'data/notification_service.dart';
import 'data/rain_report_repository.dart';
import 'firebase_options.dart';
import 'ui/map_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const mapboxToken = String.fromEnvironment('MAPBOX_ACCESS_TOKEN');
  if (mapboxToken.isNotEmpty) {
    MapboxOptions.setAccessToken(mapboxToken);
  }
  const notifyWorkerUrl = String.fromEnvironment('NOTIFY_WORKER_URL');

  AuthService authService;
  RainReportRepository repository;
  NotificationService notificationService;
  var isOfflineMode = false;

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    authService = FirebaseAuthService();
    repository = FirestoreRainReportRepository();
    notificationService = FcmNotificationService(workerUrl: notifyWorkerUrl);
  } catch (_) {
    isOfflineMode = true;
    authService = FakeAuthService();
    repository = InMemoryRainReportRepository();
    notificationService = const NoOpNotificationService();
  }

  runApp(
    RainReporterApp(
      authService: authService,
      repository: repository,
      notificationService: notificationService,
      isOfflineMode: isOfflineMode,
    ),
  );
}

class RainReporterApp extends StatelessWidget {
  const RainReporterApp({
    super.key,
    required this.authService,
    required this.repository,
    this.notificationService = const NoOpNotificationService(),
    this.locationProvider,
    this.useNativeMapView = true,
    this.isOfflineMode = false,
    this.mapTestController,
  });

  final AuthService authService;
  final RainReportRepository repository;
  final NotificationService notificationService;
  final Future<({double lat, double lng})?> Function()? locationProvider;
  final bool useNativeMapView;
  final bool isOfflineMode;
  final MapTestController? mapTestController;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rain Reporter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: MapScreen(
        authService: authService,
        repository: repository,
        notificationService: notificationService,
        locationProvider: locationProvider,
        useNativeMapView: useNativeMapView,
        isOfflineMode: isOfflineMode,
        mapTestController: mapTestController,
      ),
    );
  }
}
