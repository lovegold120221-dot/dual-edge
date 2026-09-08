import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../core/app_config.dart';
import '../data/models/history_item.dart';
import '../data/models/translation_settings.dart';

class AuthUser {
  const AuthUser({
    required this.uid,
    this.email,
    this.displayName,
    this.photoURL,
  });

  factory AuthUser.fromFirebaseUser(User user) {
    return AuthUser(
      uid: user.uid,
      email: user.email,
      displayName: user.displayName,
      photoURL: user.photoURL,
    );
  }

  final String uid;
  final String? email;
  final String? displayName;
  final String? photoURL;
}

class FirebaseService extends ChangeNotifier {
  FirebaseService(this.config);

  static const superAdminEmails = <String>{
    'master@eburon.ai',
    'martijn@eburon.ai',
  };

  final AppConfig config;

  AuthUser? _user;
  bool _loading = true;
  bool _ready = false;
  String? _initializationError;
  StreamSubscription<User?>? _authSubscription;

  AuthUser? get user => _user;
  bool get loading => _loading;
  bool get ready => _ready;
  String? get initializationError => _initializationError;

  /// True when Firebase core initialized and this service is usable.
  /// False on macOS edge builds (Firebase skipped) and on init failure.
  bool get isActive =>
      _ready && _initializationError == null && Firebase.apps.isNotEmpty;
  bool get isSuperAdmin =>
      superAdminEmails.contains(_user?.email?.trim().toLowerCase());

  FirebaseAuth get _auth => FirebaseAuth.instance;
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  Future<void> initialize() async {
    try {
      _authSubscription = _auth.authStateChanges().listen(_onAuthStateChanged);
      _ready = true;
    } on Object catch (error) {
      _initializationError = error.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void _onAuthStateChanged(User? firebaseUser) {
    if (firebaseUser != null) {
      _user = AuthUser.fromFirebaseUser(firebaseUser);
      // Keep the profile fresh on every path: sign-up, sign-in, Google,
      // and session restore. Best-effort (offline tolerant).
      unawaited(_upsertUserRecord(firebaseUser));
    } else {
      _user = null;
    }
    notifyListeners();
  }

  // ── Email/Password Authentication ──

  Future<void> signIn(String email, String password) async {
    await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<void> signUp(String email, String password) async {
    final trimmed = email.trim();
    if (trimmed.isEmpty || password.isEmpty) {
      throw ArgumentError('Email and password are required.');
    }
    await _auth.createUserWithEmailAndPassword(
      email: trimmed,
      password: password,
    );
  }

  Future<void> sendPasswordReset(String email) async {
    final trimmed = email.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Email is required.');
    }
    await _auth.sendPasswordResetEmail(email: trimmed);
  }

  // ── Google Authentication ──

  bool _googleInitialized = false;

  /// Sign in with Google. Web uses a popup; mobile uses the native flow
  /// (needs GOOGLE_SERVER_CLIENT_ID on Android for the ID token audience).
  /// A user-cancelled flow returns silently instead of throwing.
  Future<void> signInWithGoogle() async {
    if (kIsWeb) {
      await _auth.signInWithPopup(GoogleAuthProvider());
      return;
    }
    if (!_googleInitialized) {
      await GoogleSignIn.instance.initialize(
        serverClientId: config.googleServerClientId.isNotEmpty
            ? config.googleServerClientId
            : null,
      );
      _googleInitialized = true;
    }
    GoogleSignInAccount account;
    try {
      account = await GoogleSignIn.instance.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.interrupted) {
        return; // User dismissed the account picker; not an error.
      }
      rethrow;
    }
    final idToken = account.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw StateError(
        'Google Sign-In returned no ID token. On Android this means '
        'GOOGLE_SERVER_CLIENT_ID is missing or mismatched.',
      );
    }
    await _auth.signInWithCredential(
      GoogleAuthProvider.credential(idToken: idToken),
    );
  }

  Future<void> signOut() async {
    try {
      if (_googleInitialized && !kIsWeb) {
        await GoogleSignIn.instance.signOut();
      }
    } catch (_) {}
    await _auth.signOut();
  }

  // ── User Record ──

  /// Profile document payload (pure: fully unit-testable).
  ///
  /// [existingCreatedAt] preserves the original creation timestamp on
  /// updates; pass null (or nothing) when the document is new.
  static Map<String, Object?> buildUserProfile({
    required String uid,
    String? email,
    String? displayName,
    String? photoURL,
    List<String> providers = const <String>[],
    Object? existingCreatedAt,
  }) {
    return <String, Object?>{
      'uid': uid,
      'email': email ?? '',
      'displayName': displayName ?? '',
      'photoURL': photoURL ?? '',
      'providers': List<String>.from(providers),
      'createdAt': existingCreatedAt ?? FieldValue.serverTimestamp(),
      'lastSignInAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  /// Create-or-update `users/{uid}` for any auth path (owner-only rules).
  Future<void> _upsertUserRecord(User firebaseUser) async {
    try {
      final docRef = _firestore.collection('users').doc(firebaseUser.uid);
      final doc = await docRef.get();
      final existing = doc.data();
      await docRef.set(
        buildUserProfile(
          uid: firebaseUser.uid,
          email: firebaseUser.email,
          displayName: firebaseUser.displayName,
          photoURL: firebaseUser.photoURL,
          providers: firebaseUser.providerData
              .map((info) => info.providerId)
              .where((id) => id.isNotEmpty)
              .toList(),
          existingCreatedAt: existing?['createdAt'],
        ),
        SetOptions(merge: true),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Profile upsert skipped: $e');
      }
    }
  }

  // ── Firestore: Translation History ──

  Future<void> saveTranslation(HistoryItem item) async {
    if (_user == null) return;
    await _firestore
        .collection('users')
        .doc(_user!.uid)
        .collection('translations')
        .doc(item.id)
        .set({
          'id': item.id,
          'sourceText': item.sourceText,
          'translatedText': item.translatedText,
          'language1': item.language1,
          'language2': item.language2,
          'timestamp': Timestamp.fromDate(item.timestamp),
        });
  }

  Future<void> clearTranslations() async {
    if (_user == null) return;
    final batch = _firestore.batch();
    final translations = await _firestore
        .collection('users')
        .doc(_user!.uid)
        .collection('translations')
        .get();
    for (final doc in translations.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
  }

  // ── Firestore: Settings ──

  Future<void> saveSettings(TranslationSettings settings) async {
    if (_user == null) return;
    await _firestore.collection('users').doc(_user!.uid).set({
      'settings': {
        'language1': settings.language1,
        'language2': settings.language2,
        'autoDetect': settings.autoDetect,
      },
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }
}
