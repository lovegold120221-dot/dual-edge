import 'package:dual_translate/core/app_config.dart';
import 'package:dual_translate/data/models/conversation_turn.dart';
import 'package:dual_translate/state/app_controller.dart';
import 'package:dual_translate/ui/translator_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('input and translation turns are visible in conversation view', (
    tester,
  ) async {
    const config = AppConfig(
      ollamaUrl: 'http://localhost:11434',
      modelName: 'eb-translator',
    );
    final controller = AppController(config: config);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => TranslatorScreen(controller: controller),
        ),
      ),
    );

    controller.turns.add(
      ConversationTurn(
        role: ConversationRole.user,
        text: 'Hello world',
        isFinal: true,
      ),
    );
    controller.turns.add(
      ConversationTurn(
        role: ConversationRole.agent,
        text: 'Hallo wereld',
        transcription: 'Hello world',
        translation: 'Hallo wereld',
        isFinal: true,
      ),
    );
    controller.updateSettings(controller.settings);
    await tester.pump();

    expect(find.textContaining('Hello world'), findsWidgets);
    expect(find.textContaining('Hallo wereld'), findsOneWidget);
    expect(find.text('INPUT'), findsOneWidget);
    expect(find.text('TRANSLATION'), findsOneWidget);
  });
}
