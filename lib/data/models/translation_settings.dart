import '../../core/app_config.dart';
import '../translation_data.dart';

class TranslationSettings {
  /// TTS voice gender: 'male' (default) or 'female'.
  static const String voiceMale = 'male';
  static const String voiceFemale = 'female';

  /// Legacy stored voice ids that were feminine voices.
  static const Set<String> feminineVoices = <String>{
    'female',
    'af_heart',
    'af_alloy',
    'af_aoede',
    'af_bella',
    'af_jessica',
    'af_kore',
    'af_nicole',
    'af_nova',
    'af_river',
    'af_sarah',
    'af_sky',
    'bf_alice',
    'bf_emma',
    'bf_isabella',
    'bf_lily',
    'ff_siwis',
    'if_sara',
    'pf_dora',
    'jf_alpha',
    'zf_xiaobei',
    'hf_alpha',
  };

  /// Normalize any stored voice value to male/female (male default).
  static String normalizeVoice(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    if (v == voiceFemale || feminineVoices.contains(v)) return voiceFemale;
    return voiceMale;
  }

  const TranslationSettings({
    this.model = AppConfig.defaultModel,
    this.voice = voiceMale,
    this.language1 = 'Dutch (Flemish)',
    this.language2 = 'English (US)',
    this.topic = 'Medical Consultation',
    this.medicalMode = true,
    this.autoDetect = true,
  });

  final String model;
  final String voice;
  final String language1;
  final String language2;
  final String topic;
  final bool medicalMode;
  final bool autoDetect;

  String get systemPrompt => generateSystemPrompt(
    language1: language1,
    language2: language2,
    topic: topic,
    autoDetect: autoDetect,
    medicalMode: medicalMode,
  );

  TranslationSettings copyWith({
    String? model,
    String? voice,
    String? language1,
    String? language2,
    String? topic,
    bool? medicalMode,
    bool? autoDetect,
  }) {
    return TranslationSettings(
      model: model ?? this.model,
      voice: voice ?? this.voice,
      language1: language1 ?? this.language1,
      language2: language2 ?? this.language2,
      topic: topic ?? this.topic,
      medicalMode: medicalMode ?? this.medicalMode,
      autoDetect: autoDetect ?? this.autoDetect,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'model': model,
    'voice': voice,
    'language1': language1,
    'language2': language2,
    'topic': topic,
    'medicalMode': medicalMode,
    'autoDetect': autoDetect,
  };

  factory TranslationSettings.fromJson(Map<String, dynamic> json) {
    return TranslationSettings(
      model: json['model']?.toString() ?? AppConfig.defaultModel,
      voice: normalizeVoice(json['voice']?.toString()),
      language1: json['language1']?.toString() ?? 'Dutch (Flemish)',
      language2: json['language2']?.toString() ?? 'English (US)',
      topic: json['topic']?.toString() ?? 'Medical Consultation',
      medicalMode: json['medicalMode'] as bool? ?? true,
      autoDetect: json['autoDetect'] as bool? ?? true,
    );
  }
}
