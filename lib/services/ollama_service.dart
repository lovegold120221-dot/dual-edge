import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/app_config.dart';

class OllamaService {
  OllamaService({required this.config});

  final AppConfig config;

  bool _ollamaRunning = false;
  bool _modelAvailable = false;
  String? _lastError;

  String get url => config.ollamaUrl;
  String get modelName => config.modelName;
  bool get isRunning => _ollamaRunning;
  bool get isModelDownloaded => _modelAvailable;
  String? get lastError => _lastError;

  Future<void> init() async {
    await _checkAndStartOllama();
  }

  Uri _uri(String path) {
    final base = config.ollamaUrl.replaceAll(RegExp(r'/+$'), '');
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Uri.parse(path);
    }
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$normalized');
  }

  Future<void> _checkAndStartOllama() async {
    if (await _probeReady()) {
      return;
    }

    try {
      if (Platform.isMacOS) {
        await Process.run('open', <String>['-a', 'Ollama']);
      } else if (Platform.isWindows) {
        await Process.run('cmd', <String>['/c', 'start', '', 'ollama', 'app']);
      } else if (Platform.isLinux) {
        unawaited(Process.start('ollama', <String>['serve']).then((_) {}));
      }
    } catch (e) {
      _lastError = 'Failed to start Ollama: $e';
      if (kDebugMode) {
        debugPrint(_lastError);
      }
    }

    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (await _probeReady()) {
        return;
      }
    }

    _ollamaRunning = false;
    _lastError ??=
        'Ollama is not reachable at ${config.ollamaUrl}. '
        'Start the Ollama app and ensure model "${config.modelName}" is installed.';
  }

  /// Install hint shown when the daemon runs but the model is missing.
  /// eb-translator is a local Modelfile build, not a registry pull.
  static String installHint(String modelName) {
    final base = modelName.split(':').first;
    if (base == 'eb-translator') {
      return 'Install it with: ollama pull gemma3:4b && '
          'ollama create eb-translator -f Modelfile';
    }
    return 'Install it with: ollama pull $modelName';
  }

  Future<bool> _probeReady() async {
    try {
      final response = await http
          .get(_uri('/api/tags'))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) {
        return false;
      }
      _ollamaRunning = true;
      final body = json.decode(response.body);
      final models = <String>[];
      if (body is Map && body['models'] is List) {
        for (final entry in body['models'] as List<dynamic>) {
          if (entry is Map && entry['name'] != null) {
            models.add(entry['name'].toString());
          }
        }
      }
      _modelAvailable = _hasLocalModel(models, config.modelName);
      if (!_modelAvailable) {
        _lastError =
            'Ollama is running but local model "${config.modelName}" '
            'was not found. ${installHint(config.modelName)}';
      } else {
        _lastError = null;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Prefer exact / tag matches; never treat *:cloud as a local model.
  static bool _hasLocalModel(List<String> installed, String wanted) {
    final want = wanted.trim();
    if (want.isEmpty || want.contains(':cloud')) return false;
    final wantBase = want.split(':').first;
    for (final name in installed) {
      if (name.contains(':cloud')) continue;
      if (name == want || name == '$wantBase:latest') return true;
      if (name.split(':').first == wantBase) return true;
    }
    return false;
  }
}
