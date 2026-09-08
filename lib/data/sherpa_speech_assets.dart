import 'tts_voices.dart';

/// On-device speech model assets (sherpa-onnx, phones only).
///
/// Desktop keeps whisper.cpp ggml bins + the Kokoro server; phones
/// download these once (resumable) into Application Support and then run
/// fully offline.
class ModelFileRef {
  const ModelFileRef({
    required this.url,
    required this.relativePath,
    required this.minBytes,
  });

  /// Remote URL (Hugging Face resolve or GitHub release asset).
  final String url;

  /// Path relative to the models dir, e.g. `sherpa-whisper-base/encoder.onnx`.
  final String relativePath;

  /// Minimum plausible size; guards against truncated downloads.
  final int minBytes;
}

class SherpaSpeechAssets {
  static const String sttVariantBase = 'base';
  static const String sttVariantTiny = 'tiny';
  static const String defaultSttVariant = sttVariantBase;

  /// Normalize the `SHERPA_STT_VARIANT` dart-define (tiny|base).
  static String resolveSttVariant(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    if (v == sttVariantTiny) return sttVariantTiny;
    return sttVariantBase;
  }

  static String sttDirName(String variant) => 'sherpa-whisper-$variant';

  /// Multilingual whisper int8 encoder/decoder/tokens for [variant].
  static List<ModelFileRef> sttFiles(String variant) {
    final v = resolveSttVariant(variant);
    final dir = sttDirName(v);
    const base = 'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-';
    return <ModelFileRef>[
      ModelFileRef(
        url: '$base$v/resolve/main/$v-encoder.int8.onnx',
        relativePath: '$dir/$v-encoder.int8.onnx',
        minBytes: 5 * 1024 * 1024,
      ),
      ModelFileRef(
        url: '$base$v/resolve/main/$v-decoder.int8.onnx',
        relativePath: '$dir/$v-decoder.int8.onnx',
        minBytes: 50 * 1024 * 1024,
      ),
      ModelFileRef(
        url: '$base$v/resolve/main/$v-tokens.txt',
        relativePath: '$dir/$v-tokens.txt',
        minBytes: 100 * 1024,
      ),
    ];
  }

  static const String ttsDirName = 'sherpa-kokoro-en';

  /// Kokoro English TTS (same voice philosophy as the desktop server).
  static List<ModelFileRef> ttsFiles() {
    const base =
        'https://huggingface.co/csukuangfj/kokoro-en-v0_19'
        '/resolve/main';
    return const <ModelFileRef>[
      ModelFileRef(
        url: '$base/model.onnx',
        relativePath: '$ttsDirName/model.onnx',
        minBytes: 100 * 1024 * 1024,
      ),
      ModelFileRef(
        url: '$base/voices.bin',
        relativePath: '$ttsDirName/voices.bin',
        minBytes: 10 * 1024 * 1024,
      ),
      ModelFileRef(
        url: '$base/tokens.txt',
        relativePath: '$ttsDirName/tokens.txt',
        minBytes: 1 * 1024,
      ),
    ];
  }

  /// espeak-ng phonemizer data (zip to avoid hundreds of tiny downloads).
  static ModelFileRef espeakDataZip() {
    return const ModelFileRef(
      url:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
          'tts-models/espeak-ng-data.zip',
      relativePath: '$ttsDirName/espeak-ng-data.zip',
      minBytes: 3 * 1024 * 1024,
    );
  }

  static const String espeakDataDirName = 'espeak-ng-data';

  /// Piper voice bundle for a non-Supertonic language (sherpa int8 tar.bz2).
  static ModelFileRef piperBundle(String bundle) {
    return ModelFileRef(
      url: TtsVoices.piperBundleUrl(bundle),
      relativePath: 'sherpa-piper-tmp/${TtsVoices.piperBundleFile(bundle)}',
      minBytes: 5 * 1024 * 1024,
    );
  }

  /// Supertonic 3 bundle (one bundle, 31 languages).
  static ModelFileRef supertonicBundle() {
    return ModelFileRef(
      url: TtsVoices.supertonicBundleUrl(),
      relativePath: 'sherpa-piper-tmp/${TtsVoices.supertonicBundleFile}',
      minBytes: 50 * 1024 * 1024,
    );
  }
}
