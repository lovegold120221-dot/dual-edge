import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../data/sherpa_speech_assets.dart';
import '../data/tts_voices.dart';
import 'live_audio_service.dart';
import 'local_model_store.dart';
import 'sherpa_worker.dart';
import 'speech_backends.dart';

/// Convert normalized float samples to PCM16 little-endian bytes.
Uint8List float32ToPcm16(List<double> samples) {
  final bytes = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    view.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
  }
  return bytes;
}

/// Worker entry: owns one sherpa engine per language (blocking native calls
/// stay off the UI thread). Audio streams back chunk-by-chunk for low latency.
Future<void> _sherpaTtsWorkerMain(SendPort mainPort) async {
  final engines = <String, sherpa.OfflineTts>{};

  sherpa.OfflineTts buildSupertonic({
    required String durationPredictor,
    required String textEncoder,
    required String vectorEstimator,
    required String vocoder,
    required String ttsJson,
    required String unicodeIndexer,
    required String voiceStyle,
  }) {
    final supertonic = sherpa.OfflineTtsSupertonicModelConfig(
      durationPredictor: durationPredictor,
      textEncoder: textEncoder,
      vectorEstimator: vectorEstimator,
      vocoder: vocoder,
      ttsJson: ttsJson,
      unicodeIndexer: unicodeIndexer,
      voiceStyle: voiceStyle,
    );
    final config = sherpa.OfflineTtsModelConfig(
      supertonic: supertonic,
      numThreads: 2,
      debug: false,
    );
    return sherpa.OfflineTts(sherpa.OfflineTtsConfig(model: config));
  }

  sherpa.OfflineTts buildPiper({
    required String model,
    required String tokens,
    required String dataDir,
  }) {
    final vits = sherpa.OfflineTtsVitsModelConfig(
      model: model,
      tokens: tokens,
      dataDir: dataDir,
    );
    final config = sherpa.OfflineTtsModelConfig(
      vits: vits,
      numThreads: 2,
      debug: false,
    );
    return sherpa.OfflineTts(sherpa.OfflineTtsConfig(model: config));
  }

  await serveWorker(mainPort, (message, reply) async {
    switch (message['cmd']) {
      case 'initBindings':
        await sherpa.initBindingsAsync();
        reply(const <String, Object?>{'end': true, 'ok': true});
      case 'init-supertonic':
        engines['supertonic']?.free();
        final engine = buildSupertonic(
          durationPredictor: message['durationPredictor']?.toString() ?? '',
          textEncoder: message['textEncoder']?.toString() ?? '',
          vectorEstimator: message['vectorEstimator']?.toString() ?? '',
          vocoder: message['vocoder']?.toString() ?? '',
          ttsJson: message['ttsJson']?.toString() ?? '',
          unicodeIndexer: message['unicodeIndexer']?.toString() ?? '',
          voiceStyle: message['voiceStyle']?.toString() ?? '',
        );
        engines['supertonic'] = engine;
        reply(<String, Object?>{
          'end': true,
          'ok': true,
          'sampleRate': engine.sampleRate,
        });
      case 'init-piper':
        final key = message['key']?.toString() ?? '';
        if (key.isEmpty) {
          reply(const <String, Object?>{
            'end': true,
            'ok': false,
            'error': 'missing engine key',
          });
          return;
        }
        engines[key]?.free();
        final piper = buildPiper(
          model: message['model']?.toString() ?? '',
          tokens: message['tokens']?.toString() ?? '',
          dataDir: message['dataDir']?.toString() ?? '',
        );
        engines[key] = piper;
        reply(<String, Object?>{
          'end': true,
          'ok': true,
          'sampleRate': piper.sampleRate,
        });
      case 'stop-speak':
        _stopRequested.value = true;
        reply(const <String, Object?>{'end': true, 'ok': true});
      case 'speak':
        final key = message['key']?.toString() ?? 'supertonic';
        final selected = engines[key];
        if (selected == null) {
          reply(<String, Object?>{
            'end': true,
            'ok': false,
            'error': 'TTS engine not initialized: $key',
          });
          return;
        }
        _stopRequested.value = false;
        final text = message['text']?.toString() ?? '';
        final sid = (message['sid'] is int) ? message['sid'] as int : 0;
        if (key == 'supertonic') {
          // Per-request language via generation extra; single-shot result.
          final lang = message['lang']?.toString() ?? 'en';
          final result = selected.generateWithConfig(
            text: text,
            config: sherpa.OfflineTtsGenerationConfig(
              sid: sid,
              speed: 1.0,
              silenceScale: 0.2,
              numSteps: 8,
              extra: <String, Object>{'lang': lang},
            ),
          );
          if (_stopRequested.value || result.samples.isEmpty) {
            reply(<String, Object?>{
              'end': true,
              'ok': _stopRequested.value,
              'sampleRate': selected.sampleRate,
              'totalSamples': 0,
            });
            return;
          }
          reply(<String, Object?>{
            'end': false,
            'audio': result.samples,
            'sampleRate': result.sampleRate,
          });
          reply(<String, Object?>{
            'end': true,
            'ok': true,
            'sampleRate': result.sampleRate,
            'totalSamples': result.samples.length,
          });
        } else {
          // Piper: stream partial chunks as they generate.
          var totalSamples = 0;
          selected.generateWithCallback(
            text: text,
            sid: sid,
            speed: 1.0,
            callback: (Float32List samples) {
              totalSamples += samples.length;
              reply(<String, Object?>{
                'end': false,
                'audio': samples,
                'sampleRate': selected.sampleRate,
              });
              // sherpa convention: non-zero return aborts generation.
              return _stopRequested.value ? 1 : 0;
            },
          );
          reply(<String, Object?>{
            'end': true,
            'ok': !_stopRequested.value,
            'sampleRate': selected.sampleRate,
            'totalSamples': totalSamples,
          });
        }
    }
  });
}

/// Mutable flag shared with the worker closure above (each isolate holds its
/// own copy; the worker's copy is the one the callback reads).
class _StopFlag {
  bool value = false;
}

final _stopRequested = _StopFlag();

/// On-device text-to-speech for phones (sherpa: Supertonic for 31 languages,
/// per-language Piper voices otherwise).
///
/// Mirrors [TtsService]'s public surface so [AppController] can swap backends
/// by platform: desktop keeps the TTS server, phones synthesize locally and
/// play through the native duplex output ([LiveAudioService]).
class SherpaTtsService implements TtsBackend {
  SherpaTtsService({this._audio, this._store});

  final LiveAudioService? _audio;
  final LocalModelStore? _store;
  LocalModelStore? _storeInstance;

  LocalModelStore get _models =>
      _store ?? (_storeInstance ??= LocalModelStore());

  /// Phones only; desktop keeps the TTS server.
  static bool get isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  /// Supertonic speaker IDs by measured pitch (male ≈ 97-164 Hz,
  /// female ≈ 220-245 Hz). Male is the default voice.
  static const int maleSid = 6;
  static const int femaleSid = 0;

  /// Legacy feminine voice ids (mirrors TranslationSettings).
  static const Set<String> feminineVoices = <String>{
    'female',
    'af_heart',
    'bf_emma',
    'ff_siwis',
    'if_sara',
    'pf_dora',
    'jf_alpha',
    'zf_xiaobei',
    'hf_alpha',
  };

  /// Supertonic sid for a requested voice (male default).
  static int sidForVoice(String? voice) {
    final v = (voice ?? '').trim().toLowerCase();
    if (v == 'female' || feminineVoices.contains(v)) return femaleSid;
    return maleSid;
  }

  /// Engine key for Supertonic.
  static const String supertonicKey = 'supertonic';

  bool _downloading = false;
  bool _speaking = false;
  bool _stopped = false;
  double? _downloadProgress;
  final _rates = <String, int>{};
  String? _lastError;

  /// Requested voice gender ('male' default); selects the Supertonic sid.
  String _voice = 'male';

  SherpaWorker? _worker;

  final _speakingController = StreamController<bool>.broadcast();
  @override
  Stream<bool> get onSpeakingChanged => _speakingController.stream;
  @override
  bool get isSpeaking => _speaking;
  bool get isDownloading => _downloading;
  double? get downloadProgress => _downloadProgress;
  @override
  String? get lastError => _lastError;

  int rateFor(String key) => _rates[key] ?? 24000;

  Future<SherpaWorker> _ensureWorker() async {
    var worker = _worker;
    if (worker == null) {
      worker = await SherpaWorker.spawn(_sherpaTtsWorkerMain);
      _worker = worker;
      await worker.callOnce('initBindings');
    }
    return worker;
  }

  /// Engine key for [language] (Supertonic vs Piper bundle language).
  static String engineKeyFor(String? language) {
    final spec = TtsVoices.forLanguage(language);
    if (spec.isPiper) return TtsVoices.langCodeFor(language);
    return supertonicKey;
  }

  /// Synthesis language code for [language] (Supertonic `lang` extra).
  static String synthLangFor(String? language) {
    final code = TtsVoices.langCodeFor(language);
    if (TtsVoices.supertonicLangs.contains(code)) return code;
    return 'en';
  }

  @override
  Future<void> init() => ensureLanguage(null);

  /// Make sure the engine for [language] is downloaded and loaded.
  /// Null language prepares Supertonic English.
  Future<void> ensureLanguage(String? language) async {
    if (!isSupported) {
      throw StateError('On-device TTS is only available on Android/iOS');
    }
    final spec = TtsVoices.forLanguage(language);
    if (spec.isPiper) {
      await _ensurePiper(TtsVoices.langCodeFor(language), spec.piperBundle);
    } else {
      await _ensureSupertonic();
    }
  }

  Future<void> _ensureSupertonic() async {
    if (_rates.containsKey(supertonicKey)) return;
    _downloading = true;
    _downloadProgress = 0;
    _lastError = 'Downloading speech model (Supertonic)…';
    try {
      final dir = await _models.ensureTarBz2(
        bundle: SherpaSpeechAssets.supertonicBundle(),
        targetDirName: TtsVoices.supertonicDirName,
      );
      String path(String name) => '${dir.path}/$name';
      final worker = await _ensureWorker();
      final reply = await worker.callOnce('init-supertonic', <String, Object?>{
        'durationPredictor': path('duration_predictor.int8.onnx'),
        'textEncoder': path('text_encoder.int8.onnx'),
        'vectorEstimator': path('vector_estimator.int8.onnx'),
        'vocoder': path('vocoder.int8.onnx'),
        'ttsJson': path('tts.json'),
        'unicodeIndexer': path('unicode_indexer.bin'),
        'voiceStyle': path('voice.bin'),
      });
      _storeRate(supertonicKey, reply);
      _downloading = false;
      _downloadProgress = 1;
      _lastError = null;
      if (kDebugMode) {
        debugPrint(
          'SherpaTtsService: supertonic ready (${rateFor(supertonicKey)} Hz)',
        );
      }
    } catch (e) {
      _downloading = false;
      _lastError = e.toString();
      rethrow;
    }
  }

  Future<void> _ensurePiper(String lang, String bundle) async {
    if (_rates.containsKey(lang)) return;
    _downloading = true;
    _downloadProgress = 0;
    _lastError = 'Downloading speech model (Piper $lang)…';
    try {
      final targetDir = TtsVoices.piperDirName(bundle);
      final dir = await _models.modelsDir();
      await _models.ensureTarBz2(
        bundle: SherpaSpeechAssets.piperBundle(bundle),
        targetDirName: targetDir,
      );
      final extracted = Directory('${dir.path}/$targetDir');
      final found = await _findPiperFiles(extracted);
      if (found == null) {
        throw StateError('Piper bundle incomplete after extraction: $bundle');
      }
      final worker = await _ensureWorker();
      final reply = await worker.callOnce('init-piper', <String, Object?>{
        'key': lang,
        'model': found.model,
        'tokens': found.tokens,
        'dataDir': await _resolvePiperDataDir(extracted),
      });
      _storeRate(lang, reply);
      _downloading = false;
      _downloadProgress = 1;
      _lastError = null;
      if (kDebugMode) {
        debugPrint(
          'SherpaTtsService: piper ready ($lang, ${rateFor(lang)} Hz)',
        );
      }
    } catch (e) {
      _downloading = false;
      _lastError = e.toString();
      rethrow;
    }
  }

  Future<({String model, String tokens})?> _findPiperFiles(
    Directory dir,
  ) async {
    String? onnx;
    String? tokens;
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final p = entity.path;
        if (p.endsWith('.onnx') && !p.endsWith('.json')) onnx ??= p;
        if (p.endsWith('tokens.txt')) tokens = p;
      }
    } catch (_) {
      return null;
    }
    if (onnx == null || tokens == null) return null;
    return (model: onnx, tokens: tokens);
  }

  Future<String> _resolvePiperDataDir(Directory bundleDir) async {
    final bundled = Directory('${bundleDir.path}/espeak-ng-data');
    if (await bundled.exists()) return bundled.path;
    return _ensureEspeakDir();
  }

  Future<String> _ensureEspeakDir() async {
    final target = await _models.ensureUnzipped(
      zip: SherpaSpeechAssets.espeakDataZip(),
      targetDirName:
          '${SherpaSpeechAssets.ttsDirName}/${SherpaSpeechAssets.espeakDataDirName}',
    );
    return target.path;
  }

  void _storeRate(String key, Map<String, Object?> reply) {
    final rate = reply['sampleRate'];
    _rates[key] = (rate is int && rate > 0) ? rate : 24000;
  }

  /// Accepted for API parity with TtsService; the voice always follows the
  /// synthesis language (Supertonic/Piper native voice, else Supertonic en).
  /// [voice] selects the Supertonic speaker gender (male default).
  @override
  Future<void> configure({String? language, String? voice}) async {
    if (voice != null && voice.trim().isNotEmpty) {
      _voice = voice.trim();
    }
    await ensureLanguage(language);
  }

  /// Synthesize [text] locally in the voice for [language] and play it
  /// through the native output. Resolves when playback finishes.
  @override
  Future<void> speak(String text, {String? language}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final key = engineKeyFor(language);
    await ensureLanguage(language);
    final worker = _worker;
    if (worker == null) return;
    try {
      await stop();
      _lastError = null;
      _stopped = false;
      _setSpeaking(true);
      final rate = rateFor(key);
      await _audio?.prepareOutput(rate);

      final startedAt = DateTime.now();
      var totalSamples = 0;
      await for (final event in worker.call('speak', <String, Object?>{
        'key': key,
        'text': trimmed,
        'sid': sidForVoice(_voice),
        'lang': synthLangFor(language),
      })) {
        if (_stopped) break;
        final audio = event['audio'];
        final chunkRate = event['sampleRate'];
        if (audio is Float32List && audio.isNotEmpty) {
          totalSamples += audio.length;
          final pcm = float32ToPcm16(audio);
          await _audio?.playPcmChunk(
            pcm,
            (chunkRate is int && chunkRate > 0) ? chunkRate : rate,
          );
        }
        if (event['end'] == true) {
          final reported = event['totalSamples'];
          if (reported is int && reported > 0) totalSamples = reported;
          break;
        }
      }

      // Native playback buffers ahead; wait out the remainder so the
      // speaking flag (and mic echo gate) cover the audible tail.
      if (!_stopped && totalSamples > 0) {
        final expected = Duration(
          milliseconds: (totalSamples / rate * 1000).round(),
        );
        final elapsed = DateTime.now().difference(startedAt);
        final remaining = expected - elapsed;
        if (remaining > Duration.zero) {
          await Future<void>.delayed(remaining);
        }
      }
    } catch (e) {
      _lastError = e.toString();
      if (kDebugMode) {
        debugPrint('SherpaTtsService.speak error: $e');
      }
    } finally {
      _setSpeaking(false);
    }
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    try {
      _worker?.notify('stop-speak');
    } catch (_) {}
    try {
      await _audio?.stopOutput();
    } catch (_) {}
    _setSpeaking(false);
  }

  @override
  Future<void> dispose() async {
    await stop();
    _worker?.dispose();
    _worker = null;
    _rates.clear();
    if (_store == null) {
      try {
        await _storeInstance?.dispose();
      } catch (_) {}
      _storeInstance = null;
    }
    try {
      await _speakingController.close();
    } catch (_) {}
  }

  void _setSpeaking(bool value) {
    _speaking = value;
    if (!_speakingController.isClosed) {
      try {
        _speakingController.add(value);
      } catch (_) {}
    }
  }
}
