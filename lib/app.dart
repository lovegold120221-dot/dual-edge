import 'package:flutter/material.dart';

import 'core/app_theme.dart';
import 'state/app_controller.dart';
import 'ui/translator_screen.dart';

class DualTranslateApp extends StatefulWidget {
  const DualTranslateApp({required this.controller, super.key});

  final AppController controller;

  @override
  State<DualTranslateApp> createState() => _DualTranslateAppState();
}

class _DualTranslateAppState extends State<DualTranslateApp> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return MaterialApp(
          title: 'Dual Translate',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: _home(controller),
        );
      },
    );
  }

  Widget _home(AppController controller) {
    if (!controller.initialized) {
      return const _LoadingScreen();
    }
    return TranslatorScreen(controller: controller);
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(height: 18),
            Text(
              'Loading Dual Translate…',
              style: TextStyle(color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}
