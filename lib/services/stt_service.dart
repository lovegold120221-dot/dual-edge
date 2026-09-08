import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'transcription_filters.dart';
import 'speech_backends.dart';

/// Local speech-to-text via Homebrew whisper.cpp (`whisper-cli`).
///
/// Requires `/opt/homebrew/bin/whisper-cli` (Apple Silicon Homebrew).
/// Prefers `ggml-small.bin` for bilingual accuracy; falls back to tiny/base
/// already on disk while small downloads in the background into Application
/// Support (and optionally mirrors under `assets/models`).
class SttService implements SttBackend {
  SttService({
    this.whisperCliPath = '/opt/homebrew/bin/whisper-cli',
    this.preferredModelFileName = 'ggml-small.bin',
    this.preferredModelUrl =
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin',
  });

  final String whisperCliPath;
  final String preferredModelFileName;
  final String preferredModelUrl;

  static const String _smallFileName = 'ggml-small.bin';
  static const String _baseFileName = 'ggml-base.bin';
  static const String _tinyFileName = 'ggml-tiny.bin';
  static const String _smallUrl =
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin';

  bool _initialized = false;
  bool _downloading = false;
  bool _transcribing = false;
  String? _lastError;
  String? _modelPath;
  String? _modelFileNameInUse;

  /// Whisper language code (`auto`, `en`, `nl`, …). Null/`auto` = autodetection.
  String _language = 'auto';

  @override
  Set<String> expectedScripts = <String>{'Latin'};

  final List<({List<int> pcm, bool isFinal})> _pendingChunks =
      <({List<int> pcm, bool isFinal})>[];

  final _onTranscription = StreamController<SttTranscript>.broadcast();
  @override
  Stream<SttTranscript> get onTranscription => _onTranscription.stream;

  /// True when whisper-cli and a usable model are ready for transcription.
  @override
  bool get isReady => _initialized && _modelPath != null;

  @override
  bool get isDownloading => _downloading;

  String? get modelPath => _modelPath;
  String? get modelFileNameInUse => _modelFileNameInUse;

  /// Optional language hint used when [autoDetect] is false.
  /// Maps display names (Dutch/Flemish → nl, English → en). Pass null/`auto`
  /// to keep autodetection.
  @override
  void setPreferredLanguage(String? languageOrCode, {bool autoDetect = true}) {
    if (autoDetect) {
      _language = 'auto';
      return;
    }
    _language = _mapLanguageHint(languageOrCode) ?? 'auto';
    if (kDebugMode) {
      debugPrint('SttService.preferredLanguage=$_language');
    }
  }

  static String? _mapLanguageHint(String? raw) {
    if (raw == null) return null;
    final s = raw.trim().toLowerCase();
    if (s.isEmpty || s == 'auto') return 'auto';
    // Already a whisper language code.
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

  /// Quick init: verify whisper-cli; use best on-disk model; prefetch small.
  @override
  Future<void> init() async {
    if (_initialized && _modelPath != null) return;
    try {
      final cli = File(whisperCliPath);
      if (!await cli.exists()) {
        throw StateError(
          'whisper-cli not found at $whisperCliPath. '
          'Install with: brew install whisper-cpp',
        );
      }

      final found = await _findBestExistingModel();
      if (found != null) {
        _modelPath = found.path;
        _modelFileNameInUse = found.fileName;
        _initialized = true;
        _lastError = null;
        if (kDebugMode) {
          debugPrint(
            'SttService.init ok model=$_modelPath '
            '($_modelFileNameInUse)',
          );
        }
        // Prefer small for accuracy — download in background if not already using it.
        if (_modelFileNameInUse != _smallFileName) {
          if (kDebugMode) {
            debugPrint(
              'SttService: using fallback $_modelFileNameInUse; '
              'prefetching $_smallFileName in background',
            );
          }
          unawaited(_downloadPreferredInBackground());
        }
        return;
      }

      // Nothing on disk — download preferred (small) in background.
      _lastError = 'Downloading Whisper model ($_smallFileName)…';
      if (kDebugMode) {
        debugPrint(
          'SttService: no model on disk, starting background download of $_smallFileName',
        );
      }
      unawaited(_downloadPreferredInBackground());
    } catch (e) {
      _lastError = e.toString();
      if (kDebugMode) {
        debugPrint('SttService.init error: $e');
      }
      rethrow;
    }
  }

  Future<({String path, String fileName})?> _findBestExistingModel() async {
    // Preference: small > base > tiny (accuracy first when already downloaded).
    final names = <String>[
      preferredModelFileName,
      _smallFileName,
      _baseFileName,
      _tinyFileName,
    ];
    final seen = <String>{};
    for (final name in names) {
      if (!seen.add(name)) continue;
      final path = await _locateModelFile(name);
      if (path != null) {
        return (path: path, fileName: name);
      }
    }
    return null;
  }

  Future<String?> _locateModelFile(String fileName) async {
    final support = await getApplicationSupportDirectory();
    final supportModel = File('${support.path}/models/$fileName');
    if (await supportModel.exists() && await supportModel.length() > 1000000) {
      return supportModel.path;
    }

    final assetsCandidates = <String>[
      '${Directory.current.path}/assets/models/$fileName',
      '/Users/masterdee/Documents/flutter-convert-translator-edge/assets/models/$fileName',
    ];
    for (final path in assetsCandidates) {
      final f = File(path);
      if (await f.exists() && await f.length() > 1000000) {
        await supportModel.parent.create(recursive: true);
        await f.copy(supportModel.path);
        if (kDebugMode) {
          debugPrint('SttService: copied assets model -> ${supportModel.path}');
        }
        return supportModel.path;
      }
    }
    return null;
  }

  Future<void> _downloadPreferredInBackground() async {
    if (_downloading) return;
    _downloading = true;
    final url = preferredModelUrl.isNotEmpty ? preferredModelUrl : _smallUrl;
    final fileName = preferredModelFileName.isNotEmpty
        ? preferredModelFileName
        : _smallFileName;
    try {
      // Skip if already present (race with another finder).
      final existing = await _locateModelFile(fileName);
      if (existing != null) {
        _modelPath = existing;
        _modelFileNameInUse = fileName;
        _initialized = true;
        _lastError = null;
        if (kDebugMode) {
          debugPrint(
            'SttService: preferred model already present at $existing',
          );
        }
        return;
      }

      final path = await _downloadModel(fileName: fileName, url: url);
      _modelPath = path;
      _modelFileNameInUse = fileName;
      _initialized = true;
      _lastError = null;
      if (kDebugMode) {
        debugPrint('SttService: background download ok model=$_modelPath');
      }
    } catch (e) {
      // Keep fallback model if we already had one; only set error if nothing works.
      if (_modelPath == null) {
        _lastError = e.toString();
      } else if (kDebugMode) {
        debugPrint(
          'SttService: preferred download failed (keeping $_modelFileNameInUse): $e',
        );
      }
      if (kDebugMode) {
        debugPrint('SttService: background download failed: $e');
      }
    } finally {
      _downloading = false;
    }
  }

  Future<String> _downloadModel({
    required String fileName,
    required String url,
  }) async {
    final support = await getApplicationSupportDirectory();
    final supportModel = File('${support.path}/models/$fileName');
    await supportModel.parent.create(recursive: true);
    final partial = File('${supportModel.path}.partial');
    if (kDebugMode) {
      debugPrint('SttService: downloading $url -> ${supportModel.path}');
    }
    // Progress via curl -# written to stderr; also log start/finish sizes.
    final result = await Process.run('curl', <String>[
      '-L',
      '--fail',
      '--retry',
      '3',
      '--retry-delay',
      '2',
      '-o',
      partial.path,
      url,
    ]);
    if (result.exitCode != 0 ||
        !await partial.exists() ||
        await partial.length() < 1000000) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      final err = (result.stderr ?? '').toString().trim();
      throw StateError(
        'Failed to download Whisper model (exit ${result.exitCode}): $err',
      );
    }
    if (await supportModel.exists()) {
      try {
        await supportModel.delete();
      } catch (_) {}
    }
    await partial.rename(supportModel.path);
    final len = await supportModel.length();
    if (kDebugMode) {
      debugPrint(
        'SttService: download complete ${supportModel.path} '
        '(${(len / (1024 * 1024)).toStringAsFixed(1)} MB)',
      );
    }

    // Best-effort mirror under assets/models for local dev (ignore failures).
    try {
      final assetsDir = Directory('${Directory.current.path}/assets/models');
      if (await assetsDir.exists()) {
        final mirror = File('${assetsDir.path}/$fileName');
        if (!await mirror.exists()) {
          await supportModel.copy(mirror.path);
        }
      }
    } catch (_) {}

    return supportModel.path;
  }

  @override
  void transcribeUtterance(List<int> pcmBytes, {bool isFinal = true}) {
    if (!_initialized || _modelPath == null || pcmBytes.isEmpty) return;
    if (_transcribing) {
      _pendingChunks.add((pcm: List<int>.from(pcmBytes), isFinal: isFinal));
      // Bound queue so we don't grow forever under load.
      while (_pendingChunks.length > 3) {
        _pendingChunks.removeAt(0);
      }
      return;
    }
    unawaited(_transcribeBytes(List<int>.from(pcmBytes), isFinal: isFinal));
  }

  /// True when the chunk is near silence (skip whisper to avoid hallucinations).
  /// Shared with the on-device sherpa backend.
  static bool _isNearSilence(List<int> pcmBytes) =>
      TranscriptionFilters.isNearSilence(pcmBytes);

  Future<void> _transcribeBytes(
    List<int> pcmBytes, {
    bool isFinal = true,
  }) async {
    if (pcmBytes.isEmpty || _modelPath == null) return;
    _transcribing = true;
    File? tempFile;
    try {
      // VAD delivers complete padded utterances; no overlap stitching needed.
      if (_isNearSilence(pcmBytes)) {
        if (kDebugMode) {
          debugPrint('SttService: silence gate — skip whisper');
        }
        // Do not emit to UI stream for silence skips.
        return;
      }

      tempFile = await _writeTempWav(pcmBytes);
      // Absolute path so whisper-cli never depends on cwd.
      final wavPath = tempFile.absolute.path;
      final lang = (_language.isEmpty) ? 'auto' : _language;
      final args = <String>[
        '-m',
        _modelPath!,
        '-f',
        wavPath,
        '-l',
        lang,
        '-np',
        '-nt',
        '-nth',
        '0.5',
      ];
      if (kDebugMode) {
        debugPrint(
          'SttService: whisper-cli lang=$lang model=$_modelFileNameInUse '
          'pcm=${pcmBytes.length}B',
        );
      }
      final result = await Process.run(whisperCliPath, args);
      if (result.exitCode != 0) {
        final err = ((result.stderr ?? result.stdout) ?? '').toString().trim();
        throw StateError('whisper-cli failed (exit ${result.exitCode}): $err');
      }
      _lastError = null;
      final text = _filterTranscription(_parseStdout(result.stdout));
      if (text.isNotEmpty && !_onTranscription.isClosed) {
        _onTranscription.add((
          text: text,
          languageCode: parseDetectedLanguage(result.stderr),
          isFinal: isFinal,
        ));
      }
    } catch (e) {
      _lastError = e.toString();
      if (kDebugMode) {
        debugPrint('SttService.transcribe error: $e');
      }
      if (!_onTranscription.isClosed) {
        _onTranscription.addError(e);
      }
    } finally {
      // Only delete after Process.run has fully completed (success or failure),
      // so whisper-cli is never still reading the file.
      await _safeDeleteTemp(tempFile);
      _transcribing = false;
      if (_pendingChunks.isNotEmpty) {
        final next = _pendingChunks.removeAt(0);
        unawaited(_transcribeBytes(next.pcm, isFinal: next.isFinal));
      }
    }
  }

  /// Parse whisper-cli stdout into a single trimmed transcription string.
  /// Shared with the on-device sherpa backend.
  static String _parseStdout(Object? stdout) =>
      TranscriptionFilters.parseCliLines(stdout);

  /// Detected language from whisper-cli stderr
  /// (`auto-detected language: nl (p = 0.97)`). '' when absent.
  /// Shared with the on-device sherpa backend.
  static String parseDetectedLanguage(Object? stderr) {
    final raw = stderr is List<int>
        ? utf8.decode(stderr, allowMalformed: true)
        : (stderr ?? '').toString();
    final match = RegExp(
      r'auto-detected language:\s*([a-zA-Z-]+)',
    ).firstMatch(raw);
    if (match == null) return '';
    return match.group(1)!.toLowerCase().split('-').first;
  }

  /// Filter hallucination / junk outputs before emitting.
  /// Shared with the on-device sherpa backend.
  String _filterTranscription(String raw) =>
      TranscriptionFilters.filterTranscription(
        raw,
        allowedScripts: expectedScripts,
      );

  /// Write PCM to Application Support/stt_tmp (not Caches/tmp alone).
  Future<File> _writeTempWav(List<int> pcmData) async {
    final support = await getApplicationSupportDirectory();
    final sttTmp = Directory('${support.path}/stt_tmp');
    await sttTmp.create(recursive: true);

    final file = File(
      '${sttTmp.path}/stt_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    // Ensure parent exists even if path resolution differs.
    await file.parent.create(recursive: true);

    final bytes = _buildWavBytes(pcmData);
    await file.writeAsBytes(bytes, flush: true);

    final abs = File(file.absolute.path);
    if (!await abs.exists()) {
      throw StateError('Failed to write temp WAV at ${abs.path}');
    }
    final len = await abs.length();
    if (len <= 44) {
      throw StateError(
        'Temp WAV too small ($len bytes, need > 44) at ${abs.path}',
      );
    }
    if (kDebugMode) {
      debugPrint('SttService: wrote temp WAV ${abs.path} ($len bytes)');
    }
    return abs;
  }

  /// Best-effort delete only after whisper-cli has finished with the file.
  Future<void> _safeDeleteTemp(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  /// Build a valid 16-bit mono PCM WAV at 16 kHz.
  static Uint8List _buildWavBytes(List<int> pcmData) {
    const sampleRate = 16000;
    const numChannels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * (bitsPerSample ~/ 8);
    final blockAlign = numChannels * (bitsPerSample ~/ 8);
    final dataSize = pcmData.length;
    const headerSize = 44;
    final totalSize = headerSize + dataSize;
    final buffer = Uint8List(totalSize);
    final bd = ByteData.sublistView(buffer);

    // RIFF header
    buffer[0] = 0x52; // R
    buffer[1] = 0x49; // I
    buffer[2] = 0x46; // F
    buffer[3] = 0x46; // F
    bd.setUint32(4, totalSize - 8, Endian.little);
    buffer[8] = 0x57; // W
    buffer[9] = 0x41; // A
    buffer[10] = 0x56; // V
    buffer[11] = 0x45; // E

    // fmt chunk
    buffer[12] = 0x66; // f
    buffer[13] = 0x6D; // m
    buffer[14] = 0x74; // t
    buffer[15] = 0x20; // space
    bd.setUint32(16, 16, Endian.little); // PCM fmt chunk size
    bd.setUint16(20, 1, Endian.little); // PCM format
    bd.setUint16(22, numChannels, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, blockAlign, Endian.little);
    bd.setUint16(34, bitsPerSample, Endian.little);

    // data chunk
    buffer[36] = 0x64; // d
    buffer[37] = 0x61; // a
    buffer[38] = 0x74; // t
    buffer[39] = 0x61; // a
    bd.setUint32(40, dataSize, Endian.little);
    buffer.setRange(headerSize, headerSize + dataSize, pcmData);
    return buffer;
  }

  @override
  void reset() {
    _pendingChunks.clear();
  }

  @override
  void dispose() {
    _pendingChunks.clear();
    if (!_onTranscription.isClosed) {
      _onTranscription.close();
    }
  }

  @override
  String? get lastError => _lastError;
}
