import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_config.dart';
import 'firebase_options.dart';
import 'state/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase is not configured for macOS in firebase_options.dart — skip it so
  // we never crash before the first frame. Local STT/TTS/Ollama do not need it.
  if (!kIsWeb && defaultTargetPlatform != TargetPlatform.macOS) {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      ).timeout(const Duration(seconds: 5));
    } catch (e, st) {
      debugPrint('Firebase init skipped: $e\n$st');
    }
  } else {
    debugPrint('Firebase skipped on macOS (local edge mode)');
  }

  final controller = AppController(config: AppConfig.fromEnvironment());
  // Paint UI immediately (loading → translator). Heavy init runs after.
  runApp(DualTranslateApp(controller: controller));
  unawaited(controller.initialize());
}
