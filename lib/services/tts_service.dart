import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'speech_backends.dart';
import 'live_audio_service.dart';

/// Local multilingual TTS via a small Node HTTP server (afplay on macOS).
///
/// Speaks only the final translated string — never source/transcription.
/// Played audio is registered with [LiveAudioService] as an echo reference
/// so the microphone never re-captures speaker output as user input.
class TtsService implements TtsBackend {
  TtsService({String? baseUrl, this._audio})
    : _baseUrl =
          (baseUrl ??
                  const String.fromEnvironment(
                    'KOKORO_TTS_URL',
                    defaultValue: 'http://127.0.0.1:8880',
                  ))
              .replaceAll(RegExp(r'/+$'), '');

  final String _baseUrl;

  /// Echo-reference sink for played audio (set by AppController).
  final LiveAudioService? _audio;
  bool _initialized = false;
  bool _speaking = false;
  String? _lastError;
  String _voice = 'af_heart';
  final double _speed = 1.0;
  Process? _serverProcess;
  Process? _playProcess;

  final _speakingController = StreamController<bool>.broadcast();
  @override
  Stream<bool> get onSpeakingChanged => _speakingController.stream;
  @override
  bool get isSpeaking => _speaking;
  @override
  String? get lastError => _lastError;

  Uri get _healthUri => Uri.parse('$_baseUrl/health');
  Uri get _ttsUri => Uri.parse('$_baseUrl/tts');

  @override
  Future<void> init() async {
    if (_initialized) return;
    try {
      final ok = await _ensureServer();
      _initialized = ok;
      if (!ok) {
        _lastError ??= 'Kokoro TTS server unavailable at $_baseUrl';
      }
    } catch (e) {
      _lastError = e.toString();
      if (kDebugMode) {
        debugPrint('TtsService.init error: $e');
      }
    }
  }

  /// Map a display language name (or BCP-47 tag) to a Kokoro voice id.
  static String voiceForLanguage(String language) {
    final raw = language.trim();
    if (raw.isEmpty) return 'af_heart';
    final lower = raw.toLowerCase();
    // Already a Kokoro voice id (e.g. af_heart, am_adam).
    if (RegExp(r'^[a-z]{2}_[a-z0-9]+$').hasMatch(lower)) return lower;
    const map = <String, String>{
      'english': 'af_heart',
      'english (us)': 'af_heart',
      'english (uk)': 'bf_emma',
      'english (british)': 'bf_emma',
      'american': 'af_heart',
      'british': 'bf_emma',
      'dutch': 'af_heart',
      'french': 'ff_siwis',
      'spanish': 'ef_dora',
      'italian': 'if_sara',
      'portuguese': 'pf_dora',
      'japanese': 'jf_alpha',
      'chinese': 'zf_xiaobei',
      'mandarin': 'zf_xiaobei',
      'hindi': 'hf_alpha',
    };
    if (map.containsKey(lower)) return map[lower]!;
    for (final entry in map.entries) {
      if (lower.startsWith(entry.key) || lower.contains(entry.key)) {
        return entry.value;
      }
    }
    return 'af_heart';
  }

  @override
  Future<void> configure({String? language, String? voice}) async {
    await init();
    try {
      if (voice != null && voice.trim().isNotEmpty) {
        final v = voice.trim().toLowerCase();
        if (v == 'male' || v == 'female') {
          // Gender voice: the server selects the Supertonic speaker.
          _voice = v;
        } else if (v.contains('|')) {
          // Legacy flutter_tts "name|locale" — ignore name, map locale/language.
          final parts = v.split('|');
          _voice = voiceForLanguage(parts.length >= 2 ? parts[1] : parts[0]);
        } else if (RegExp(
          r'^[a-z]{2}_[a-z0-9]+$',
          caseSensitive: false,
        ).hasMatch(v)) {
          _voice = v.toLowerCase();
        } else {
          _voice = voiceForLanguage(v);
        }
      } else if (language != null && language.isNotEmpty) {
        _voice = voiceForLanguage(language);
      }
    } catch (e) {
      _lastError = e.toString();
      if (kDebugMode) {
        debugPrint('TtsService.configure error: $e');
      }
    }
  }

  /// True when [text] looks like LLM commentary rather than a translation.
  static bool looksLikeCommentary(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    return RegExp(
      r'^(?:sure\b|here\s+is\b|i\s+translated\b|of\s+course\b|'
      r'certainly\b|the\s+translation\b|i\s+have\s+translated\b)',
      caseSensitive: false,
    ).hasMatch(t);
  }

  /// Speak only the final translated string aloud. Never source text.
  /// [language] selects the server voice: English stays on Kokoro, other
  /// covered languages use native Piper voices, the rest fall back to Kokoro.
  @override
  Future<void> speak(String text, {String? language}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    if (looksLikeCommentary(trimmed)) {
      _lastError = 'Skipped TTS: text looks like commentary';
      if (kDebugMode) {
        debugPrint('TtsService.speak skipped commentary: $trimmed');
      }
      return;
    }

    await init();
    if (!_initialized) return;
    try {
      if (language != null) {
        await configure(language: language);
      }
      _lastError = null;
      await stop();

      final healthy = await _ensureServer();
      if (!healthy) {
        _lastError ??= 'Kokoro TTS server unavailable at $_baseUrl';
        return;
      }

      final response = await http
          .post(
            _ttsUri,
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: json.encode(<String, Object>{
              'text': trimmed,
              'voice': _voice,
              'language': (language ?? '').trim(),
              'speed': _speed,
            }),
          )
          .timeout(const Duration(seconds: 120));

      if (response.statusCode != 200) {
        _lastError =
            'Kokoro TTS error ${response.statusCode}: ${response.body}';
        return;
      }

      final bytes = response.bodyBytes;
      if (bytes.isEmpty) {
        _lastError = 'Kokoro TTS returned empty audio';
        return;
      }

      // Echo reference BEFORE playback so speaker output is never
      // re-captured as microphone input.
      _audio?.registerTtsPlayback(bytes);

      await _playWavBytes(bytes);
    } catch (e) {
      _lastError = e.toString();
      _setSpeaking(false);
      if (kDebugMode) {
        debugPrint('TtsService.speak error: $e');
      }
    }
  }

  @override
  Future<void> stop() async {
    try {
      _playProcess?.kill(ProcessSignal.sigterm);
    } catch (_) {}
    _playProcess = null;
    _setSpeaking(false);
  }

  @override
  Future<void> dispose() async {
    await stop();
    try {
      _serverProcess?.kill(ProcessSignal.sigterm);
    } catch (_) {}
    _serverProcess = null;
    await _speakingController.close();
  }

  void _setSpeaking(bool value) {
    _speaking = value;
    if (!_speakingController.isClosed) {
      _speakingController.add(value);
    }
  }

  Future<bool> _healthOk() async {
    try {
      final response = await http
          .get(_healthUri)
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ensureServer() async {
    if (await _healthOk()) return true;
    if (kIsWeb) return false;
    if (!Platform.isMacOS && !Platform.isLinux) {
      // afplay path is macOS; still allow health if user started server.
      return false;
    }

    final serverDir = _resolveServerDir();
    if (serverDir == null) {
      _lastError =
          'Kokoro TTS server not running and tool/kokoro-tts-server not found';
      return false;
    }

    try {
      final node = _resolveNodeBinary();
      _serverProcess = await Process.start(
        node,
        <String>['server.js'],
        workingDirectory: serverDir.path,
        mode: ProcessStartMode.detachedWithStdio,
        environment: <String, String>{
          ...Platform.environment,
          'HOST': '127.0.0.1',
          'PORT': _baseUrlUri.port.toString(),
        },
      );
      if (kDebugMode) {
        debugPrint(
          'TtsService: started Kokoro server pid=${_serverProcess!.pid} in ${serverDir.path}',
        );
      }
    } catch (e) {
      _lastError = 'Failed to start Kokoro TTS server: $e';
      return false;
    }

    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (await _healthOk()) return true;
    }
    _lastError = 'Kokoro TTS server did not become healthy at $_baseUrl';
    return false;
  }

  Uri get _baseUrlUri {
    try {
      return Uri.parse(_baseUrl);
    } catch (_) {
      return Uri.parse('http://127.0.0.1:8880');
    }
  }

  Directory? _resolveServerDir() {
    final candidates = <String>[
      'tool/kokoro-tts-server',
      '../tool/kokoro-tts-server',
      '../../tool/kokoro-tts-server',
      '../../../tool/kokoro-tts-server',
      '/Users/masterdee/Documents/flutter-convert-translator-edge/tool/kokoro-tts-server',
    ];
    try {
      candidates.insert(0, '${Directory.current.path}/tool/kokoro-tts-server');
    } catch (_) {}
    for (final path in candidates) {
      final dir = Directory(path);
      final serverJs = File('${dir.path}/server.js');
      if (serverJs.existsSync()) return dir.absolute;
    }
    return null;
  }

  String _resolveNodeBinary() {
    final fromEnv = Platform.environment['NODE_BINARY'];
    if (fromEnv != null && fromEnv.isNotEmpty && File(fromEnv).existsSync()) {
      return fromEnv;
    }
    final candidates = <String>[
      '/Users/masterdee/.local/share/fnm/aliases/default/bin/node',
      '/opt/homebrew/bin/node',
      '/usr/local/bin/node',
      '/usr/bin/node',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return 'node';
  }

  Future<void> _playWavBytes(List<int> bytes) async {
    if (!Platform.isMacOS) {
      _lastError = 'WAV playback via afplay is only implemented on macOS';
      return;
    }
    final tmpDir = await getTemporaryDirectory();
    final file = File(
      '${tmpDir.path}/kokoro_tts_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(bytes, flush: true);
    _setSpeaking(true);
    try {
      _playProcess = await Process.start('afplay', <String>[file.path]);
      final code = await _playProcess!.exitCode;
      if (code != 0 && _lastError == null) {
        _lastError = 'afplay exited with code $code';
      }
    } finally {
      _playProcess = null;
      _setSpeaking(false);
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}
