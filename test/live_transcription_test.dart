import 'package:dual_translate/services/live_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes Vite-compatible realtime transcription fields', () {
    final service = LiveApiService();
    addTearDown(service.disconnect);

    final events = service.decodeServerContentForTesting(<String, dynamic>{
      'inputTranscription': <String, dynamic>{
        'text': 'Magandang ',
        'isFinal': false,
      },
      'outputTranscription': <String, dynamic>{
        'text': 'Goede dag',
        'isFinal': true,
      },
      'modelTurn': <String, dynamic>{
        'parts': <Map<String, String>>[
          <String, String>{'text': 'Goedendag'},
        ],
      },
      'turnComplete': true,
    });

    expect(events.map((event) => event.type), <LiveEventType>[
      LiveEventType.inputTranscription,
      LiveEventType.outputTranscription,
      LiveEventType.modelText,
      LiveEventType.turnComplete,
    ]);
    expect(events[0].text, 'Magandang ');
    expect(events[0].isFinal, isFalse);
    expect(events[1].text, 'Goede dag');
    expect(events[1].isFinal, isTrue);
    expect(events[2].text, 'Goedendag');
  });

  test('also decodes snake-case transcription fields', () {
    final service = LiveApiService();
    addTearDown(service.disconnect);

    final events = service.decodeServerContentForTesting(<String, dynamic>{
      'input_transcription': <String, dynamic>{
        'text': 'Hello',
        'is_final': true,
      },
      'output_transcription': <String, dynamic>{
        'text': 'Hallo',
        'is_final': false,
      },
    });

    expect(events, hasLength(2));
    expect(events[0].type, LiveEventType.inputTranscription);
    expect(events[0].isFinal, isTrue);
    expect(events[1].type, LiveEventType.outputTranscription);
    expect(events[1].isFinal, isFalse);
  });
}
