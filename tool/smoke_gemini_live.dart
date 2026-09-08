import 'dart:convert';
import 'dart:io';

import 'package:dual_translate/services/live_api_service.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart run tool/smoke_gemini_live.dart <config-json>');
    exitCode = 64;
    return;
  }

  final configFile = File(arguments.single);
  if (!configFile.existsSync()) {
    stderr.writeln('Configuration file not found.');
    exitCode = 66;
    return;
  }

  final decoded = jsonDecode(await configFile.readAsString());
  if (decoded is! Map) {
    stderr.writeln('Configuration must be a JSON object.');
    exitCode = 65;
    return;
  }
  final apiKey = decoded['GEMINI_API_KEY']?.toString().trim() ?? '';
  if (apiKey.isEmpty) {
    stderr.writeln('GEMINI_API_KEY is empty.');
    exitCode = 78;
    return;
  }

  final service = LiveApiService();
  try {
    await service.connect(
      apiKey: apiKey,
      model: 'gemini-3.1-flash-live-preview',
      voice: 'Orus',
      systemInstruction:
          'You are a translation connection smoke test. Remain silent.',
    );
    stdout.writeln('Gemini Live setup completed successfully.');
  } on Object catch (error) {
    final safeMessage = error.toString().replaceAll(apiKey, '[REDACTED]');
    stderr.writeln('Gemini Live setup failed: $safeMessage');
    exitCode = 1;
  } finally {
    await service.disconnect();
  }
}
