import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/history_item.dart';
import '../data/models/translation_settings.dart';

class PreferenceStore {
  static const _settingsKey = 'dual_translate_settings';
  static const _historyKey = 'translation-history-storage';

  SharedPreferences? _preferences;

  Future<void> initialize() async {
    _preferences = await SharedPreferences.getInstance();
  }

  TranslationSettings loadSettings() {
    final raw = _preferences?.getString(_settingsKey);
    if (raw == null || raw.isEmpty) return const TranslationSettings();
    try {
      return TranslationSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on Object {
      return const TranslationSettings();
    }
  }

  Future<void> saveSettings(TranslationSettings settings) async {
    await _preferences?.setString(_settingsKey, jsonEncode(settings.toJson()));
  }

  List<HistoryItem> loadHistory() {
    final raw = _preferences?.getString(_historyKey);
    if (raw == null || raw.isEmpty) return <HistoryItem>[];
    try {
      final decoded = jsonDecode(raw);
      final state = decoded is Map ? decoded['state'] : null;
      final list = state is Map ? state['history'] : decoded;
      if (list is! List) return <HistoryItem>[];
      return list
          .whereType<Map>()
          .map((item) => HistoryItem.fromJson(Map<String, dynamic>.from(item)))
          .where((item) => item.sourceText.isNotEmpty)
          .toList(growable: true);
    } on Object {
      return <HistoryItem>[];
    }
  }

  Future<void> saveHistory(List<HistoryItem> history) async {
    await _preferences?.setString(
      _historyKey,
      jsonEncode(history.map((item) => item.toJson()).toList()),
    );
  }

  void clearHistory() {
    _preferences?.remove(_historyKey);
  }
}
