import 'dart:convert';
import 'dart:math' as math;

/// Shared pre/post filters for speech-to-text output.
///
/// Used by both STT backends (desktop whisper-cli and on-device sherpa
/// whisper) so silence gating and hallucination filtering behave identically.
class TranscriptionFilters {
  /// Skip transcription when chunk RMS is below this (PCM16 full-scale ≈ 32768).
  static const double silenceRmsThreshold = 180.0;

  /// Skip transcription when peak absolute sample is below this.
  static const int silencePeakThreshold = 500;

  /// True when the PCM16 little-endian mono chunk is near silence.
  static bool isNearSilence(List<int> pcmBytes) {
    if (pcmBytes.length < 4) return true;
    var peak = 0;
    var sumSq = 0.0;
    var samples = 0;
    for (var i = 0; i + 1 < pcmBytes.length; i += 2) {
      final sample = (pcmBytes[i] | (pcmBytes[i + 1] << 8));
      final signed = sample > 32767 ? sample - 65536 : sample;
      final abs = signed.abs();
      if (abs > peak) peak = abs;
      sumSq += signed * signed;
      samples++;
    }
    if (samples == 0) return true;
    final rms = math.sqrt(sumSq / samples);
    return rms < silenceRmsThreshold && peak < silencePeakThreshold;
  }

  static final RegExp junkPhrase = RegExp(
    r'^(?:\[?\s*blank[_\s-]?audio\s*\]?|'
    r'thank(?:s|\s+you)\s+for\s+watching\.?|'
    r'\(?\s*music\s*\)?|'
    r'\[?\s*music\s*\]?|'
    r'\[?\s*silence\s*\]?|'
    r'\[?\s*inaudible\s*\]?|'
    r'subscribe\s+to\s+(?:my|the)\s+channel\.?|'
    r'please\s+subscribe\.?)$',
    caseSensitive: false,
  );

  static final RegExp purePunctuation = RegExp(
    r'^[\s\p{P}\p{S}]+$',
    unicode: true,
  );

  /// Entire turn is a bracketed sound/scene label.
  static final RegExp _bracketedLabel = RegExp(r'^[\(\[]\s*[^\)\]]+\s*[\)\]]$');

  /// Bracketed asides embedded in real speech.
  static final RegExp _inlineBracketed = RegExp(r'\([^()]*\)|\[[^\[\]]*\]');

  /// Lone words whisper emits on silence/non-speech (no content to translate).
  static final RegExp _loneJunk = RegExp(
    r'^(?:you|the|a|oh|uh|uhm|hmm|music|silence|noise)\.?$',
    caseSensitive: false,
  );

  /// Unicode script probes for hallucination detection.
  static final Map<String, RegExp> _scriptProbes = <String, RegExp>{
    for (final script in <String>[
      'Han',
      'Hiragana',
      'Katakana',
      'Hangul',
      'Arabic',
      'Devanagari',
      'Thai',
      'Cyrillic',
      'Greek',
      'Hebrew',
      'Armenian',
      'Georgian',
      'Tamil',
      'Telugu',
      'Kannada',
      'Malayalam',
      'Gujarati',
      'Gurmukhi',
      'Bengali',
      'Oriya',
      'Sinhala',
      'Myanmar',
      'Khmer',
      'Lao',
      'Ethiopic',
    ])
      script: RegExp('\\p{Script=$script}', unicode: true),
  };

  /// Scripts a display language name is expected to use (Latin always added).
  static Set<String> scriptsForLanguages(String? a, String? b) {
    final scripts = <String>{'Latin'};
    for (final raw in <String?>[a, b]) {
      final s = (raw ?? '').trim().toLowerCase();
      if (s.isEmpty) continue;
      if (s.contains('arab') ||
          s.contains('urdu') ||
          s.contains('persian') ||
          s.contains('farsi') ||
          s.contains('pashto') ||
          s.contains('darija') ||
          s.contains('dari')) {
        scripts.add('Arabic');
      } else if (s.contains('chinese') || s.contains('mandarin')) {
        scripts.add('Han');
      } else if (s.contains('japan')) {
        scripts.addAll(<String>['Hiragana', 'Katakana', 'Han']);
      } else if (s.contains('korea')) {
        scripts.add('Hangul');
      } else if (s.contains('hindi') || s.contains('marathi')) {
        scripts.add('Devanagari');
      } else if (s.contains('thai')) {
        scripts.add('Thai');
      } else if (s.contains('russian') ||
          s.contains('ukrain') ||
          s.contains('bulgar') ||
          s.contains('serbian') ||
          s.contains('belarus') ||
          s.contains('macedon') ||
          s.contains('kazakh') ||
          s.contains('kyrgyz') ||
          s.contains('mongol')) {
        scripts.add('Cyrillic');
      } else if (s.contains('greek')) {
        scripts.add('Greek');
      } else if (s.contains('hebrew')) {
        scripts.add('Hebrew');
      } else if (s.contains('tamil')) {
        scripts.add('Tamil');
      } else if (s.contains('telugu')) {
        scripts.add('Telugu');
      } else if (s.contains('bengali')) {
        scripts.add('Bengali');
      } else if (s.contains('gujarati')) {
        scripts.add('Gujarati');
      } else if (s.contains('kannada')) {
        scripts.add('Kannada');
      } else if (s.contains('malayalam')) {
        scripts.add('Malayalam');
      } else if (s.contains('sinhala')) {
        scripts.add('Sinhala');
      } else if (s.contains('myanmar') || s.contains('burmese')) {
        scripts.add('Myanmar');
      } else if (s.contains('khmer')) {
        scripts.add('Khmer');
      } else if (s.contains('lao')) {
        scripts.add('Lao');
      } else if (s.contains('amharic')) {
        scripts.add('Ethiopic');
      } else if (s.contains('tajik')) {
        scripts.add('Cyrillic');
      } else if (s.contains('cantonese')) {
        scripts.add('Han');
      } else if (s.contains('armenian')) {
        scripts.add('Armenian');
      } else if (s.contains('georgian')) {
        scripts.add('Georgian');
      }
    }
    return scripts;
  }

  /// True when [text] carries a script outside [allowed] (Latin implied).
  static bool hasDisallowedScript(String text, Set<String> allowed) {
    final effective = {...allowed, 'Latin'};
    for (final entry in _scriptProbes.entries) {
      if (effective.contains(entry.key)) continue;
      if (entry.value.hasMatch(text)) return true;
    }
    return false;
  }

  /// Parse whisper-style stdout into a single trimmed transcription string.
  static String parseCliLines(Object? stdout) {
    final raw = stdout is List<int>
        ? utf8.decode(stdout, allowMalformed: true)
        : (stdout ?? '').toString();
    final lines = raw
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .where((l) => !l.startsWith('whisper_'))
        .where((l) => !l.startsWith('ggml_'))
        .where((l) => !l.startsWith('system_info'))
        .where((l) => !l.startsWith('main:'))
        .where((l) => !l.startsWith('load_'))
        .toList();
    return lines.join(' ').trim();
  }

  /// Filter hallucination / junk outputs before emitting.
  ///
  /// [allowedScripts] are Unicode script names expected for the active
  /// language pair (always implicitly includes Latin for loanwords).
  /// Anything carrying a foreign script (e.g. Khmer/Korean output while
  /// transcribing Dutch) is a model hallucination and is dropped.
  static String filterTranscription(
    String raw, {
    Set<String> allowedScripts = const <String>{'Latin'},
  }) {
    var text = raw.trim();
    if (text.isEmpty) return '';

    // Strip common bracketed tags that whisper emits alone.
    text = text
        .replaceAll(RegExp(r'\[BLANK_AUDIO\]', caseSensitive: false), '')
        .trim();
    text = text
        .replaceAll(RegExp(r'\(music\)', caseSensitive: false), '')
        .trim();
    if (text.isEmpty) return '';

    // Whole-turn sound/scene labels: "(upbeat music)", "[crickets chirping]",
    // "(speaking in foreign language)" — never user speech.
    if (_bracketedLabel.hasMatch(text)) return '';

    // Inline labels inside real speech: "hello (laughs) world".
    text = text
        .replaceAll(_inlineBracketed, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return '';

    if (junkPhrase.hasMatch(text)) return '';
    if (purePunctuation.hasMatch(text)) return '';

    // Classic whisper-on-silence outputs with no translatable content.
    if (_loneJunk.hasMatch(text)) return '';

    // Foreign-script hallucination guard.
    if (hasDisallowedScript(text, allowedScripts)) return '';

    // Single-char noise (letter/digit only if longer is ok; lone symbol already caught).
    final compact = text.replaceAll(RegExp(r'\s+'), '');
    if (compact.length <= 1) return '';

    // Repeated same phrase spam: "hello hello hello hello"
    final words = text
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.length >= 4) {
      final first = words.first.toLowerCase();
      if (words.every((w) => w.toLowerCase() == first)) return '';
      // Pair spam: "thank you thank you thank you"
      if (words.length >= 6 && words.length.isEven) {
        final a = words[0].toLowerCase();
        final b = words[1].toLowerCase();
        var pairSpam = true;
        for (var i = 0; i < words.length; i += 2) {
          if (words[i].toLowerCase() != a || words[i + 1].toLowerCase() != b) {
            pairSpam = false;
            break;
          }
        }
        if (pairSpam) return '';
      }
    }

    // Exact known junk phrases as substrings when that's the whole content.
    final lower = text.toLowerCase();
    const junkExact = <String>[
      'thank you for watching',
      'thanks for watching',
      'thanks for watching.',
      'thank you for watching.',
      '[blank_audio]',
      '(music)',
      '[music]',
    ];
    for (final j in junkExact) {
      if (lower == j) return '';
    }

    return repairTranscript(text);
  }

  /// Light deterministic repair before translation: whitespace and
  /// punctuation spacing only. Heavier repair (mishearings, completion)
  /// uses conversation context inside the translation call.
  static String repairTranscript(String value) {
    var text = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    text = text.replaceAllMapped(
      RegExp(r'\s+([,.!?;:])'),
      (match) => match.group(1)!,
    );
    return text.trim();
  }

  /// Convert PCM16 little-endian mono bytes to normalized float samples.
  static List<double> pcm16ToFloat(List<int> pcmBytes) {
    final count = pcmBytes.length ~/ 2;
    final out = List<double>.filled(count, 0);
    for (var i = 0; i < count; i++) {
      final sample = (pcmBytes[i * 2] | (pcmBytes[i * 2 + 1] << 8));
      final signed = sample > 32767 ? sample - 65536 : sample;
      out[i] = signed / 32768.0;
    }
    return out;
  }
}
