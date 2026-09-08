import 'package:dual_translate/core/app_config.dart';
import 'package:dual_translate/data/eb_translator_prompt.dart';
import 'package:dual_translate/data/models/translation_settings.dart';
import 'package:dual_translate/data/translation_data.dart';
import 'package:dual_translate/services/ollama_service.dart';
import 'package:dual_translate/services/ondevice_llm_service.dart';
import 'package:dual_translate/services/output_language_validator.dart';
import 'package:dual_translate/services/stt_service.dart';
import 'package:dual_translate/services/translation_service.dart';
import 'package:dual_translate/services/tts_text_normalizer.dart';
import 'package:flutter_local_llm/flutter_local_llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('eb-translator model wiring', () {
    test('default model is eb-translator', () {
      expect(AppConfig.defaultModel, 'eb-translator');
      expect(const TranslationSettings().model, 'eb-translator');
      expect(
        TranslationSettings.fromJson(const <String, dynamic>{}).model,
        'eb-translator',
      );
      expect(AppConfig.fromEnvironment().modelName, isNotEmpty);
    });

    test('legacy eburon-mobile names canonicalize to eb-translator', () {
      expect(
        TranslationService.canonicalModelName('eburon-mobile'),
        'eb-translator',
      );
      expect(
        TranslationService.canonicalModelName('eburon-mobile:latest'),
        'eb-translator',
      );
      expect(
        TranslationService.canonicalModelName('eburonpro/eburon-mobile:latest'),
        'eb-translator',
      );
    });

    test('cloud and gemini names are rejected', () {
      expect(TranslationService.canonicalModelName('foo:cloud'), isEmpty);
      expect(TranslationService.canonicalModelName('gemini-live'), isEmpty);
      expect(TranslationService.canonicalModelName('  '), isEmpty);
    });

    test('resolveModel prefers stored value but never cloud/gemini', () {
      const config = AppConfig(
        ollamaUrl: 'http://localhost:11434',
        modelName: 'eb-translator',
      );
      final service = TranslationService(config: config);
      expect(service.resolveModel('gemma3:4b'), 'gemma3:4b');
      expect(service.resolveModel('eburon-mobile'), 'eb-translator');
      expect(service.resolveModel('something:cloud'), 'eb-translator');
      expect(service.resolveModel(null), 'eb-translator');
    });

    test('install hint points at the Modelfile build', () {
      expect(
        OllamaService.installHint('eb-translator'),
        contains('ollama create eb-translator -f Modelfile'),
      );
      expect(OllamaService.installHint('eb-translator'), contains('gemma3:4b'));
      expect(
        OllamaService.installHint('gemma3:4b'),
        contains('ollama pull gemma3:4b'),
      );
    });

    test('backend routes phones on-device, desktop to Ollama', () {
      expect(TranslationService.useOnDevice(overrideOnDevice: true), isTrue);
      expect(TranslationService.useOnDevice(overrideOnDevice: false), isFalse);
      const config = AppConfig(
        ollamaUrl: 'http://localhost:11434',
        modelName: 'eb-translator',
      );
      final service = TranslationService(config: config);
      expect(service.backend, isA<LlmBackend>());
    });
  });

  group('shared eb-translator prompts', () {
    test('system prompt stays short and strict', () {
      final system = EbTranslatorPrompt.system();
      expect(system, contains('eb-translator'));
      expect(system, contains('ONLY the translated text'));
      expect(system.length, lessThan(400));
      expect(EbTranslatorPrompt.system(medicalMode: true), contains('medical'));
    });

    test('directed prompt carries context without repeating it', () {
      final prompt = EbTranslatorPrompt.directed(
        text: 'Hallo',
        sourceLanguage: 'Dutch (Flemish)',
        targetLanguage: 'English (US)',
        context: 'Hoi -> Hi',
      );
      expect(prompt, contains('Dutch (Flemish)'));
      expect(prompt, contains('Hallo'));
      expect(prompt, contains('Hoi -> Hi'));
      final plain = EbTranslatorPrompt.directed(
        text: 'Hallo',
        sourceLanguage: 'Dutch (Flemish)',
        targetLanguage: 'English (US)',
      );
      expect(plain, isNot(contains('Recent conversation')));
    });

    test('polish prompt targets the right language', () {
      final prompt = EbTranslatorPrompt.polishRewrite(
        text: 'Ik heb hoofdpijn',
        targetLanguage: 'Dutch (Flemish)',
      );
      expect(prompt, contains('Dutch (Flemish)'));
      expect(prompt, contains('Ik heb hoofdpijn'));
      expect(prompt, contains('ONLY the rewrite'));
    });

    test('whisper language line parses to a code', () {
      expect(
        SttService.parseDetectedLanguage(
          'whisper_full_with_state: auto-detected language: nl (p = 0.97)',
        ),
        'nl',
      );
      expect(SttService.parseDetectedLanguage('no language here'), isEmpty);
      expect(SttService.parseDetectedLanguage(null), isEmpty);
    });

    test('tts normalizer scrubs speech-hostile text', () {
      expect(
        TtsTextNormalizer.normalizeForSpeech('Hello **world**!'),
        'Hello world!',
      );
      expect(
        TtsTextNormalizer.normalizeForSpeech('Hallo 😀 wereld'),
        'Hallo wereld',
      );
      expect(
        TtsTextNormalizer.normalizeForSpeech('Goedemorgen , hoe gaat het ?'),
        'Goedemorgen, hoe gaat het?',
      );
      expect(
        TtsTextNormalizer.normalizeForSpeech('Echt waar!!!'),
        'Echt waar!',
      );
      expect(TtsTextNormalizer.normalizeForSpeech("Don't stop"), "Don't stop");
      expect(TtsTextNormalizer.normalizeForSpeech('   '), isEmpty);
    });

    test('leading language-name leaks are stripped', () {
      expect(
        TranslationService.sanitizeTranslation('Dutch, Hoe gaat het met u?'),
        'Hoe gaat het met u?',
      );
      expect(
        TranslationService.sanitizeTranslation('French: Bonjour'),
        'Bonjour',
      );
      // Real sentences starting with those words without punctuation stay.
      expect(
        TranslationService.sanitizeTranslation('Dutch courage helps.'),
        'Dutch courage helps.',
      );
    });

    test('language codes map to display names', () {
      expect(displayNameForLanguageCode('tl'), 'Tagalog (Filipino)');
      expect(displayNameForLanguageCode('nl'), 'Dutch (Flemish)');
      expect(displayNameForLanguageCode('en'), 'English (US)');
      expect(displayNameForLanguageCode('xx'), isNull);
      expect(displayNameForLanguageCode(''), isNull);
    });

    test('on-device GGUF points at gemma 3 4B QAT', () {
      expect(
        EbTranslatorPrompt.defaultGgufUrl,
        contains('gemma-3-4b-it-qat-q4_0-gguf'),
      );
      expect(EbTranslatorPrompt.defaultGgufFileName, endsWith('.gguf'));
      expect(AppConfig.fromEnvironment().onDeviceModelUrl, contains('.gguf'));
    });

    test('chat template matches the gguf family', () {
      expect(
        OnDeviceLlmService.templateFor('gemma-3-4b-it-q4_0.gguf'),
        isA<GemmaTemplate>(),
      );
      expect(
        OnDeviceLlmService.templateFor('Llama-3.2-1B-Q4_K_M.gguf'),
        isA<Llama3Template>(),
      );
      expect(
        OnDeviceLlmService.templateFor('qwen2.5-0.5b-instruct-q4_k_m.gguf'),
        isA<ChatMlTemplate>(),
      );
    });
  });

  group('output language validation', () {
    bool valid(String source, String output, String from, String to) =>
        OutputLanguageValidator.matchesTarget(
          sourceText: source,
          outputText: output,
          sourceCode: from,
          targetCode: to,
          targetScripts: OutputLanguageValidator.scriptsForTarget(to),
        );

    test('correct translations pass', () {
      expect(
        valid('I have a headache.', 'May sakit ng ulo ako.', 'en', 'tl'),
        isTrue,
      );
      expect(
        valid('Masakit ang tiyan ko.', 'My stomach hurts.', 'tl', 'en'),
        isTrue,
      );
    });

    test('same-language echoes fail', () {
      expect(valid('Hello world', 'Hello world', 'en', 'tl'), isFalse);
      expect(valid('Hello  world', 'hello world', 'en', 'tl'), isFalse);
    });

    test('wrong-direction output fails', () {
      // English wording when Tagalog was requested.
      expect(
        valid('Kamusta ka na?', 'I am fine, thank you', 'tl', 'tl'),
        isFalse,
      );
      expect(
        valid('How are you today?', 'I am fine, thank you', 'en', 'tl'),
        isFalse,
      );
    });

    test('foreign-script output fails for latin targets', () {
      expect(valid('Hello', 'ស្្្្្', 'en', 'nl'), isFalse);
    });

    test('short inconclusive output passes', () {
      expect(valid('Hallo', 'Salamat!', 'nl', 'tl'), isTrue);
      expect(valid('Hello', '', 'en', 'tl'), isFalse);
    });

    test('target scripts cover language families', () {
      expect(
        OutputLanguageValidator.scriptsForTarget('ar'),
        contains('Arabic'),
      );
      expect(OutputLanguageValidator.scriptsForTarget('zh'), contains('Han'));
      expect(OutputLanguageValidator.scriptsForTarget('nl'), <String>{'Latin'});
    });
  });
}
