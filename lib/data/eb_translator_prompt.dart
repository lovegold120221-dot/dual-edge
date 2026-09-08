/// Shared eb-translator prompt builders.
///
/// Used by both inference backends (desktop Ollama via `TranslationService`
/// and on-device llama.cpp via `OnDeviceLlmService`) so the model receives
/// byte-identical instructions on every platform.
///
/// Backend model is Gemma 3 4B (multilingual incl. Tagalog/Dutch). Qwen2.5
/// 0.5B–3B were tried and produce Tagalog word salad on medical sentences.
class EbTranslatorPrompt {
  /// GGUF weights for on-device inference (official Google QAT quant:
  /// near-fp16 quality at ~2.4 GB — needs a modern phone).
  static const defaultGgufFileName = 'gemma-3-4b-it-q4_0.gguf';

  static const defaultGgufUrl =
      'https://huggingface.co/google/gemma-3-4b-it-qat-q4_0-gguf/resolve/main/'
      '$defaultGgufFileName';

  /// Minimum plausible GGUF size in bytes (guards against truncated files).
  static const int minModelBytes = 1000 * 1024 * 1024;

  /// Deterministic sampling used on every backend (mirrors the Modelfile).
  static const double temperature = 0;
  static const double topP = 0.9;
  static const int topK = 40;
  static const int contextSize = 2048;
  static const int maxTokens = 512;

  /// Base system instruction. Callers may append a domain note; keep the
  /// whole string short — it is sent on every turn.
  static String system({bool medicalMode = false}) {
    final medicalNote = medicalMode ? ' Preserve medical terms precisely.' : '';
    return 'You are eb-translator, a strict translation engine. '
        'Output ONLY the translated text. '
        'Never return the source text unchanged.$medicalNote '
        'No commentary, explanations, notes, labels, preambles, or quotes.';
  }

  /// Fixed-direction prompt with optional conversation context.
  /// Context lines look like `source arrow translation` and help pronouns,
  /// terms, tone, and repair. Never repeated in the output.
  static String directed({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
    String? context,
  }) {
    final contextBlock = (context != null && context.trim().isNotEmpty)
        ? 'Recent conversation (source arrow translation):\n'
              '${context.trim()}\n'
              'Use it for pronouns, terms, tone, and repair. '
              'Do not repeat it.\n\n'
        : '';
    return '${contextBlock}Translate the following $sourceLanguage text '
        'to $targetLanguage. Output only the translation.\n\n'
        'Text:\n$text';
  }

  /// Second-stage rewrite: fluent native-speaker polish of a translation.
  /// Fixes grammar, word choice, rhythm, and TTS form. Output feeds speech.
  static String polishRewrite({
    required String text,
    required String targetLanguage,
  }) {
    return 'Rewrite the following $targetLanguage sentence exactly as a '
        'fluent native speaker would say it. Fix grammar, word choice, and '
        'rhythm. Use spoken-form numbers and normal punctuation, no symbols. '
        'Output ONLY the rewrite, nothing else.\n\n'
        'Text:\n$text';
  }
}
