import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_config.dart';
import 'state/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final controller = AppController(config: AppConfig.fromEnvironment());
  // Paint UI immediately (loading → translator). Heavy init runs after.
  runApp(DualTranslateApp(controller: controller));
  unawaited(controller.initialize());
}
