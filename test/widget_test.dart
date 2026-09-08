import 'package:dual_translate/app.dart';
import 'package:dual_translate/core/app_config.dart';
import 'package:dual_translate/core/app_theme.dart';
import 'package:dual_translate/data/models/translation_settings.dart';
import 'package:dual_translate/state/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const emptyConfig = AppConfig(ollamaUrl: '', modelName: 'eb-translator');

  test('generated translation prompt preserves strict pairing rules', () {
    const settings = TranslationSettings(
      language1: 'Dutch (Flemish)',
      language2: 'Tagalog (Filipino)',
      autoDetect: true,
      medicalMode: true,
    );

    expect(settings.systemPrompt, contains('PURE REALTIME TRANSLATOR'));
    expect(settings.systemPrompt, contains('setGuestLanguage'));
    expect(settings.systemPrompt, contains('Tagalog (Filipino)'));
    expect(settings.systemPrompt, contains('MEDICAL MODE ENABLED'));
  });

  test('default settings use local ollama model', () {
    const settings = TranslationSettings();
    expect(settings.model, 'eb-translator');
    expect(emptyConfig.missingRequiredVariables, contains('OLLAMA_URL'));
  });

  testWidgets('app boots to loading with no account gate', (tester) async {
    // DualTranslateApp owns the controller lifetime (disposes on unmount).
    final controller = AppController(config: emptyConfig);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: DualTranslateApp(controller: controller),
      ),
    );

    // Uninitialized controller shows loading; initialized goes straight to
    // the translator — there is no sign-in step anywhere.
    expect(find.text('Loading Dual Translate…'), findsOneWidget);
    expect(find.text('Sign In'), findsNothing);
  });
}
