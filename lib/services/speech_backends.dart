// Platform-swappable speech backend contracts.
//
// Desktop uses whisper-cli + the TTS server; phones use sherpa-onnx
// (whisper + Supertonic/Piper, fully offline). [AppController] talks only
// to these interfaces and picks the implementation by platform.

/// One transcribed chunk with the detected language code ('' when unknown).
typedef SttTranscript = ({String text, String languageCode});

abstract class SttBackend {
  Stream<SttTranscript> get onTranscription;
  bool get isReady;
  bool get isDownloading;
  String? get lastError;

  /// Unicode scripts the active language pair may produce (Latin implied).
  Set<String> get expectedScripts;
  set expectedScripts(Set<String> value);

  Future<void> init();
  void setPreferredLanguage(String? languageOrCode, {bool autoDetect = true});
  void feedPcmChunk(List<int> chunk);
  void reset();
  void dispose();
}

abstract class TtsBackend {
  Stream<bool> get onSpeakingChanged;
  bool get isSpeaking;
  String? get lastError;

  Future<void> init();
  Future<void> configure({String? language, String? voice});
  Future<void> speak(String text, {String? language});
  Future<void> stop();
  Future<void> dispose();
}
