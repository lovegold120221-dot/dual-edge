import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

enum LiveEventType {
  inputTranscription,
  outputTranscription,
  modelText,
  audioData,
  turnComplete,
  interrupted,
  toolCall,
  error,
  done,
}

class LiveFunctionCall {
  const LiveFunctionCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
}

class LiveEvent {
  const LiveEvent({
    required this.type,
    this.text,
    this.isFinal = false,
    this.audioData,
    this.sampleRate,
    this.toolCalls = const <LiveFunctionCall>[],
  });

  final LiveEventType type;
  final String? text;
  final bool isFinal;
  final Uint8List? audioData;
  final int? sampleRate;
  final List<LiveFunctionCall> toolCalls;
}

class LiveApiService {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  StreamController<LiveEvent>? _events;
  Completer<void>? _setupCompleter;
  bool _setupComplete = false;
  bool _disconnecting = false;

  bool get isConnected => _channel != null && _setupComplete;

  Future<Stream<LiveEvent>> connect({
    required String apiKey,
    required String model,
    required String voice,
    required String systemInstruction,
  }) async {
    await disconnect();
    _disconnecting = false;
    _setupComplete = false;
    _events = StreamController<LiveEvent>.broadcast();
    _setupCompleter = Completer<void>();

    final uri = Uri.parse(
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1beta.GenerativeService.'
      'BidiGenerateContent?key=${Uri.encodeQueryComponent(apiKey)}',
    );

    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _subscription = channel.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
      await channel.ready.timeout(const Duration(seconds: 10));
      channel.sink.add(
        jsonEncode(_setupPayload(model, voice, systemInstruction)),
      );
      await _setupCompleter!.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException(
          'Gemini Live setup timed out after 15 seconds.',
        ),
      );
      return _events!.stream;
    } on Object {
      await disconnect();
      rethrow;
    }
  }

  Map<String, dynamic> _setupPayload(
    String model,
    String voice,
    String systemInstruction,
  ) {
    return <String, dynamic>{
      'setup': <String, dynamic>{
        'model': model.startsWith('models/') ? model : 'models/$model',
        'generationConfig': <String, dynamic>{
          'responseModalities': <String>['AUDIO'],
          'speechConfig': <String, dynamic>{
            'voiceConfig': <String, dynamic>{
              'prebuiltVoiceConfig': <String, dynamic>{'voiceName': voice},
            },
          },
        },
        'systemInstruction': <String, dynamic>{
          'parts': <Map<String, String>>[
            <String, String>{'text': systemInstruction},
          ],
        },
        'tools': <Map<String, dynamic>>[
          <String, dynamic>{
            'functionDeclarations': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'setGuestLanguage',
                'description':
                    'Update the latest paired non-Dutch/Flemish language. '
                    'Call whenever a new language from the OTHER group is detected.',
                'parameters': <String, dynamic>{
                  'type': 'OBJECT',
                  'properties': <String, dynamic>{
                    'language': <String, dynamic>{
                      'type': 'STRING',
                      'description':
                          'Exact language name, such as English, Tagalog, Spanish, or French.',
                    },
                  },
                  'required': <String>['language'],
                },
              },
            ],
          },
        ],
        'inputAudioTranscription': <String, dynamic>{},
        'outputAudioTranscription': <String, dynamic>{},
        'realtimeInputConfig': <String, dynamic>{
          'automaticActivityDetection': <String, dynamic>{
            'disabled': false,
            'startOfSpeechSensitivity': 'START_SENSITIVITY_HIGH',
            'endOfSpeechSensitivity': 'END_SENSITIVITY_HIGH',
            'prefixPaddingMs': 40,
            'silenceDurationMs': 500,
          },
        },
      },
    };
  }

  void sendAudio(Uint8List pcm16) {
    if (!_setupComplete || pcm16.isEmpty) return;
    _channel?.sink.add(
      jsonEncode(<String, dynamic>{
        'realtimeInput': <String, dynamic>{
          'audio': <String, dynamic>{
            'mimeType': 'audio/pcm;rate=16000',
            'data': base64Encode(pcm16),
          },
        },
      }),
    );
  }

  void sendToolResponse({
    required String id,
    required String name,
    required Map<String, dynamic> response,
  }) {
    if (!_setupComplete) return;
    _channel?.sink.add(
      jsonEncode(<String, dynamic>{
        'toolResponse': <String, dynamic>{
          'functionResponses': <Map<String, dynamic>>[
            <String, dynamic>{'id': id, 'name': name, 'response': response},
          ],
        },
      }),
    );
  }

  dynamic _pick(Map<dynamic, dynamic> map, String camel, String snake) {
    if (map.containsKey(camel)) return map[camel];
    return map[snake];
  }

  void _onMessage(dynamic data) {
    try {
      final text = switch (data) {
        String value => value,
        Uint8List value => utf8.decode(value),
        _ => '',
      };
      if (text.isEmpty) return;
      final message = jsonDecode(text);
      if (message is! Map) return;

      final apiError = message['error'];
      if (apiError != null) {
        final errorText = apiError is Map
            ? apiError['message']?.toString() ?? apiError.toString()
            : apiError.toString();
        _emit(LiveEvent(type: LiveEventType.error, text: errorText));
        if (_setupCompleter case final completer? when !completer.isCompleted) {
          completer.completeError(Exception(errorText));
        }
        return;
      }

      if (message['setupComplete'] != null ||
          message['setup_complete'] != null) {
        _setupComplete = true;
        if (_setupCompleter case final completer? when !completer.isCompleted) {
          completer.complete();
        }
        return;
      }

      final calls = _decodeToolCalls(message);
      if (calls.isNotEmpty) {
        _emit(LiveEvent(type: LiveEventType.toolCall, toolCalls: calls));
      }

      final serverContent = _pick(message, 'serverContent', 'server_content');
      if (serverContent is! Map) return;
      for (final event in _decodeServerContent(serverContent)) {
        _emit(event);
      }
    } on Object catch (error) {
      _emit(
        LiveEvent(
          type: LiveEventType.error,
          text: 'Could not decode a Gemini Live event: $error',
        ),
      );
    }
  }

  List<LiveEvent> decodeServerContentForTesting(
    Map<dynamic, dynamic> serverContent,
  ) => _decodeServerContent(serverContent);

  List<LiveEvent> _decodeServerContent(Map<dynamic, dynamic> serverContent) {
    final decodedEvents = <LiveEvent>[];
    final input = _pickFirst(serverContent, const <String>[
      'inputTranscription',
      'input_transcription',
      'inputAudioTranscription',
      'input_audio_transcription',
    ]);
    if (input is Map && input['text'] != null) {
      decodedEvents.add(
        LiveEvent(
          type: LiveEventType.inputTranscription,
          text: input['text'].toString(),
          isFinal: _transcriptionIsFinal(input),
        ),
      );
    }

    final modelText = StringBuffer();
    final modelTurn = _pick(serverContent, 'modelTurn', 'model_turn');
    if (modelTurn is Map && modelTurn['parts'] is List) {
      for (final part in modelTurn['parts'] as List) {
        if (part is! Map) continue;
        final inlineData = _pick(part, 'inlineData', 'inline_data');
        if (inlineData is Map && inlineData['data'] is String) {
          final mime =
              inlineData['mimeType']?.toString() ??
              inlineData['mime_type']?.toString() ??
              'audio/pcm;rate=24000';
          final rateMatch = RegExp(r'rate=(\d+)').firstMatch(mime);
          final sampleRate = int.tryParse(rateMatch?.group(1) ?? '') ?? 24000;
          decodedEvents.add(
            LiveEvent(
              type: LiveEventType.audioData,
              audioData: base64Decode(inlineData['data'] as String),
              sampleRate: sampleRate,
            ),
          );
        }
        if (part['text'] != null) modelText.write(part['text']);
      }
    }

    final output = _pickFirst(serverContent, const <String>[
      'outputTranscription',
      'output_transcription',
      'outputAudioTranscription',
      'output_audio_transcription',
    ]);
    if (output is Map && output['text'] != null) {
      decodedEvents.add(
        LiveEvent(
          type: LiveEventType.outputTranscription,
          text: output['text'].toString(),
          isFinal: _transcriptionIsFinal(output),
        ),
      );
    }
    if (modelText.isNotEmpty) {
      decodedEvents.add(
        LiveEvent(type: LiveEventType.modelText, text: modelText.toString()),
      );
    }

    if (_pick(serverContent, 'interrupted', 'interrupted') == true) {
      decodedEvents.add(const LiveEvent(type: LiveEventType.interrupted));
    }
    if (_pick(serverContent, 'turnComplete', 'turn_complete') == true) {
      decodedEvents.add(const LiveEvent(type: LiveEventType.turnComplete));
    }
    return decodedEvents;
  }

  dynamic _pickFirst(Map<dynamic, dynamic> map, List<String> keys) {
    for (final key in keys) {
      if (map.containsKey(key)) return map[key];
    }
    return null;
  }

  bool _transcriptionIsFinal(Map<dynamic, dynamic> transcription) {
    return transcription['isFinal'] == true ||
        transcription['is_final'] == true;
  }

  List<LiveFunctionCall> _decodeToolCalls(Map<dynamic, dynamic> message) {
    final toolCall = _pick(message, 'toolCall', 'tool_call');
    if (toolCall is! Map) return const <LiveFunctionCall>[];
    final rawCalls = _pick(toolCall, 'functionCalls', 'function_calls');
    if (rawCalls is! List) return const <LiveFunctionCall>[];
    final calls = <LiveFunctionCall>[];
    for (final raw in rawCalls) {
      if (raw is! Map) continue;
      final id = raw['id']?.toString() ?? '';
      final name = raw['name']?.toString() ?? '';
      dynamic rawArguments = raw['args'] ?? raw['arguments'];
      if (rawArguments is String) {
        try {
          rawArguments = jsonDecode(rawArguments);
        } on Object {
          rawArguments = <String, dynamic>{};
        }
      }
      if (id.isEmpty || name.isEmpty || rawArguments is! Map) continue;
      calls.add(
        LiveFunctionCall(
          id: id,
          name: name,
          arguments: Map<String, dynamic>.from(rawArguments),
        ),
      );
    }
    return calls;
  }

  void _onError(Object error, StackTrace stackTrace) {
    _emit(LiveEvent(type: LiveEventType.error, text: error.toString()));
    if (_setupCompleter case final completer? when !completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }

  void _onDone() {
    _setupComplete = false;
    if (!_disconnecting) {
      _emit(const LiveEvent(type: LiveEventType.done));
    }
  }

  void _emit(LiveEvent event) {
    final events = _events;
    if (events != null && !events.isClosed) events.add(event);
  }

  Future<void> disconnect() async {
    _disconnecting = true;
    _setupComplete = false;
    final completer = _setupCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(Exception('Disconnected'));
    }
    _setupCompleter = null;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    await _events?.close();
    _events = null;
  }
}
