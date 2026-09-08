/// Final text hygiene before speech synthesis.
///
/// The polish pass already targets TTS-clean output; this is the deterministic
/// safety net: no markdown, symbols, emoji, control characters, or STT
/// artifacts may ever reach the speaker.
class TtsTextNormalizer {
  /// Scrub [value] for speech. Returns '' when nothing speakable remains.
  static String normalizeForSpeech(String value) {
    var text = value.trim();
    if (text.isEmpty) return '';

    // Markdown / chat formatting that TTS would spell out or choke on.
    text = text.replaceAll(RegExp(r'[*_~`#|>]+'), '');

    // Emoji, pictographs, modifier symbols.
    text = text.replaceAll(RegExp(r'[\p{So}\p{Sk}]+', unicode: true), '');

    // Zero-width and control characters.
    text = text.replaceAll(RegExp(r'[\u200B-\u200F\uFEFF\u0000-\u001F]+'), '');

    // Collapse whitespace (including newlines) to single spaces.
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    // No space before closing punctuation: "hello , world" -> "hello, world".
    text = text.replaceAllMapped(
      RegExp(r'\s+([,.!?;:])'),
      (match) => match.group(1)!,
    );

    // Cap shouting punctuation ("What!!!?" -> "What!?").
    text = text.replaceAllMapped(
      RegExp(r'([!?]){2,}'),
      (match) => match.group(1)!,
    );

    return text.trim();
  }
}
