import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/app_config.dart';
import '../data/eb_translator_prompt.dart';
import '../data/tts_voices.dart';
import 'ondevice_llm_service.dart';
import 'output_language_validator.dart';

/// Which inference backend handles a translation request.
enum LlmBackend { ollama, onDevice }

class TranslationService {
  TranslationService({required this.config, OnDeviceLlmService? onDevice})
    : _onDeviceOverride = onDevice;

  final AppConfig config;
  final OnDeviceLlmService? _onDeviceOverride;
  OnDeviceLlmService? _onDevice;
  String? _lastError;

  String? get lastError => _lastError;
  String get ollamaUrl => config.ollamaUrl;
  String get modelName => config.modelName;

  /// Phones run the GGUF on-device; desktop keeps the Ollama server.
  /// [overrideOnDevice] forces a backend (tests).
  static bool useOnDevice({bool? overrideOnDevice}) {
    if (overrideOnDevice != null) return overrideOnDevice;
    return OnDeviceLlmService.isSupported;
  }

  LlmBackend get backend =>
      useOnDevice() ? LlmBackend.onDevice : LlmBackend.ollama;

  OnDeviceLlmService get onDeviceService =>
      _onDeviceOverride ??
      (_onDevice ??= OnDeviceLlmService(ggufUrl: config.onDeviceModelUrl));

  Future<void> dispose() async {
    try {
      await _onDevice?.dispose();
    } catch (_) {}
    _onDevice = null;
  }

  Uri get _chatUri {
    final base = config.ollamaUrl.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base/api/chat');
  }

  /// Canonical local translator model (gemma3:4b via repo Modelfile).
  static const defaultModel = AppConfig.defaultModel;

  /// Resolve a safe local model name (never *:cloud / gemini).
  /// Legacy `eburon-mobile` installs predate the dedicated translator model
  /// and are canonicalized to [defaultModel].
  String resolveModel([String? preferred]) {
    final candidates = <String>[?preferred, config.modelName, defaultModel];
    for (final name in candidates) {
      final canonical = canonicalModelName(name);
      if (canonical.isNotEmpty) return canonical;
    }
    return defaultModel;
  }

  /// Map a stored/configured name to the model to request from Ollama.
  /// Returns '' when the name must not be used (cloud / gemini / empty).
  static String canonicalModelName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.contains(':cloud')) return '';
    if (trimmed.toLowerCase().contains('gemini')) return '';
    if (trimmed == 'eburon-mobile' ||
        trimmed.startsWith('eburon-mobile:') ||
        trimmed.endsWith('/eburon-mobile') ||
        trimmed.contains('eburon-mobile:')) {
      return defaultModel;
    }
    return trimmed;
  }

  /// Translate one turn with explicit direction, then polish it.
  ///
  /// Stage 1 translates meaning with conversation [context]; stage 2 rewrites
  /// the result as a fluent native speaker would say it (grammar, rhythm,
  /// TTS-clean form). If polishing fails or echoes, the stage-1 text is
  /// returned — output is never worse than a single translation call.
  ///
  /// The final text is validated to actually be [targetLanguage] (never an
  /// echo of the source, never a foreign script, never source-language
  /// wording). A failed validation returns null so wrong-language text can
  /// never reach history or TTS.
  /// [forceOnDevice] is test-only backend selection.
  Future<String?> translateTurn({
    required String sourceText,
    required String sourceLanguage,
    required String targetLanguage,
    String? context,
    String? systemPrompt,
    String? model,
    bool? forceOnDevice,
  }) async {
    final text = sourceText.trim();
    if (text.isEmpty) return null;

    final onDevice = useOnDevice(overrideOnDevice: forceOnDevice);
    final system = (systemPrompt != null && systemPrompt.trim().isNotEmpty)
        ? systemPrompt.trim()
        : EbTranslatorPrompt.system();

    Future<String?> requestOnce(String prompt) async {
      final raw = onDevice
          ? await _requestOnDeviceRaw(prompt, system: system)
          : await _requestOllamaRaw(
              prompt,
              system: system,
              modelName: resolveModel(model),
            );
      if (raw == null || raw.trim().isEmpty) return null;
      return sanitizeTranslation(raw);
    }

    bool valid(String candidate) => OutputLanguageValidator.matchesTarget(
      sourceText: text,
      outputText: candidate,
      sourceCode: TtsVoices.langCodeFor(sourceLanguage),
      targetCode: TtsVoices.langCodeFor(targetLanguage),
      targetScripts: OutputLanguageValidator.scriptsForTarget(
        TtsVoices.langCodeFor(targetLanguage),
      ),
    );

    final first = await requestOnce(
      EbTranslatorPrompt.directed(
        text: text,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        context: context,
      ),
    );
    if (first == null || first.isEmpty) return null;

    final polished = await requestOnce(
      EbTranslatorPrompt.polishRewrite(
        text: first,
        targetLanguage: targetLanguage,
      ),
    );
    final candidate = (polished == null || polished.isEmpty) ? first : polished;
    if (!valid(candidate)) {
      _lastError =
          'Output failed language validation (expected $targetLanguage)';
      return null;
    }
    _lastError = null;
    return candidate;
  }

  /// Raw model text for [prompt] (unsanitized; split/parse first).
  Future<String?> _requestOnDeviceRaw(
    String prompt, {
    required String system,
  }) async {
    final raw = await onDeviceService.complete(system: system, user: prompt);
    if (raw == null || raw.trim().isEmpty) {
      _lastError = onDeviceService.lastError ?? 'On-device translation failed';
      return null;
    }
    _lastError = null;
    return raw;
  }

  /// Raw model text for [prompt] (unsanitized; split/parse first).
  Future<String?> _requestOllamaRaw(
    String prompt, {
    required String system,
    required String modelName,
  }) async {
    final body = <String, dynamic>{
      'model': modelName,
      'stream': false,
      // Deterministic decoding to match the eb-translator Modelfile.
      'options': <String, dynamic>{
        'temperature': EbTranslatorPrompt.temperature,
        'top_p': EbTranslatorPrompt.topP,
        'top_k': EbTranslatorPrompt.topK,
        'num_ctx': EbTranslatorPrompt.contextSize,
        'num_predict': EbTranslatorPrompt.maxTokens,
      },
      'messages': <Map<String, String>>[
        <String, String>{'role': 'system', 'content': system},
        <String, String>{'role': 'user', 'content': prompt},
      ],
    };

    try {
      final response = await http
          .post(
            _chatUri,
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        _lastError = 'Ollama error ${response.statusCode}: ${response.body}';
        return null;
      }

      final data = json.decode(response.body);
      String? content;
      if (data is Map) {
        final message = data['message'];
        if (message is Map) {
          content = message['content']?.toString();
        }
        content ??= data['response']?.toString();
      }
      final translated = content?.trim();
      if (translated == null || translated.isEmpty) {
        _lastError = 'Ollama returned an empty translation';
        return null;
      }
      _lastError = null;
      return translated;
    } catch (e) {
      _lastError = e.toString();
      if (kDebugMode) {
        debugPrint('Translation error: $e');
      }
      return null;
    }
  }

  /// Strip LLM chatter so TTS only receives the translation.
  static String sanitizeTranslation(String value) {
    var text = value.trim();
    if (text.isEmpty) return text;

    // Drop common preamble lines.
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final preamble = RegExp(
      r'^(?:translation\s*:|here\s+is\s+(?:the\s+)?translation\s*:?|'
      r'sure[,.]?\s*|of\s+course[,.]?\s*|certainly[,.]?\s*|'
      r'i\s+(?:have\s+)?translated\s*:?|'
      r'the\s+translated\s+text\s*(?:is)?\s*:?|'
      r'output\s*:|result\s*:)\s*',
      caseSensitive: false,
    );

    final cleaned = <String>[];
    for (final line in lines) {
      var l = line.replaceFirst(preamble, '').trim();
      if (l.isEmpty) continue;
      // Whole-line preamble leftovers.
      if (RegExp(
        r'^(?:sure|here is(?: the)? translation|i translated|of course|certainly)[.!:]*$',
        caseSensitive: false,
      ).hasMatch(l)) {
        continue;
      }
      cleaned.add(l);
    }

    if (cleaned.isEmpty) {
      text = text.replaceFirst(preamble, '').trim();
    } else if (cleaned.length == 1) {
      text = cleaned.first;
    } else {
      // Prefer last non-empty line when earlier lines look like meta commentary.
      final meta = RegExp(
        r'^(?:translation|note|explanation|detected|language|source|target)\b',
        caseSensitive: false,
      );
      final nonMeta = cleaned.where((l) => !meta.hasMatch(l)).toList();
      if (nonMeta.isNotEmpty) {
        text = nonMeta.last;
      } else {
        text = cleaned.last;
      }
    }

    text = _stripWrappingQuotes(text);

    // Leading language-name label leaked by the model: "Dutch, …".
    text = text
        .replaceFirst(
          RegExp(
            r'^(?:english|dutch|flemish|tagalog|filipino|french|spanish|'
            r'german|italian|portuguese|arabic|hindi|japanese|chinese|'
            r'korean|russian|ukrainian|turkish|polish|indonesian|malay|'
            r'vietnamese|thai|bengali|tamil|urdu|persian|cebuano)\s*[:,]\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();

    // Leading label on a single line: "Translation: …"
    text = text
        .replaceFirst(
          RegExp(
            r'^(?:translation|translated(?:\s+text)?|output|result)\s*:\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();

    return _stripWrappingQuotes(text);
  }

  static String _stripWrappingQuotes(String value) {
    var text = value.trim();
    if (text.length >= 2) {
      final first = text[0];
      final last = text[text.length - 1];
      if ((first == '"' && last == '"') ||
          (first == "'" && last == "'") ||
          (first == '\u201C' && last == '\u201D') ||
          (first == '`' && last == '`')) {
        text = text.substring(1, text.length - 1).trim();
      }
    }
    return text;
  }
}
