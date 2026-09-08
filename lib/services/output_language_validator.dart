import 'transcription_filters.dart';

/// Validates that a translation is really in the target language before it
/// may be shown or spoken. Three layers:
///
/// 1. Echo: output identical to the source (normalized).
/// 2. Script: output carries a script the target language never uses
///    (e.g. Khmer characters in a Dutch translation).
/// 3. Stopword vote: for Latin-script languages, the output must not look
///    more like the source language than the target language.
///
/// Inconclusive results (very short text, no stopwords hit) PASS — the gate
/// only blocks clear mismatches, never legitimate speech.
class OutputLanguageValidator {
  /// Minimum words before the stopword vote may fail a translation.
  static const int minWordsForVote = 2;

  /// Minimum source-language hits required to fail a translation.
  static const int minSourceHitsToFail = 2;

  /// Minimum hits for a third language to veto the output.
  static const int minThirdLanguageHitsToFail = 3;

  /// Phrase repetitions that mark garbled output (e.g. looped n-grams).
  static const int minPhraseRepeatsToFail = 3;

  /// Word-count ratios beyond which meaning likely diverged.
  static const double maxLengthRatio = 4.0;
  static const double minLengthRatio = 0.25;
  static const int minWordsForLengthCheck = 4;

  /// Common words per Latin-script language (lowercase, matched on words).
  static const Map<String, List<String>> stopwords = <String, List<String>>{
    'en': <String>[
      'the',
      'and',
      'is',
      'are',
      'you',
      'your',
      'to',
      'of',
      'in',
      'it',
      'that',
      'this',
      'with',
      'for',
      'have',
      'has',
      'was',
      'were',
      'will',
      'would',
      'there',
      'their',
      'what',
      'when',
      'where',
      'which',
      'who',
      'whom',
      'whose',
      'how',
      'i',
      'a',
      'an',
      'my',
      'me',
      'we',
      'he',
      'she',
      'they',
      'them',
      'our',
      'am',
      'do',
      'does',
      'did',
      'can',
      'could',
      'should',
      'may',
      'might',
      'must',
      'not',
      'yes',
      'at',
      'by',
      'from',
      'but',
      'then',
      'than',
      'very',
      'just',
      'only',
      'also',
      'here',
      'now',
      'good',
      'morning',
      'evening',
      'hello',
      'thanks',
      'please',
      'people',
      'know',
      'think',
      'want',
      'need',
      'world',
      'life',
      'story',
      'child',
      'day',
      'time',
      'year',
      'way',
    ],
    'nl': <String>[
      'het',
      'een',
      'van',
      'jij',
      'dat',
      'die',
      'dit',
      'niet',
      'wat',
      'met',
      'voor',
      'zijn',
      'heeft',
      'hebt',
      'bent',
      'maar',
      'ook',
      'als',
      'dan',
      'hier',
      'daar',
      'is',
      'een',
      'ja',
      'nee',
      'kan',
      'gaat',
      'hoe',
      'waarom',
      'vandaag',
      'goed',
      'graag',
      'zij',
      'ons',
      'jullie',
      'wordt',
      'worden',
      'moet',
      'wil',
      'deze',
      'geen',
      'de',
      'ik',
      'je',
      'en',
    ],
    'tl': <String>[
      'mga',
      'ako',
      'ikaw',
      'hindi',
      'para',
      'kay',
      'siya',
      'kami',
      'tayo',
      'kayo',
      'namin',
      'natin',
      'kanila',
      'ito',
      'iyan',
      'iyon',
      'nang',
      'kung',
      'pero',
      'din',
      'rin',
      'opo',
      'ano',
      'saan',
      'bakit',
      'paano',
      'gusto',
      'mabuti',
      'lahat',
      'bawat',
      'ang',
      'ng',
      'ay',
      'sa',
      'na',
      'at',
      'ka',
      'ko',
      'mo',
    ],
    'ceb': <String>[
      'dili',
      'kini',
      'kana',
      'kadto',
      'sila',
      'kamo',
      'amo',
      'ila',
    ],
    'fr': <String>[
      'les',
      'une',
      'est',
      'sont',
      'vous',
      'nous',
      'dans',
      'avec',
      'pour',
      'plus',
      'comme',
      'cette',
      'ces',
      'mon',
      'mes',
      'ton',
      'son',
      'leur',
      'leurs',
      'mais',
      'donc',
      'tout',
      'tous',
      'bien',
      'notre',
      'votre',
      'moi',
      'toi',
      'lui',
      'eux',
      'elles',
      'ils',
      'elle',
      'elle',
      'cela',
      'le',
      'la',
      'de',
      'des',
      'un',
      'et',
      'je',
      'tu',
      'il',
      'pas',
      'que',
      'qui',
      'sur',
    ],
    'es': <String>[
      'los',
      'las',
      'del',
      'una',
      'son',
      'nosotros',
      'pero',
      'porque',
      'como',
      'cuando',
      'donde',
      'para',
      'con',
      'esta',
      'este',
      'muy',
      'mucho',
      'tambien',
      'hasta',
      'desde',
      'entre',
      'sobre',
      'todo',
      'todos',
      'nuestro',
      'nuestra',
      'este',
      'estos',
      'estas',
      'ese',
      'el',
      'la',
      'de',
      'un',
      'y',
      'es',
      'yo',
      'no',
      'que',
      'en',
    ],
    'de': <String>[
      'der',
      'die',
      'das',
      'den',
      'dem',
      'eine',
      'einem',
      'einen',
      'einer',
      'und',
      'ist',
      'sind',
      'ich',
      'wir',
      'ihr',
      'nicht',
      'mit',
      'von',
      'zum',
      'kein',
      'keine',
      'auch',
      'oder',
      'doch',
      'sondern',
      'dieser',
      'diese',
      'dieses',
      'man',
      'mein',
      'meine',
      'dein',
      'sein',
      'seine',
      'wird',
      'werden',
      'hat',
      'haben',
      'bin',
      'kann',
      'muss',
      'will',
      'soll',
      'sehr',
      'heute',
      'jetzt',
      'hier',
      'dort',
      'warum',
      'weil',
      'wenn',
      'aber',
      'du',
      'er',
      'sie',
    ],
    'it': <String>[
      'gli',
      'allo',
      'della',
      'uno',
      'sei',
      'siamo',
      'siete',
      'sono',
      'loro',
      'nella',
      'questo',
      'questa',
      'come',
      'quando',
      'dove',
      'molto',
      'mio',
      'mia',
      'miei',
      'tuo',
      'tua',
      'suo',
      'sua',
      'nostro',
      'nostra',
      'questi',
      'queste',
      'quello',
      'quella',
      'tanto',
      'sempre',
      'bene',
      'grande',
      'nuovo',
      'altro',
      'stesso',
      'fare',
      'potere',
      'volere',
      'vedere',
      'andare',
      'il',
      'lo',
      'la',
      'di',
      'un',
      'io',
      'tu',
      'non',
      'che',
    ],
    'pt': <String>[
      'uma',
      'umas',
      'dos',
      'das',
      'nos',
      'nas',
      'pelo',
      'pela',
      'sou',
      'somos',
      'ele',
      'eles',
      'elas',
      'nela',
      'nele',
      'isso',
      'isto',
      'como',
      'quando',
      'muito',
      'tambem',
      'meu',
      'minha',
      'meus',
      'teu',
      'tua',
      'seu',
      'sua',
      'nosso',
      'nossa',
      'este',
      'esta',
      'esse',
      'essa',
      'aquele',
      'aquela',
      'sempre',
      'nunca',
      'agora',
      'bem',
      'grande',
      'novo',
      'outro',
      'mesmo',
      'fazer',
      'poder',
      'o',
      'os',
      'do',
      'eu',
      'tu',
      'que',
    ],
    'id': <String>[
      'dari',
      'ini',
      'itu',
      'saya',
      'kamu',
      'mereka',
      'tidak',
      'adalah',
      'untuk',
      'dengan',
      'pada',
      'kami',
      'kita',
      'telah',
      'sudah',
    ],
    'ms': <String>[
      'dari',
      'ini',
      'itu',
      'saya',
      'awak',
      'mereka',
      'tidak',
      'adalah',
      'untuk',
      'dengan',
      'pada',
      'kami',
      'kita',
      'telah',
      'sudah',
    ],
    'vi': <String>[
      'những',
      'không',
      'đã',
      'trong',
      'này',
      'vậy',
      'rất',
      'cũng',
      'người',
      'mình',
      'chúng',
      'với',
      'cho',
      'được',
      'này',
    ],
    'sw': <String>[
      'hiki',
      'hicho',
      'mimi',
      'wewe',
      'sisi',
      'nyinyi',
      'sio',
      'kama',
      'ambayo',
      'katika',
      'hapa',
      'pale',
      'sana',
      'lakini',
      'basi',
    ],
  };

  /// True when [output] is unchanged source text (normalized compare).
  static bool isEcho(String source, String output) {
    String normalize(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (source.trim().isEmpty || output.trim().isEmpty) return false;
    return normalize(source) == normalize(output);
  }

  /// True when [output] may be sent onward as [targetCode] speech.
  ///
  /// [sourceCode] is the ISO code of the input, [targetScripts] the scripts
  /// the target language pair may produce (Latin always allowed).
  /// Validation is base-language first: regional variants are never
  /// distinguished here (that is the localization step's job), and short
  /// inconclusive texts pass rather than risk blocking real speech.
  static bool matchesTarget({
    required String sourceText,
    required String outputText,
    required String sourceCode,
    required String targetCode,
    required Set<String> targetScripts,
  }) {
    final source = sourceText.trim();
    final output = outputText.trim();
    if (output.isEmpty) return false;

    // 1. Never echo the source.
    if (isEcho(source, output)) return false;

    // 2. Never carry a script the target pair cannot produce.
    if (TranscriptionFilters.hasDisallowedScript(output, targetScripts)) {
      return false;
    }

    // 3. Never pass obviously garbled output (loops, extreme length drift).
    if (_isGarbled(source, output)) return false;

    // 4. Stopword vote (Latin-script languages only).
    final words = _words(output);
    if (words.length >= minWordsForVote) {
      final sourceHits = _hits(words, sourceCode);
      if (sourceHits >= minSourceHitsToFail) {
        final targetHits = _hits(words, targetCode);
        if (targetHits < sourceHits) return false;
      }

      // 5. Third-language tripwire: output clearly in a language that is
      // neither source nor target (e.g. English text where Tagalog belongs).
      var bestCode = '';
      var bestHits = 0;
      for (final code in stopwords.keys) {
        final hits = _hits(words, code);
        if (hits > bestHits) {
          bestHits = hits;
          bestCode = code;
        }
      }
      if (bestHits >= minThirdLanguageHitsToFail &&
          bestCode != sourceCode.trim().toLowerCase() &&
          bestCode != targetCode.trim().toLowerCase()) {
        return false;
      }
    }
    return true;
  }

  static List<String> _words(String text) {
    return text
        .toLowerCase()
        .split(RegExp('[^a-zà-ÿā-žñçâêîôûäöüßåøæœăâîșță]+'))
        .where((word) => word.isNotEmpty)
        .toList();
  }

  /// Repeated n-gram loops ("x y x y x y") or extreme length drift vs the
  /// source — the model lost meaning and must not be spoken.
  static bool _isGarbled(String source, String output) {
    final outWords = _words(output);
    if (outWords.length >= 6 && _hasRepeatedPhrase(outWords)) return true;
    final srcWords = _words(source);
    if (srcWords.length >= minWordsForLengthCheck &&
        outWords.length >= minWordsForLengthCheck) {
      final ratio = outWords.length / srcWords.length;
      if (ratio > maxLengthRatio || ratio < minLengthRatio) return true;
    }
    return false;
  }

  static bool _hasRepeatedPhrase(List<String> words) {
    // Any 2-4 word phrase occurring minPhraseRepeatsToFail+ times.
    for (var len = 2; len <= 4; len++) {
      final counts = <String, int>{};
      for (var i = 0; i + len <= words.length; i++) {
        final phrase = words.sublist(i, i + len).join(' ');
        counts[phrase] = (counts[phrase] ?? 0) + 1;
        if (counts[phrase]! > minPhraseRepeatsToFail) return true;
      }
    }
    return false;
  }

  /// Expected scripts for a target language code (Latin always included).
  static Set<String> scriptsForTarget(String targetCode) {
    switch (targetCode.trim().toLowerCase()) {
      case 'ar':
      case 'ur':
      case 'fa':
        return <String>{'Latin', 'Arabic'};
      case 'zh':
        return <String>{'Latin', 'Han'};
      case 'ja':
        return <String>{'Latin', 'Hiragana', 'Katakana', 'Han'};
      case 'ko':
        return <String>{'Latin', 'Hangul'};
      case 'hi':
      case 'mr':
        return <String>{'Latin', 'Devanagari'};
      case 'th':
        return <String>{'Latin', 'Thai'};
      case 'ru':
      case 'uk':
      case 'bg':
      case 'sr':
      case 'be':
      case 'mk':
      case 'kk':
      case 'ky':
      case 'mn':
        return <String>{'Latin', 'Cyrillic'};
      case 'el':
        return <String>{'Latin', 'Greek'};
      case 'he':
        return <String>{'Latin', 'Hebrew'};
      case 'bn':
        return <String>{'Latin', 'Bengali'};
      case 'ta':
        return <String>{'Latin', 'Tamil'};
      case 'te':
        return <String>{'Latin', 'Telugu'};
      case 'gu':
        return <String>{'Latin', 'Gujarati'};
      case 'kn':
        return <String>{'Latin', 'Kannada'};
      case 'ml':
        return <String>{'Latin', 'Malayalam'};
      case 'si':
        return <String>{'Latin', 'Sinhala'};
      case 'my':
        return <String>{'Latin', 'Myanmar'};
      case 'km':
        return <String>{'Latin', 'Khmer'};
      case 'hy':
        return <String>{'Latin', 'Armenian'};
      case 'lo':
        return <String>{'Latin', 'Lao'};
      case 'am':
        return <String>{'Latin', 'Ethiopic'};
      case 'tg':
        return <String>{'Latin', 'Cyrillic'};
      case 'yue':
        return <String>{'Latin', 'Han'};
      case 'ka':
        return <String>{'Latin', 'Georgian'};
      default:
        return <String>{'Latin'};
    }
  }

  static int _hits(List<String> words, String code) {
    final profile = stopwords[code.trim().toLowerCase()];
    if (profile == null) return 0;
    final set = profile.toSet();
    var count = 0;
    for (final word in words) {
      if (set.contains(word)) count++;
    }
    return count;
  }
}
