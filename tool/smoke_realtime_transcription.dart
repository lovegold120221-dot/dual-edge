import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dual_translate/services/live_api_service.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/smoke_realtime_transcription.dart '
      '<config-json> <16-khz-mono-pcm16-file>',
    );
    exitCode = 64;
    return;
  }

  final configFile = File(arguments[0]);
  final audioFile = File(arguments[1]);
  if (!configFile.existsSync() || !audioFile.existsSync()) {
    stderr.writeln('Configuration or PCM audio file was not found.');
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
  StreamSubscription<LiveEvent>? subscription;
  try {
    final events = await service.connect(
      apiKey: apiKey,
      model: 'gemini-3.1-flash-live-preview',
      voice: 'Orus',
      systemInstruction:
          'You are a pure realtime translator. Translate English speech only '
          'into Dutch. Speak exactly and only the translation.',
    );
    final inputText = StringBuffer();
    final outputText = StringBuffer();
    final turnComplete = Completer<void>();
    subscription = events.listen((event) {
      switch (event.type) {
        case LiveEventType.inputTranscription:
          inputText.write(event.text ?? '');
        case LiveEventType.outputTranscription:
          outputText.write(event.text ?? '');
        case LiveEventType.turnComplete:
          if (!turnComplete.isCompleted) turnComplete.complete();
        case LiveEventType.error:
          if (!turnComplete.isCompleted) {
            turnComplete.completeError(StateError(event.text ?? 'Live error'));
          }
        case _:
          break;
      }
    });

    final audio = await audioFile.readAsBytes();
    const frameSize = 3200;
    for (var offset = 0; offset < audio.length; offset += frameSize) {
      final end = offset + frameSize < audio.length
          ? offset + frameSize
          : audio.length;
      service.sendAudio(Uint8List.sublistView(audio, offset, end));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    for (var index = 0; index < 18; index++) {
      service.sendAudio(Uint8List(frameSize));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    await turnComplete.future.timeout(const Duration(seconds: 30));
    if (inputText.toString().trim().isEmpty ||
        outputText.toString().trim().isEmpty) {
      throw StateError(
        'The Live turn completed without both transcription streams.',
      );
    }
    stdout.writeln(
      'Realtime input and output transcription events were received.',
    );
  } on Object catch (error) {
    final safeMessage = error.toString().replaceAll(apiKey, '[REDACTED]');
    stderr.writeln('Realtime transcription smoke failed: $safeMessage');
    exitCode = 1;
  } finally {
    await subscription?.cancel();
    await service.disconnect();
  }
}
