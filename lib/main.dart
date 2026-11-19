import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'data/auth_service.dart';
import 'data/firestore_rain_report_repository.dart';
import 'data/rain_report_repository.dart';
import 'ui/map_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  AuthService authService;
  RainReportRepository repository;

  try {
    await Firebase.initializeApp();
    authService = FirebaseAuthService();
    repository = FirestoreRainReportRepository();
  } catch (_) {
    authService = FakeAuthService();
    repository = InMemoryRainReportRepository();
  }

  runApp(
    RainReporterApp(
      authService: authService,
      repository: repository,
    ),
  );
}

class RainReporterApp extends StatelessWidget {
  const RainReporterApp({
    super.key,
    required this.authService,
    required this.repository,
    this.locationProvider,
    this.useNativeMapView = true,
  });

  final AuthService authService;
  final RainReportRepository repository;
  final Future<({double lat, double lng})?> Function()? locationProvider;
  final bool useNativeMapView;

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
        locationProvider: locationProvider,
        useNativeMapView: useNativeMapView,
      ),
    );
  }
}
