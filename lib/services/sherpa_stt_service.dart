import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../data/sherpa_speech_assets.dart';
import 'local_model_store.dart';
import 'sherpa_worker.dart';
import 'speech_backends.dart';
import 'transcription_filters.dart';

/// Worker entry: owns the sherpa OfflineRecognizer (blocking native calls
/// stay off the UI thread).
Future<void> _sherpaSttWorkerMain(SendPort mainPort) async {
  sherpa.OfflineRecognizer? recognizer;
  var language = '';

  sherpa.OfflineRecognizer build(
    String encoder,
    String decoder,
    String tokens,
  ) {
    recognizer?.free();
    final whisper = sherpa.OfflineWhisperModelConfig(
      encoder: encoder,
      decoder: decoder,
      language: language,
      task: 'transcribe',
    );
    final model = sherpa.OfflineModelConfig(
      whisper: whisper,
      tokens: tokens,
      modelType: 'whisper',
      numThreads: 2,
    );
    final created = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(model: model),
    );
    recognizer = created;
    return created;
  }

  var encoderPath = '';
  var decoderPath = '';
  var tokensPath = '';

  await serveWorker(mainPort, (message, reply) async {
    switch (message['cmd']) {
      case 'initBindings':
        await sherpa.initBindingsAsync();
        reply(const <String, Object?>{'end': true, 'ok': true});
      case 'init':
        encoderPath = message['encoder']?.toString() ?? '';
        decoderPath = message['decoder']?.toString() ?? '';
        tokensPath = message['tokens']?.toString() ?? '';
        language = message['language']?.toString() ?? '';
        build(encoderPath, decoderPath, tokensPath);
        reply(const <String, Object?>{'end': true, 'ok': true});
      case 'setLanguage':
        language = message['language']?.toString() ?? '';
        if (encoderPath.isNotEmpty) {
          build(encoderPath, decoderPath, tokensPath);
        }
        reply(const <String, Object?>{'end': true, 'ok': true});
      case 'decode':
        final current = recognizer;
        if (current == null) {
          reply(const <String, Object?>{
            'end': true,
            'ok': false,
            'error': 'Recognizer not initialized',
          });
          return;
        }
        final samples = (message['samples'] as List).cast<double>();
        final stream = current.createStream();
        try {
          stream.acceptWaveform(
            samples: Float32List.fromList(samples),
            sampleRate: 16000,
          );
          current.decode(stream);
          final result = current.getResult(stream);
          reply(<String, Object?>{
            'end': true,
            'ok': true,
            'text': result.text.trim(),
            'lang': result.lang.trim().toLowerCase(),
          });
        } finally {
          stream.free();
        }
    }
  });
}

/// On-device speech-to-text for phones (sherpa whisper, multilingual).
///
/// Mirrors [SttService]'s public surface so [AppController] can swap backends
/// by platform: desktop keeps whisper-cli, phones use this.
class SherpaSttService implements SttBackend {
  SherpaSttService({String? sttVariant, this._store})
    : _variant = SherpaSpeechAssets.resolveSttVariant(sttVariant);

  final String _variant;
  final LocalModelStore? _store;
  LocalModelStore? _storeInstance;

  LocalModelStore get _models =>
      _store ?? (_storeInstance ??= LocalModelStore());

  /// Phones only; desktop keeps whisper-cli.
  static bool get isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  /// ~3.75s of 16 kHz mono PCM16 (bytes), mirroring SttService.
  static const int bufferSizeBytes = 120000;

  /// ~0.5s of previous PCM kept for continuity across chunk boundaries.
  static const int overlapBytes = 16000;

  bool _initialized = false;
  bool _downloading = false;
  bool _transcribing = false;
  double? _downloadProgress;
  String? _lastError;
  String _language = '';

  @override
  Set<String> expectedScripts = <String>{'Latin'};

  SherpaWorker? _worker;
  StreamSubscription<ModelDownloadProgress>? _downloadSubscription;

  final List<int> _pcmBuffer = <int>[];
  final List<List<int>> _pendingChunks = <List<int>>[];
  List<int> _overlapTail = <int>[];

  final _onTranscription = StreamController<SttTranscript>.broadcast();
  @override
  Stream<SttTranscript> get onTranscription => _onTranscription.stream;

  @override
  bool get isReady => _initialized && _worker != null;
  @override
  bool get isDownloading => _downloading;
  double? get downloadProgress => _downloadProgress;
  @override
  String? get lastError => _lastError;
  String get sttVariant => _variant;

  /// Same hint mapping as SttService (nl/en/fr/es/de); '' keeps auto-detect.
  @override
  void setPreferredLanguage(String? languageOrCode, {bool autoDetect = true}) {
    _language = autoDetect ? '' : (_mapLanguageHint(languageOrCode) ?? '');
    final worker = _worker;
    if (worker != null && _initialized) {
      unawaited(
        worker
            .callOnce('setLanguage', <String, Object?>{'language': _language})
            .catchError((Object _) => <String, Object?>{}),
      );
    }
    if (kDebugMode) {
      debugPrint('SherpaSttService.preferredLanguage=$_language');
    }
  }

  static String? _mapLanguageHint(String? raw) {
    if (raw == null) return null;
    final s = raw.trim().toLowerCase();
    if (s.isEmpty || s == 'auto') return null;
    if (RegExp(r'^[a-z]{2}(-[a-z]{2})?$').hasMatch(s) && s.length <= 5) {
      if (s.startsWith('nl') || s == 'dut' || s == 'nld') return 'nl';
      if (s.startsWith('en')) return 'en';
      return s.length == 2 ? s : s.substring(0, 2);
    }
    if (s.contains('dutch') ||
        s.contains('flemish') ||
        s.contains('nederlands')) {
      return 'nl';
    }
    if (s.contains('english') ||
        s.contains('american') ||
        s.contains('british')) {
      return 'en';
    }
    if (s.contains('french') ||
        s.contains('français') ||
        s.contains('francais')) {
      return 'fr';
    }
    if (s.contains('spanish') ||
        s.contains('español') ||
        s.contains('espanol')) {
      return 'es';
    }
    if (s.contains('german') || s.contains('deutsch')) return 'de';
    return null;
  }

  @override
  Future<void> init() async {
    if (_initialized && _worker != null) return;
    if (!isSupported) {
      throw StateError('On-device STT is only available on Android/iOS');
    }
    try {
      final files = SherpaSpeechAssets.sttFiles(_variant);
      if (!await _models.arePresent(files)) {
        _downloading = true;
        _downloadProgress = 0;
        _lastError = 'Downloading speech model (sherpa whisper $_variant)…';
        await _downloadSubscription?.cancel();
        _downloadSubscription = _models
            .ensureFiles(files)
            .listen(
              (event) {
                _downloadProgress = event.overallFraction >= 0
                    ? event.overallFraction
                    : null;
              },
              onError: (Object error) {
                _lastError = error.toString();
              },
            );
        await _downloadSubscription?.asFuture<void>();
        await _downloadSubscription?.cancel();
        _downloadSubscription = null;
        _downloading = false;
      }
      final dir = await _models.modelsDir();
      String path(String relative) => '${dir.path}/$relative';
      final fileList = SherpaSpeechAssets.sttFiles(_variant);
      final encoder = path(fileList[0].relativePath);
      final decoder = path(fileList[1].relativePath);
      final tokens = path(fileList[2].relativePath);

      _worker ??= await SherpaWorker.spawn(_sherpaSttWorkerMain);
      await _worker!.callOnce('initBindings');
      await _worker!.callOnce('init', <String, Object?>{
        'encoder': encoder,
        'decoder': decoder,
        'tokens': tokens,
        'language': _language,
      });
      _initialized = true;
      _downloadProgress = 1;
      _lastError = null;
      if (kDebugMode) {
        debugPrint('SherpaSttService.init ok variant=$_variant');
      }
    } catch (e) {
      _downloading = false;
      _lastError = e.toString();
      if (kDebugMode) {
        debugPrint('SherpaSttService.init error: $e');
      }
      rethrow;
    }
  }

  @override
  void feedPcmChunk(List<int> chunk) {
    if (!_initialized || _worker == null || chunk.isEmpty) return;
    _pcmBuffer.addAll(chunk);
    while (_pcmBuffer.length >= bufferSizeBytes) {
      final slice = List<int>.from(_pcmBuffer.sublist(0, bufferSizeBytes));
      _pcmBuffer.removeRange(0, bufferSizeBytes);
      _enqueue(slice);
    }
  }

  void _enqueue(List<int> pcmBytes) {
    if (_transcribing) {
      _pendingChunks.add(pcmBytes);
      while (_pendingChunks.length > 3) {
        _pendingChunks.removeAt(0);
      }
      return;
    }
    unawaited(_transcribeBytes(pcmBytes));
  }

  Future<void> _transcribeBytes(List<int> pcmBytes) async {
    if (pcmBytes.isEmpty || _worker == null) return;
    _transcribing = true;
    try {
      List<int> withOverlap = pcmBytes;
      if (_overlapTail.isNotEmpty) {
        withOverlap = <int>[..._overlapTail, ...pcmBytes];
      }
      if (pcmBytes.length >= overlapBytes) {
        _overlapTail = List<int>.from(
          pcmBytes.sublist(pcmBytes.length - overlapBytes),
        );
      } else {
        _overlapTail = List<int>.from(pcmBytes);
      }

      if (TranscriptionFilters.isNearSilence(pcmBytes)) {
        if (kDebugMode) {
          debugPrint('SherpaSttService: silence gate — skip decode');
        }
        return;
      }

      final samples = TranscriptionFilters.pcm16ToFloat(withOverlap);
      final reply = await _worker!.callOnce('decode', <String, Object?>{
        'samples': samples,
      });
      _lastError = null;
      final text = TranscriptionFilters.filterTranscription(
        reply['text']?.toString() ?? '',
        allowedScripts: expectedScripts,
      );
      if (text.isNotEmpty && !_onTranscription.isClosed) {
        _onTranscription.add((
          text: text,
          languageCode: reply['lang']?.toString() ?? '',
        ));
      }
    } catch (e) {
      _lastError = e.toString();
      if (kDebugMode) {
        debugPrint('SherpaSttService.transcribe error: $e');
      }
      if (!_onTranscription.isClosed) {
        _onTranscription.addError(e);
      }
    } finally {
      _transcribing = false;
      if (_pendingChunks.isNotEmpty) {
        final next = _pendingChunks.removeAt(0);
        unawaited(_transcribeBytes(next));
      }
    }
  }

  @override
  void reset() {
    _pcmBuffer.clear();
    _pendingChunks.clear();
    _overlapTail = <int>[];
  }

  @override
  void dispose() {
    _pcmBuffer.clear();
    _pendingChunks.clear();
    _overlapTail = <int>[];
    _downloadSubscription?.cancel();
    _downloadSubscription = null;
    _worker?.dispose();
    _worker = null;
    _initialized = false;
    if (_store == null) {
      unawaited(_storeInstance?.dispose());
      _storeInstance = null;
    }
    if (!_onTranscription.isClosed) {
      _onTranscription.close();
    }
  }
}
