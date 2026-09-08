import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../state/app_controller.dart';

class ConfigurationScreen extends StatelessWidget {
  const ConfigurationScreen({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final missing = controller.config.missingRequiredVariables;
    final firebaseError = controller.firebase.initializationError;
    return Scaffold(
      backgroundColor: AppColors.black,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Row(
                        children: <Widget>[
                          Icon(
                            Icons.translate_rounded,
                            color: AppColors.blue,
                            size: 34,
                          ),
                          SizedBox(width: 12),
                          Text(
                            'Dual Translate',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: AppColors.text,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      const Text(
                        'Native app configuration required',
                        style: TextStyle(
                          color: AppColors.red,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'The app was built without embedding credentials. '
                        'Provide the same Eburon API Key and Firebase values used by '
                        'the web app through Flutter dart-defines, then rebuild.',
                        style: TextStyle(color: AppColors.muted, height: 1.5),
                      ),
                      if (missing.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 22),
                        const Text(
                          'Missing values',
                          style: TextStyle(
                            color: AppColors.text,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          missing.join('\n'),
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontFamily: 'monospace',
                            height: 1.5,
                          ),
                        ),
                      ],
                      if (firebaseError != null) ...<Widget>[
                        const SizedBox(height: 22),
                        const Text(
                          'Initialization detail',
                          style: TextStyle(
                            color: AppColors.text,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          firebaseError,
                          style: const TextStyle(color: AppColors.muted),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
