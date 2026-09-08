import '../data/eb_translator_prompt.dart';
import '../data/sherpa_speech_assets.dart';
import '../data/tts_voices.dart';
import 'local_model_store.dart';

/// Offline readiness: every model a translation session needs, verified
/// from local files with zero network calls.
///
/// Required on phones: translator GGUF, whisper STT, Supertonic TTS.
/// Piper voice + espeak data are required only when the guest language
/// needs them. VAD is best-effort (fixed windows cover its absence).
class OfflineReadiness {
  const OfflineReadiness({required this.missing});

  /// Human-readable labels of what still needs a Wi-Fi download.
  final List<String> missing;

  bool get isReady => missing.isEmpty;

  String get message => isReady
      ? 'Offline ready.'
      : 'Offline models missing — connect to Wi-Fi once to download: '
            '${missing.join(', ')}.';

  static Future<OfflineReadiness> check({
    required LocalModelStore store,
    required String sttVariant,
    required String guestLanguage,
  }) async {
    final missing = <String>[];

    // Translator GGUF (stored directly under the models dir).
    if (!await store.isPresent(
      ModelFileRef(
        url: '',
        relativePath: EbTranslatorPrompt.defaultGgufFileName,
        minBytes: EbTranslatorPrompt.minModelBytes,
      ),
    )) {
      missing.add('Translator (eb-translator)');
    }

    // Speech recognition (whisper).
    final variant = SherpaSpeechAssets.resolveSttVariant(sttVariant);
    if (!await store.arePresent(SherpaSpeechAssets.sttFiles(variant))) {
      missing.add('Speech recognition (whisper $variant)');
    }

    // Speech synthesis (Supertonic always; Piper per guest language).
    if (!await store.isFilePresent(
      '${TtsVoices.supertonicDirName}/.extracted',
    )) {
      missing.add('Speech synthesis (Supertonic)');
    }
    final spec = TtsVoices.forLanguage(guestLanguage);
    if (spec.isPiper) {
      final dir = TtsVoices.piperDirName(spec.piperBundle);
      if (!await store.isFilePresent('$dir/.extracted')) {
        missing.add(
          'Speech synthesis (Piper ${TtsVoices.langCodeFor(guestLanguage)})',
        );
      } else if (!await store.isFilePresent('$dir/espeak-ng-data/phontab') &&
          !await store.isFilePresent(
            '${SherpaSpeechAssets.ttsDirName}/${SherpaSpeechAssets.espeakDataDirName}/.extracted',
          )) {
        missing.add('Speech data (espeak)');
      }
    }

    return OfflineReadiness(missing: missing);
  }
}
