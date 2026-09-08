import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dual_translate/core/app_config.dart';
import 'package:dual_translate/services/firebase_service.dart';
import 'package:dual_translate/state/app_controller.dart';
import 'package:dual_translate/ui/auth_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('user profile document', () {
    test('new profile carries identity, providers, and timestamps', () {
      const uid = 'uid-123';
      final doc = FirebaseService.buildUserProfile(
        uid: uid,
        email: 'ada@eburon.ai',
        displayName: 'Ada',
        photoURL: 'https://example.com/ada.png',
        providers: const <String>['google.com'],
      );

      expect(doc['uid'], uid);
      expect(doc['email'], 'ada@eburon.ai');
      expect(doc['displayName'], 'Ada');
      expect(doc['photoURL'], 'https://example.com/ada.png');
      expect(doc['providers'], <String>['google.com']);
      expect(doc['createdAt'], isA<FieldValue>());
      expect(doc['lastSignInAt'], isA<FieldValue>());
      expect(doc['updatedAt'], isA<FieldValue>());
    });

    test('update preserves the original createdAt', () {
      const created = 'original-timestamp-sentinel';
      final doc = FirebaseService.buildUserProfile(
        uid: 'uid-123',
        email: 'ada@eburon.ai',
        providers: const <String>['password', 'google.com'],
        existingCreatedAt: created,
      );

      expect(doc['createdAt'], created);
      expect(doc['providers'], <String>['password', 'google.com']);
      expect(doc['lastSignInAt'], isA<FieldValue>());
    });

    test('null identity fields default to empty strings', () {
      final doc = FirebaseService.buildUserProfile(uid: 'uid-123');

      expect(doc['email'], '');
      expect(doc['displayName'], '');
      expect(doc['photoURL'], '');
      expect(doc['providers'], isEmpty);
    });
  });

  group('auth screen', () {
    testWidgets('email fields, primary action, and Google button render', (
      tester,
    ) async {
      const config = AppConfig(
        ollamaUrl: 'http://localhost:11434',
        modelName: 'eb-translator',
      );
      final controller = AppController(config: config);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: AuthScreen(controller: controller)),
      );

      expect(find.text('Sign In'), findsWidgets);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('New here? Create account'), findsOneWidget);
      expect(find.text('Forgot password?'), findsOneWidget);
    });

    testWidgets('create-account and reset views switch correctly', (
      tester,
    ) async {
      const config = AppConfig(
        ollamaUrl: 'http://localhost:11434',
        modelName: 'eb-translator',
      );
      final controller = AppController(config: config);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: AuthScreen(controller: controller)),
      );

      await tester.tap(find.text('New here? Create account'));
      await tester.pump();
      expect(find.text('Create account'), findsWidgets);

      await tester.tap(find.text('Already have an account? Sign in'));
      await tester.pump();
      await tester.tap(find.text('Forgot password?'));
      await tester.pump();
      expect(find.text('Reset password'), findsWidgets);
      expect(find.text('Password reset email sent.'), findsNothing);
    });
  });
}
