import 'dart:io';
import 'dart:typed_data';

import 'package:dual_translate/core/app_config.dart';
import 'package:dual_translate/data/eb_translator_prompt.dart';
import 'package:dual_translate/data/models/translation_settings.dart';
import 'package:dual_translate/data/sherpa_speech_assets.dart';
import 'package:dual_translate/data/tts_voices.dart';
import 'package:dual_translate/services/local_model_store.dart';
import 'package:dual_translate/services/offline_readiness.dart';
import 'package:dual_translate/services/sherpa_tts_service.dart';
import 'package:dual_translate/services/transcription_filters.dart';
import 'package:dual_translate/services/vad_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sherpa speech assets', () {
    test('variant resolution defaults to base', () {
      expect(SherpaSpeechAssets.resolveSttVariant(null), 'base');
      expect(SherpaSpeechAssets.resolveSttVariant(''), 'base');
      expect(SherpaSpeechAssets.resolveSttVariant('tiny'), 'tiny');
      expect(SherpaSpeechAssets.resolveSttVariant('BASE'), 'base');
      expect(SherpaSpeechAssets.resolveSttVariant('small'), 'base');
    });

    test('stt files point at multilingual whisper int8 weights', () {
      final files = SherpaSpeechAssets.sttFiles('base');
      expect(files, hasLength(3));
      expect(files[0].url, contains('sherpa-onnx-whisper-base'));
      expect(files[0].url, endsWith('base-encoder.int8.onnx'));
      expect(files[1].url, endsWith('base-decoder.int8.onnx'));
      expect(files[2].url, endsWith('base-tokens.txt'));
      for (final file in files) {
        expect(file.minBytes, greaterThan(0));
        expect(file.relativePath, startsWith('sherpa-whisper-base/'));
      }
    });

    test('tts files point at kokoro en + espeak data', () {
      final files = SherpaSpeechAssets.ttsFiles();
      expect(files.map((f) => f.url.split('/').last), contains('model.onnx'));
      expect(files.map((f) => f.url.split('/').last), contains('voices.bin'));
      expect(
        SherpaSpeechAssets.espeakDataZip().url,
        contains('espeak-ng-data.zip'),
      );
    });

    test('app config exposes the stt variant', () {
      expect(AppConfig.fromEnvironment().resolvedSttVariant, 'base');
      const custom = AppConfig(
        ollamaUrl: 'http://localhost:11434',
        modelName: 'eb-translator',
        sttVariant: 'tiny',
      );
      expect(custom.resolvedSttVariant, 'tiny');
    });
  });

  group('transcription filters', () {
    test('silence gate rejects quiet PCM', () {
      expect(TranscriptionFilters.isNearSilence(<int>[]), isTrue);
      expect(TranscriptionFilters.isNearSilence(<int>[0, 0, 0, 0]), isTrue);
      // Loud 440Hz-ish square wave must pass the gate.
      final loud = List<int>.generate(3200, (i) => i.isEven ? 0x00 : 0x60);
      expect(TranscriptionFilters.isNearSilence(loud), isFalse);
    });

    test('junk transcriptions are filtered', () {
      expect(
        TranscriptionFilters.filterTranscription('Hello world'),
        'Hello world',
      );
      expect(
        TranscriptionFilters.filterTranscription('[BLANK_AUDIO]'),
        isEmpty,
      );
      expect(
        TranscriptionFilters.filterTranscription('Thank you for watching.'),
        isEmpty,
      );
      expect(
        TranscriptionFilters.filterTranscription('hello hello hello hello'),
        isEmpty,
      );
    });

    test('bracketed sound labels never become turns', () {
      for (final junk in <String>[
        '(upbeat music)',
        '(crickets chirping)',
        '(wind blowing)',
        '(speaking in foreign language)',
        '[music]',
        '[applause]',
      ]) {
        expect(
          TranscriptionFilters.filterTranscription(junk),
          isEmpty,
          reason: junk,
        );
      }
      // Inline asides are stripped but real speech is kept.
      expect(
        TranscriptionFilters.filterTranscription('Hallo (lacht) wereld'),
        'Hallo wereld',
      );
    });

    test('lone silence words are dropped, real words kept', () {
      expect(TranscriptionFilters.filterTranscription('you'), isEmpty);
      expect(
        TranscriptionFilters.filterTranscription('Hello world'),
        isNotEmpty,
      );
      expect(TranscriptionFilters.filterTranscription('ja'), isNotEmpty);
      expect(TranscriptionFilters.filterTranscription('nee'), isNotEmpty);
    });

    test('foreign-script hallucinations are dropped', () {
      const latinOnly = <String>{'Latin'};
      expect(
        TranscriptionFilters.filterTranscription(
          'Hello world',
          allowedScripts: latinOnly,
        ),
        isNotEmpty,
      );
      // Khmer garbage on a Latin pair (real whisper failure mode).
      expect(
        TranscriptionFilters.filterTranscription(
          'ស្្្្្',
          allowedScripts: latinOnly,
        ),
        isEmpty,
      );
      // Same output passes when Khmer is expected.
      expect(
        TranscriptionFilters.filterTranscription(
          'ស្្្្្',
          allowedScripts: <String>{'Latin', 'Khmer'},
        ),
        isNotEmpty,
      );
    });

    test('scripts follow the language pair', () {
      expect(
        TranscriptionFilters.scriptsForLanguages(
          'Dutch (Flemish)',
          'English (US)',
        ),
        <String>{'Latin'},
      );
      expect(
        TranscriptionFilters.scriptsForLanguages('Arabic', 'English (US)'),
        contains('Arabic'),
      );
      expect(
        TranscriptionFilters.scriptsForLanguages(
          'Chinese (Simplified)',
          'Dutch (Flemish)',
        ),
        contains('Han'),
      );
      // Latin is always allowed (loanwords, numbers).
      expect(
        TranscriptionFilters.scriptsForLanguages('Arabic', 'Urdu'),
        contains('Latin'),
      );
    });

    test('pcm16 converts to normalized floats', () {
      // 0, max positive, max negative.
      final floats = TranscriptionFilters.pcm16ToFloat(<int>[
        0x00,
        0x00,
        0xFF,
        0x7F,
        0x00,
        0x80,
      ]);
      expect(floats[0], 0.0);
      expect(floats[1], closeTo(1.0, 0.001));
      expect(floats[2], closeTo(-1.0, 0.001));
    });

    test('float samples convert to pcm16 bytes', () {
      final bytes = float32ToPcm16(<double>[0.0, 1.0, -1.0]);
      expect(bytes, hasLength(6));
      expect(bytes[0], 0);
      expect(bytes[1], 0);
    });
  });

  group('multilingual tts voices', () {
    test('display names resolve to language codes', () {
      expect(TtsVoices.langCodeFor('Tagalog (Filipino)'), 'tl');
      expect(TtsVoices.langCodeFor('Thai'), 'th');
      expect(TtsVoices.langCodeFor('Malay'), 'ms');
      expect(TtsVoices.langCodeFor('Cebuano'), 'ceb');
      expect(TtsVoices.langCodeFor('Dutch (Flemish)'), 'nl');
      expect(TtsVoices.langCodeFor('English (US)'), 'en');
      expect(TtsVoices.langCodeFor('French'), 'fr');
      expect(TtsVoices.langCodeFor('Korean'), 'ko');
      expect(TtsVoices.langCodeFor('Japanese'), 'ja');
      expect(TtsVoices.langCodeFor('nl'), 'nl');
      expect(TtsVoices.langCodeFor('pt-BR'), 'pt');
      expect(TtsVoices.langCodeFor(''), 'en');
      expect(TtsVoices.langCodeFor(null), 'en');
    });

    test('legacy kokoro voice ids resolve to languages', () {
      expect(TtsVoices.langCodeFor('af_heart'), 'en');
      expect(TtsVoices.langCodeFor('ff_siwis'), 'fr');
      expect(TtsVoices.langCodeFor('ef_dora'), 'es');
    });

    test('supertonic covers 31 languages incl dutch/korean/japanese', () {
      for (final code in <String>['en', 'nl', 'fr', 'de', 'ko', 'ja']) {
        expect(TtsVoices.supertonicLangs, contains(code));
        expect(TtsVoices.forLanguage(code).isPiper, isFalse);
      }
      expect(TtsVoices.supertonicLangs.length, 31);
      expect(TtsVoices.forLanguage('Dutch (Flemish)').isPiper, isFalse);
      expect(TtsVoices.forLanguage('Korean').isPiper, isFalse);
    });

    test('piper covers languages outside supertonic', () {
      // Chinese has no usable local male voice: Supertonic English fallback.
      expect(TtsVoices.forLanguage('Chinese (Simplified)').isPiper, isFalse);
      expect(
        TtsVoices.forLanguage('Catalan').piperBundle,
        'ca_ES-upc_ona-medium',
      );
      // Male-default piper voices (pitch-verified).
      expect(
        TtsVoices.forLanguage('Basque').piperBundle,
        'eu_ES-antton-medium',
      );
      expect(
        TtsVoices.forLanguage('Icelandic').piperBundle,
        'is_IS-steinn-medium',
      );
      expect(
        TtsVoices.forLanguage('Malayalam').piperBundle,
        'ml_IN-arjun-medium',
      );
      expect(
        TtsVoices.forLanguage('Nepali').piperBundle,
        'ne_NP-chitwan-medium',
      );
      // Uncovered languages fall back to Supertonic English.
      expect(TtsVoices.forLanguage('Tagalog (Filipino)').isPiper, isFalse);
      expect(TtsVoices.forLanguage('Klingon').isPiper, isFalse);
    });

    test('piper bundle urls target the sherpa release', () {
      expect(
        TtsVoices.piperBundleUrl('nl_BE-nathalie-medium'),
        contains('vits-piper-nl_BE-nathalie-medium-int8.tar.bz2'),
      );
      final ref = SherpaSpeechAssets.piperBundle('fr_FR-siwis-medium');
      expect(ref.url, contains('fr_FR-siwis-medium'));
      expect(ref.minBytes, greaterThan(0));
    });

    test('mobile engine keys follow the voice spec', () {
      expect(SherpaTtsService.engineKeyFor('English (US)'), 'supertonic');
      expect(SherpaTtsService.engineKeyFor('Dutch (Flemish)'), 'supertonic');
      expect(SherpaTtsService.engineKeyFor('Korean'), 'supertonic');
      expect(
        SherpaTtsService.engineKeyFor('Chinese (Simplified)'),
        'supertonic',
      );
      expect(SherpaTtsService.engineKeyFor('Tagalog (Filipino)'), 'supertonic');
      expect(SherpaTtsService.synthLangFor('Dutch (Flemish)'), 'nl');
      expect(SherpaTtsService.synthLangFor('Tagalog (Filipino)'), 'en');
    });

    test('male voice is default, feminine legacy voices map to female', () {
      expect(const TranslationSettings().voice, 'male');
      expect(
        TranslationSettings.fromJson(const <String, dynamic>{}).voice,
        'male',
      );
      expect(
        TranslationSettings.fromJson(const <String, dynamic>{
          'voice': 'Orus',
        }).voice,
        'male',
      );
      expect(
        TranslationSettings.fromJson(const <String, dynamic>{
          'voice': 'af_heart',
        }).voice,
        'female',
      );
      expect(
        TranslationSettings.fromJson(const <String, dynamic>{
          'voice': 'female',
        }).voice,
        'female',
      );
    });

    test('supertonic sid follows gender (male default)', () {
      expect(SherpaTtsService.sidForVoice(null), SherpaTtsService.maleSid);
      expect(SherpaTtsService.sidForVoice('male'), SherpaTtsService.maleSid);
      expect(SherpaTtsService.sidForVoice('Orus'), SherpaTtsService.maleSid);
      expect(
        SherpaTtsService.sidForVoice('female'),
        SherpaTtsService.femaleSid,
      );
      expect(
        SherpaTtsService.sidForVoice('af_heart'),
        SherpaTtsService.femaleSid,
      );
      expect(SherpaTtsService.maleSid, isNot(SherpaTtsService.femaleSid));
    });
  });

  group('voice activity detection', () {
    test('silero asset points at the k2-fsa release', () {
      final ref = SherpaSpeechAssets.vadModel();
      expect(ref.url, contains('silero_vad.onnx'));
      expect(ref.relativePath, endsWith('.onnx'));
      expect(ref.minBytes, greaterThan(0));
    });

    test('fallback windows keep transcription alive without a model', () {
      final vad = VadService();
      addTearDown(vad.dispose);
      expect(vad.isReady, isFalse);

      // Short feed: nothing completes yet.
      expect(vad.feed(List<int>.filled(1000, 0)), isEmpty);
      // Full ~3.75 s window completes exactly one utterance.
      final done = vad.feed(
        List<int>.filled(VadService.fallbackWindowBytes, 0),
      );
      expect(done, hasLength(1));
      expect(done.single.pcmBytes, hasLength(VadService.fallbackWindowBytes));
      // Remainder carries over to the next feed.
      final more = vad.feed(
        List<int>.filled(VadService.fallbackWindowBytes + 500, 0),
      );
      expect(more, hasLength(1));
      // Reset drops buffered audio.
      vad.reset();
      expect(
        vad.feed(List<int>.filled(VadService.fallbackWindowBytes - 1, 0)),
        isEmpty,
      );
    });

    test('utterances carry finality for fragment holding', () {
      final finalU = VadUtterance(Uint8List(0));
      expect(finalU.isFinal, isTrue);
      final fragment = VadUtterance(Uint8List(0), isFinal: false);
      expect(fragment.isFinal, isFalse);
    });
  });

  group('offline readiness', () {
    Future<Directory> seed({
      bool gguf = true,
      bool stt = true,
      bool supertonic = true,
      List<String> piperBundles = const <String>['nl_BE-nathalie-medium'],
      bool espeak = true,
    }) async {
      final dir = await Directory.systemTemp.createTemp('models');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      Future<void> big(String relative, int bytes) async {
        final file = File('${dir.path}/$relative');
        await file.parent.create(recursive: true);
        final sink = file.openWrite();
        final chunk = Uint8List(65536);
        var left = bytes;
        while (left > 0) {
          final n = left > chunk.length ? chunk.length : left;
          sink.add(chunk.sublist(0, n));
          left -= n;
        }
        await sink.close();
      }

      if (gguf) {
        await big(
          EbTranslatorPrompt.defaultGgufFileName,
          EbTranslatorPrompt.minModelBytes + 10,
        );
      }
      if (stt) {
        for (final ref in SherpaSpeechAssets.sttFiles('base')) {
          await big(ref.relativePath, ref.minBytes + 10);
        }
      }
      if (supertonic) {
        await big('${TtsVoices.supertonicDirName}/.extracted', 30);
      }
      for (final bundle in piperBundles) {
        await big('${TtsVoices.piperDirName(bundle)}/.extracted', 30);
      }
      if (espeak) {
        await big(
          '${SherpaSpeechAssets.ttsDirName}/${SherpaSpeechAssets.espeakDataDirName}/.extracted',
          30,
        );
      }
      return dir;
    }

    Future<OfflineReadiness> check(
      Directory dir, {
      String guest = 'Dutch (Flemish)',
    }) {
      final store = LocalModelStore(baseDir: dir);
      addTearDown(store.dispose);
      return OfflineReadiness.check(
        store: store,
        sttVariant: 'base',
        guestLanguage: guest,
      );
    }

    test('fully seeded models report ready', () async {
      final readiness = await check(await seed());
      expect(readiness.isReady, isTrue);
      expect(readiness.missing, isEmpty);
    });

    test('missing translator lists it by name', () async {
      final readiness = await check(await seed(gguf: false));
      expect(readiness.isReady, isFalse);
      expect(readiness.missing.join(' '), contains('Translator'));
      expect(readiness.message, contains('Wi-Fi'));
    });

    test('piper guest requires its bundle, others do not', () async {
      final noPiper = await check(
        await seed(piperBundles: const <String>[]),
        guest: 'Catalan',
      );
      expect(noPiper.isReady, isFalse);
      expect(noPiper.missing.join(' '), contains('Piper'));

      final withPiper = await check(
        await seed(piperBundles: const <String>['ca_ES-upc_ona-medium']),
        guest: 'Catalan',
      );
      expect(withPiper.isReady, isTrue);

      final englishGuest = await check(
        await seed(piperBundles: const <String>[]),
        guest: 'English (US)',
      );
      expect(englishGuest.isReady, isTrue);
    });

    test('missing supertonic blocks even with piper present', () async {
      final readiness = await check(await seed(supertonic: false));
      expect(readiness.isReady, isFalse);
      expect(readiness.missing.join(' '), contains('Supertonic'));
    });
  });
}
