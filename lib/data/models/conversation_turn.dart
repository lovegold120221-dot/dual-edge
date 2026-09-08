enum ConversationRole { user, agent, system }

class ConversationTurn {
  ConversationTurn({
    required this.role,
    required this.text,
    required this.isFinal,
    this.transcription,
    this.translation,
    this.detectedLanguage,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final ConversationRole role;
  String text;
  String? transcription;
  String? translation;

  /// Detected source language display name (auto-detect sessions).
  String? detectedLanguage;
  bool isFinal;
  final DateTime timestamp;

  String get visibleText {
    final translated = translation?.trim() ?? '';
    return translated.isNotEmpty ? translated : text;
  }
}
