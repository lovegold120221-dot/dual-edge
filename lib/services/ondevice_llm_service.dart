import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_llm/flutter_local_llm.dart';
import 'package:path_provider/path_provider.dart';

import '../data/eb_translator_prompt.dart';

/// On-device eb-translator inference for phones (llama.cpp via FFI).
///
/// Desktop keeps using Ollama over HTTP; Android/iOS cannot run an Ollama
/// server, so they run the same Qwen2.5 0.5B weights as a local GGUF file.
/// The ~400 MB model downloads once (resumable) into Application Support and
/// then works fully offline.
class OnDeviceLlmService {
  OnDeviceLlmService({String? ggufUrl, String? ggufFileName})
    : _ggufUrl = (ggufUrl != null && ggufUrl.trim().isNotEmpty)
          ? ggufUrl.trim()
          : EbTranslatorPrompt.defaultGgufUrl,
      _ggufFileName = (ggufFileName != null && ggufFileName.trim().isNotEmpty)
          ? ggufFileName.trim()
          : EbTranslatorPrompt.defaultGgufFileName;

  final String _ggufUrl;
  final String _ggufFileName;

  LocalLlmEngine? _engine;
  ModelDownloader? _downloader;
  StreamSubscription<DownloadProgress>? _downloadSubscription;
  bool _downloading = false;
  bool _generating = false;
  double? _downloadProgress;
  String? _lastError;

  final _progressController = StreamController<double?>.broadcast();
  Stream<double?> get onDownloadProgress => _progressController.stream;

  /// Phones only: Android + iOS. Desktop uses Ollama; web is unsupported.
  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  bool get isDownloading => _downloading;
  double? get downloadProgress => _downloadProgress;
  bool get isReady => _engine != null && !_engine!.isDisposed;
  String? get lastError => _lastError;
  String get ggufUrl => _ggufUrl;
  String get ggufFileName => _ggufFileName;

  Future<String> modelFilePath() async {
    final support = await getApplicationSupportDirectory();
    return '${support.path}/models/$_ggufFileName';
  }

  Future<bool> isModelDownloaded() async {
    try {
      final file = File(await modelFilePath());
      return await file.exists() &&
          await file.length() > EbTranslatorPrompt.minModelBytes;
    } catch (_) {
      return false;
    }
  }

  /// Download the GGUF once (resumes partial files). Reports 0..1 progress.
  Future<void> ensureModel({
    void Function(double? progress)? onProgress,
  }) async {
    if (await isModelDownloaded()) {
      _downloadProgress = 1;
      _emitProgress(1, onProgress);
      return;
    }
    if (_downloading) return;
    _downloading = true;
    _lastError = null;
    final completer = Completer<void>();
    try {
      final path = await modelFilePath();
      await File(path).parent.create(recursive: true);
      _downloader ??= ModelDownloader();
      await _downloadSubscription?.cancel();
      _downloadSubscription = _downloader!
          .download(url: _ggufUrl, destinationPath: path)
          .listen(
            (event) {
              if (event.status == DownloadStatus.failed ||
                  event.status == DownloadStatus.cancelled) {
                final message = (event.error ?? '').trim();
                _lastError = message.isEmpty
                    ? 'On-device model download ${event.status.name}'
                    : message;
                if (!completer.isCompleted) {
                  completer.completeError(StateError(_lastError!));
                }
                return;
              }
              if (event.totalBytes > 0) {
                _downloadProgress = event.progress.clamp(0.0, 1.0);
              }
              _emitProgress(_downloadProgress, onProgress);
              if (event.status == DownloadStatus.completed) {
                _downloadProgress = 1;
                _emitProgress(1, onProgress);
                if (!completer.isCompleted) completer.complete();
              }
            },
            onError: (Object error) {
              _lastError = error.toString();
              if (!completer.isCompleted) completer.completeError(error);
            },
            onDone: () {
              if (!completer.isCompleted) completer.complete();
            },
            cancelOnError: false,
          );
      await completer.future;
      // Guard against a truncated file that still reported success.
      if (!await isModelDownloaded()) {
        throw StateError(
          'Downloaded model file is incomplete; retry on a stable connection.',
        );
      }
      _lastError = null;
    } catch (e) {
      _lastError ??= e.toString();
      if (kDebugMode) {
        debugPrint('OnDeviceLlmService download error: $e');
      }
      rethrow;
    } finally {
      _downloading = false;
    }
  }

  void _emitProgress(double? value, void Function(double?)? onProgress) {
    try {
      if (!_progressController.isClosed) _progressController.add(value);
    } catch (_) {}
    try {
      onProgress?.call(value);
    } catch (_) {}
  }

  /// Load the model into memory (Metal on iOS, Vulkan/CPU on Android).
  /// Downloads first when the file is missing.
  Future<void> ensureLoaded() async {
    if (isReady) return;
    await ensureModel();
    final path = await modelFilePath();
    try {
      _engine = await LocalLlmEngine.loadModel(
        modelPath: path,
        params: const ModelParams(
          contextSize: EbTranslatorPrompt.contextSize,
          gpuLayers: 99,
        ),
      );
      _lastError = null;
      if (kDebugMode) {
        debugPrint('OnDeviceLlmService: engine ready ($path)');
      }
    } catch (e) {
      _lastError = e.toString();
      if (kDebugMode) {
        debugPrint('OnDeviceLlmService load error: $e');
      }
      rethrow;
    }
  }

  /// Chat template matching the loaded GGUF family.
  static ChatTemplate templateFor(String ggufFileName) {
    final name = ggufFileName.trim().toLowerCase();
    if (name.contains('gemma')) return const GemmaTemplate();
    if (name.contains('llama')) return const Llama3Template();
    return const ChatMlTemplate();
  }

  /// Single-turn completion with the eb-translator system prompt.
  /// Returns the raw assistant text (callers sanitize).
  Future<String?> complete({
    required String system,
    required String user,
  }) async {
    if (!isSupported) {
      _lastError = 'On-device inference is only available on Android/iOS';
      return null;
    }
    if (_generating) {
      _lastError = 'On-device model is already generating';
      return null;
    }
    try {
      await ensureLoaded();
    } catch (e) {
      _lastError ??= e.toString();
      return null;
    }
    final engine = _engine;
    if (engine == null || engine.isDisposed) {
      _lastError = 'On-device model is not loaded';
      return null;
    }
    _generating = true;
    LlmSession? session;
    final ChatTemplate template = templateFor(_ggufFileName);
    try {
      session = engine.createSession(defaultTemplate: template);
      final buffer = StringBuffer();
      final stream = session.chat(
        <ChatMessage>[ChatMessage.system(system), ChatMessage.user(user)],
        params: const SamplingParams(
          temperature: EbTranslatorPrompt.temperature,
          topP: EbTranslatorPrompt.topP,
          topK: EbTranslatorPrompt.topK,
          maxTokens: EbTranslatorPrompt.maxTokens,
        ),
      );
      await for (final token in stream) {
        buffer.write(token);
      }
      final text = buffer.toString().trim();
      if (text.isEmpty) {
        _lastError = 'On-device model returned an empty translation';
        return null;
      }
      _lastError = null;
      return text;
    } catch (e) {
      _lastError = e.toString();
      if (kDebugMode) {
        debugPrint('OnDeviceLlmService generate error: $e');
      }
      return null;
    } finally {
      _generating = false;
      try {
        session?.dispose();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    await _downloadSubscription?.cancel();
    _downloadSubscription = null;
    try {
      _downloader?.dispose();
    } catch (_) {}
    _downloader = null;
    try {
      _engine?.dispose();
    } catch (_) {}
    _engine = null;
    try {
      await _progressController.close();
    } catch (_) {}
  }
}
