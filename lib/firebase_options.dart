import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for $defaultTargetPlatform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCl-RMhnvy6K6R7ibJlDien9AYlHj-RtEE',
    appId: '1:62813048406:web:ae93bde301b5144c07f5f7',
    messagingSenderId: '62813048406',
    projectId: 'rain-reporter-bdg',
    authDomain: 'rain-reporter-bdg.firebaseapp.com',
    storageBucket: 'rain-reporter-bdg.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCCwcx6eWXhrT6sQa_ex_gER4XgaDnSg5Q',
    appId: '1:62813048406:android:fe074ea0881096ad07f5f7',
    messagingSenderId: '62813048406',
    projectId: 'rain-reporter-bdg',
    storageBucket: 'rain-reporter-bdg.firebasestorage.app',
  );
}
