import 'package:dual_translate/core/app_config.dart';
import 'package:dual_translate/core/app_theme.dart';
import 'package:dual_translate/data/models/translation_settings.dart';
import 'package:dual_translate/state/app_controller.dart';
import 'package:dual_translate/ui/configuration_screen.dart';
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

  testWidgets('missing native configuration is explained', (tester) async {
    final controller = AppController(config: emptyConfig);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: ConfigurationScreen(controller: controller),
      ),
    );

    expect(find.text('Native app configuration required'), findsOneWidget);
    expect(find.textContaining('OLLAMA_URL'), findsOneWidget);
    expect(find.byIcon(Icons.translate_rounded), findsOneWidget);
  });
}
