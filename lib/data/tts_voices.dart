/// Canonical text-to-speech voice table, shared by both TTS backends.
///
/// Supertonic 3 covers 31 languages in one bundle (best quality, used
/// first); remaining covered languages use per-language Piper voices
/// (native phonemes); anything else falls back to Supertonic English.
/// (The desktop server additionally serves gap languages via local MMS.)
///
/// NOTE: keep the Piper entries in sync with
/// tool/kokoro-tts-server/server.js (PIPER_VOICES).
enum TtsEngineKind { supertonic, piper }

class TtsVoiceSpec {
  const TtsVoiceSpec.supertonic()
    : kind = TtsEngineKind.supertonic,
      piperBundle = '';

  const TtsVoiceSpec.piper(this.piperBundle) : kind = TtsEngineKind.piper;

  final TtsEngineKind kind;

  /// sherpa bundle base name, e.g. `zh_CN-huayan-medium`
  /// (downloaded as `vits-piper-<bundle>-int8.tar.bz2`).
  final String piperBundle;

  bool get isPiper => kind == TtsEngineKind.piper;
}

class TtsVoices {
  /// Supertonic 3 language codes (ISO 639-1), one shared bundle.
  static const Set<String> supertonicLangs = <String>{
    'en',
    'ko',
    'ja',
    'ar',
    'bg',
    'cs',
    'da',
    'de',
    'el',
    'es',
    'et',
    'fi',
    'fr',
    'hi',
    'hr',
    'hu',
    'id',
    'it',
    'lt',
    'lv',
    'nl',
    'pl',
    'pt',
    'ro',
    'ru',
    'sk',
    'sl',
    'sv',
    'tr',
    'uk',
    'vi',
  };

  /// Two-letter language code → Piper voice (languages outside Supertonic).
  static const Map<String, TtsVoiceSpec> byLang = <String, TtsVoiceSpec>{
    'ca': TtsVoiceSpec.piper('ca_ES-upc_ona-medium'),
    'cy': TtsVoiceSpec.piper('cy_GB-gwryw_gogleddol-medium'),
    'eu': TtsVoiceSpec.piper('eu_ES-antton-medium'),
    'fa': TtsVoiceSpec.piper('fa_IR-amir-medium'),
    'is': TtsVoiceSpec.piper('is_IS-steinn-medium'),
    'ku': TtsVoiceSpec.piper('ku_TR-berfin_renas-medium'),
    'lb': TtsVoiceSpec.piper('lb_LU-marylux-medium'),
    'ml': TtsVoiceSpec.piper('ml_IN-arjun-medium'),
    'ne': TtsVoiceSpec.piper('ne_NP-chitwan-medium'),
    'no': TtsVoiceSpec.piper('no_NO-talesyntese-medium'),
    'sq': TtsVoiceSpec.piper('sq_AL-edon-medium'),
    'sr': TtsVoiceSpec.piper('sr_RS-serbski_institut-medium'),
    'sw': TtsVoiceSpec.piper('sw_CD-lanfrica-medium'),
    'ur': TtsVoiceSpec.piper('ur_PK-fasih-medium'),
  };

  /// Bundle file name for a Piper voice (sherpa tts-models release).
  static String piperBundleFile(String bundle) =>
      'vits-piper-$bundle-int8.tar.bz2';

  static String piperBundleUrl(String bundle) =>
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
      'tts-models/${piperBundleFile(bundle)}';

  /// Directory the bundle extracts to (contains model .onnx + tokens.txt).
  static String piperDirName(String bundle) => 'vits-piper-$bundle-int8';

  /// Supertonic 3 sherpa bundle (one bundle, 31 languages).
  static const String supertonicBundleFile =
      'sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2';
  static const String supertonicDirName =
      'sherpa-onnx-supertonic-3-tts-int8-2026-05-11';
  static String supertonicBundleUrl() =>
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
      'tts-models/$supertonicBundleFile';

  /// Normalize a display name ("Dutch (Flemish)"), BCP-47 tag ("nl", "fr-BE"),
  /// or legacy Kokoro voice id ("af_heart", "ff_siwis") to a two-letter code.
  static String langCodeFor(String? input) {
    final raw = (input ?? '').trim().toLowerCase();
    if (raw.isEmpty || raw == 'auto') return 'en';
    // Legacy Kokoro voice ids map back to their language.
    const voiceToLang = <String, String>{
      'orus': 'en',
      'ef_dora': 'es',
      'ff_siwis': 'fr',
      'hf_alpha': 'hi',
      'if_sara': 'it',
      'jf_alpha': 'ja',
      'pf_dora': 'pt',
      'zf_xiaobei': 'zh',
    };
    if (voiceToLang.containsKey(raw)) return voiceToLang[raw]!;
    if (supertonicLangs.contains(raw) || byLang.containsKey(raw)) return raw;
    if (raw.startsWith('en-') || raw.startsWith('en_')) return 'en';
    if (raw.length >= 2) {
      final two = raw.substring(0, 2);
      if (supertonicLangs.contains(two) || byLang.containsKey(two)) {
        return two;
      }
    }
    if (raw.contains('dutch') ||
        raw.contains('flemish') ||
        raw.contains('nederlands')) {
      return 'nl';
    }
    if (raw.contains('english') ||
        raw.contains('american') ||
        raw.contains('british')) {
      return 'en';
    }
    if (raw.contains('french') || raw.contains('fran')) return 'fr';
    if (raw.contains('spanish') || raw.contains('espa')) return 'es';
    if (raw.contains('german') || raw.contains('deutsch')) return 'de';
    if (raw.contains('italian')) return 'it';
    if (raw.contains('portug')) return 'pt';
    if (raw.contains('arab') || raw.contains('darija')) return 'ar';
    if (raw.contains('turk')) return 'tr';
    if (raw.contains('polish') || raw.contains('polski')) return 'pl';
    if (raw.contains('romanian')) return 'ro';
    if (raw.contains('ukrain')) return 'uk';
    if (raw.contains('hindi')) return 'hi';
    if (raw.contains('chinese') || raw.contains('mandarin')) return 'zh';
    if (raw.contains('indones')) return 'id';
    if (raw.contains('vietnam')) return 'vi';
    if (raw.contains('russian')) return 'ru';
    if (raw.contains('korean')) return 'ko';
    if (raw.contains('japanese')) return 'ja';
    if (raw.contains('catalan')) return 'ca';
    if (raw.contains('welsh') || raw.contains('cymraeg')) return 'cy';
    if (raw.contains('basque')) return 'eu';
    if (raw.contains('persian') || raw.contains('farsi')) return 'fa';
    if (raw.contains('icelandic')) return 'is';
    if (raw.contains('kurdish')) return 'ku';
    if (raw.contains('luxembourg')) return 'lb';
    if (raw.contains('malayalam')) return 'ml';
    if (raw.contains('malay') || raw.contains('malaysian')) return 'ms';
    if (raw.contains('nepali')) return 'ne';
    if (raw.contains('norwegian')) return 'no';
    if (raw.contains('albanian')) return 'sq';
    if (raw.contains('serbian')) return 'sr';
    if (raw.contains('swahili')) return 'sw';
    if (raw.contains('urdu')) return 'ur';
    if (raw.contains('tagalog') || raw.contains('filipino')) return 'tl';
    if (raw.contains('cebuano')) return 'ceb';
    if (raw.contains('thai')) return 'th';
    if (raw.contains('bengali')) return 'bn';
    if (raw.contains('tamil')) return 'ta';
    if (raw.contains('telugu')) return 'te';
    if (raw.contains('marathi')) return 'mr';
    if (raw.contains('gujarati')) return 'gu';
    if (raw.contains('kannada')) return 'kn';
    if (raw.contains('burmese') || raw.contains('myanmar')) return 'my';
    if (raw.contains('khmer')) return 'kh';
    if (raw.contains('lao')) return 'lo';
    if (raw.contains('shona')) return 'sn';
    if (raw.contains('chichewa') || raw.contains('nyanja')) return 'ny';
    if (raw.contains('malagasy')) return 'mg';
    if (raw.contains('mongolian')) return 'mon';
    if (raw.contains('samoan')) return 'sm';
    if (raw.contains('hausa')) return 'ha';
    if (raw.contains('yoruba')) return 'yo';
    if (raw.contains('somali')) return 'so';
    if (raw.contains('amharic')) return 'am';
    if (raw.contains('tajik')) return 'tg';
    if (raw.contains('kazakh')) return 'kk';
    if (raw.contains('kyrgyz')) return 'ky';
    if (raw.contains('hebrew')) return 'he';
    if (raw.contains('hawaiian')) return 'haw';
    if (raw.contains('maori')) return 'mi';
    if (raw.contains('georgian')) return 'ka';
    if (raw.contains('armenian')) return 'hy';
    if (raw.contains('azerbaijani')) return 'az';
    if (raw.contains('belarusian')) return 'be';
    if (raw.contains('galician')) return 'gl';
    if (raw.contains('croatian')) return 'hr';
    if (raw.contains('bosnian')) return 'bs';
    if (raw.contains('macedonian')) return 'mk';
    if (raw.contains('maltese')) return 'mt';
    if (raw.contains('irish')) return 'ga';
    if (raw.contains('sinhala') || raw.contains('sinhalese')) return 'si';
    if (raw.contains('pashto')) return 'ps';
    if (raw.contains('cantonese')) return 'yue';
    return 'en';
  }

  /// Voice spec for a display name / tag / voice id (Supertonic fallback).
  static TtsVoiceSpec forLanguage(String? input) {
    final code = langCodeFor(input);
    if (supertonicLangs.contains(code)) {
      return const TtsVoiceSpec.supertonic();
    }
    return byLang[code] ?? const TtsVoiceSpec.supertonic();
  }
}
