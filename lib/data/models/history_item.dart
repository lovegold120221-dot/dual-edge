class HistoryItem {
  const HistoryItem({
    required this.id,
    required this.sourceText,
    required this.translatedText,
    required this.language1,
    required this.language2,
    required this.timestamp,
  });

  final String id;
  final String sourceText;
  final String translatedText;
  final String language1;
  final String language2;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'sourceText': sourceText,
    'translatedText': translatedText,
    'lang1': language1,
    'lang2': language2,
    'timestamp': timestamp.toIso8601String(),
  };

  factory HistoryItem.fromJson(Map<String, dynamic> json) {
    return HistoryItem(
      id: json['id']?.toString() ?? '',
      sourceText: json['sourceText']?.toString() ?? '',
      translatedText: json['translatedText']?.toString() ?? '',
      language1: json['lang1']?.toString() ?? '',
      language2: json['lang2']?.toString() ?? '',
      timestamp:
          DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
