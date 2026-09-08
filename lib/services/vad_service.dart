import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../data/sherpa_speech_assets.dart';
import 'local_model_store.dart';
import 'transcription_filters.dart';

/// One complete speech utterance (16 kHz mono PCM16).
class VadUtterance {
  const VadUtterance(this.pcmBytes, {this.isFinal = true});

  final Uint8List pcmBytes;

  /// False when cut by the max-speech cap rather than natural silence:
  /// more speech is still coming, so the transcript is a fragment.
  final bool isFinal;
}

/// Voice activity detection (sherpa Silero) shared by every platform.
///
/// Mic frames go in; complete utterances come out. Words are never cut
/// mid-utterance, and silence/noise never reaches speech recognition, so
/// whisper decodes far less audio and hallucinates far less often.
///
/// Falls back to fixed windows when the model is unavailable (first-run
/// offline), so transcription keeps working everywhere.
class VadService {
  VadService({this._store});

  final LocalModelStore? _store;
  LocalModelStore? _storeInstance;

  LocalModelStore get _models =>
      _store ?? (_storeInstance ??= LocalModelStore());

  /// Silero window: 512 samples (32 ms) at 16 kHz.
  static const int windowSamples = 512;

  /// Pre-speech audio kept so plosive onsets are never clipped.
  static const int preSpeechSamples = 4096; // ~0.25 s

  /// Fallback window when the VAD model is unavailable (~3.75 s).
  static const int fallbackWindowBytes = 120000;

  sherpa.VoiceActivityDetector? _detector;
  String? _lastError;
  bool _downloading = false;

  final List<double> _windowRemainder = <double>[];
  final List<double> _ring = <double>[];
  final List<int> _fallbackBuffer = <int>[];

  bool get isReady => _detector != null;
  bool get isDownloading => _downloading;
  String? get lastError => _lastError;

  Future<void> init() async {
    if (_detector != null) return;
    _downloading = true;
    _lastError = null;
    try {
      await _models.ensureFiles(<ModelFileRef>[
        SherpaSpeechAssets.vadModel(),
      ]).drain<void>();
      final dir = await _models.modelsDir();
      final modelPath =
          '${dir.path}/${SherpaSpeechAssets.vadModel().relativePath}';
      try {
        await sherpa.initBindingsAsync();
      } catch (_) {}
      final config = sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: modelPath,
          threshold: 0.5,
          // Wait out mid-sentence pauses: only real end-of-utterance
          // silence finalizes a transcript. Never cut slow speakers.
          minSilenceDuration: 0.9,
          minSpeechDuration: 0.25,
          windowSize: windowSamples,
          maxSpeechDuration: 15,
        ),
        sampleRate: 16000,
        numThreads: 1,
        debug: false,
      );
      _detector = sherpa.VoiceActivityDetector(
        config: config,
        bufferSizeInSeconds: 30,
      );
      _lastError = null;
      if (kDebugMode) {
        debugPrint('VadService: silero ready ($modelPath)');
      }
    } catch (e) {
      _lastError = e.toString();
      if (kDebugMode) {
        debugPrint('VadService.init error (fallback windows): $e');
      }
    } finally {
      _downloading = false;
    }
  }

  /// Feed 16 kHz mono PCM16 bytes; returns utterances completed by this feed.
  List<VadUtterance> feed(List<int> pcmBytes) {
    final detector = _detector;
    if (detector == null) return _feedFallback(pcmBytes);
    if (pcmBytes.isEmpty) return const <VadUtterance>[];
    final out = <VadUtterance>[];
    final samples = TranscriptionFilters.pcm16ToFloat(pcmBytes);
    var offset = 0;
    // Prepend leftover from the previous feed to keep windows whole.
    final pending = <double>[..._windowRemainder, ...samples];
    _windowRemainder.clear();
    while (offset + windowSamples <= pending.length) {
      final window = Float32List.fromList(
        pending.sublist(offset, offset + windowSamples),
      );
      offset += windowSamples;
      _pushRing(window);
      try {
        detector.acceptWaveform(window);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('VadService.accept error: $e');
        }
        continue;
      }
      try {
        while (!detector.isEmpty()) {
          final segment = detector.front();
          detector.pop();
          out.add(_toUtterance(segment.samples));
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('VadService.drain error: $e');
        }
      }
    }
    if (offset < pending.length) {
      _windowRemainder.addAll(pending.sublist(offset));
    }
    return out;
  }

  /// Samples at which a segment counts as max-speech cut (not silence end).
  static const int maxSpeechCutSamples = 15 * 16000 - 512;

  VadUtterance _toUtterance(Float32List segment) {
    // Prepend pre-speech audio so onsets are never clipped.
    final padded = <double>[..._ring, ...segment];
    // Segments hitting the duration cap are fragments: more speech follows.
    final isFinal = segment.length < maxSpeechCutSamples;
    return VadUtterance(_floatToPcm16(padded), isFinal: isFinal);
  }

  void _pushRing(Float32List window) {
    _ring.addAll(window);
    while (_ring.length > preSpeechSamples) {
      _ring.removeRange(0, _ring.length - preSpeechSamples);
    }
  }

  Uint8List _floatToPcm16(List<double> samples) {
    final bytes = Uint8List(samples.length * 2);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      view.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
    }
    return bytes;
  }

  /// Fixed-window fallback (VAD model unavailable): same ~3.75 s windows
  /// the pipeline used before VAD, so nothing downstream changes.
  List<VadUtterance> _feedFallback(List<int> pcmBytes) {
    final out = <VadUtterance>[];
    if (pcmBytes.isEmpty) return out;
    _fallbackBuffer.addAll(pcmBytes);
    while (_fallbackBuffer.length >= fallbackWindowBytes) {
      out.add(
        VadUtterance(
          Uint8List.fromList(_fallbackBuffer.sublist(0, fallbackWindowBytes)),
        ),
      );
      _fallbackBuffer.removeRange(0, fallbackWindowBytes);
    }
    return out;
  }

  void reset() {
    _windowRemainder.clear();
    _ring.clear();
    _fallbackBuffer.clear();
    try {
      _detector?.reset();
    } catch (_) {}
  }

  Future<void> dispose() async {
    reset();
    try {
      _detector?.free();
    } catch (_) {}
    _detector = null;
    if (_store == null) {
      try {
        await _storeInstance?.dispose();
      } catch (_) {}
      _storeInstance = null;
    }
  }
}
