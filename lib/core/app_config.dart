import '../data/eb_translator_prompt.dart';

import '../data/sherpa_speech_assets.dart';

class AppConfig {
  const AppConfig({
    required this.ollamaUrl,
    required this.modelName,
    this.kokoroTtsUrl = 'http://127.0.0.1:8880',
    this.onDeviceModelUrl = EbTranslatorPrompt.defaultGgufUrl,
    this.sttVariant = SherpaSpeechAssets.defaultSttVariant,
    this.googleServerClientId = '',
  });

  /// Local Ollama model used for translation on desktop.
  /// Built from gemma3:4b via the repo-root Modelfile:
  /// `ollama create eb-translator -f Modelfile`.
  /// Phones cannot run Ollama; they run the GGUF in [onDeviceModelUrl].
  static const defaultModel = 'eb-translator';

  factory AppConfig.fromEnvironment() {
    return const AppConfig(
      ollamaUrl: String.fromEnvironment(
        'OLLAMA_URL',
        defaultValue: 'http://localhost:11434',
      ),
      modelName: String.fromEnvironment(
        'OLLAMA_MODEL',
        defaultValue: defaultModel,
      ),
      kokoroTtsUrl: String.fromEnvironment(
        'KOKORO_TTS_URL',
        defaultValue: 'http://127.0.0.1:8880',
      ),
      onDeviceModelUrl: String.fromEnvironment(
        'EB_TRANSLATOR_GGUF_URL',
        defaultValue: EbTranslatorPrompt.defaultGgufUrl,
      ),
      sttVariant: String.fromEnvironment(
        'SHERPA_STT_VARIANT',
        defaultValue: SherpaSpeechAssets.defaultSttVariant,
      ),
      googleServerClientId: String.fromEnvironment(
        'GOOGLE_SERVER_CLIENT_ID',
        defaultValue: '',
      ),
    );
  }

  final String ollamaUrl;
  final String modelName;
  final String kokoroTtsUrl;

  /// GGUF weights downloaded once by phones for on-device inference.
  final String onDeviceModelUrl;

  /// Raw sherpa whisper variant (tiny|base); use [resolvedSttVariant].
  final String sttVariant;

  /// OAuth web client ID used as the audience for Google Sign-In ID tokens
  /// on Android. Empty disables native Google sign-in with a clear error.
  final String googleServerClientId;

  /// Normalized whisper variant for phones.
  String get resolvedSttVariant =>
      SherpaSpeechAssets.resolveSttVariant(sttVariant);

  bool get isOllamaConfigured => ollamaUrl.isNotEmpty;

  List<String> get missingRequiredVariables {
    final values = <String, String>{'OLLAMA_URL': ollamaUrl};
    return values.entries
        .where((entry) => entry.value.trim().isEmpty)
        .map((entry) => entry.key)
        .toList(growable: false);
  }
}
