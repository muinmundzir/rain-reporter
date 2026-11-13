import 'package:firebase_auth/firebase_auth.dart';

abstract class AuthService {
  Future<String> ensureAnonymousUid();
}

class FirebaseAuthService implements AuthService {
  FirebaseAuthService({FirebaseAuth? firebaseAuth})
      : _firebaseAuth = firebaseAuth ?? FirebaseAuth.instance;

  final FirebaseAuth _firebaseAuth;

  @override
  Future<String> ensureAnonymousUid() async {
    final current = _firebaseAuth.currentUser;
    if (current != null) {
      return current.uid;
    }
    final credential = await _firebaseAuth.signInAnonymously();
    final user = credential.user;
    if (user == null) {
      throw StateError('Anonymous sign-in returned no user');
    }
    return user.uid;
  }
}

class FakeAuthService implements AuthService {
  FakeAuthService({this.uid = 'local-anon-uid'});

  final String uid;

  @override
  Future<String> ensureAnonymousUid() async => uid;
}
