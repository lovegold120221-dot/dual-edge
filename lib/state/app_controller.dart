import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_config.dart';
import '../data/eb_translator_prompt.dart';
import '../data/models/conversation_turn.dart';
import '../data/models/history_item.dart';
import '../data/models/translation_settings.dart';
import '../data/translation_data.dart';
import '../data/tts_voices.dart';
import '../services/firebase_service.dart';
import '../services/live_audio_service.dart';
import '../services/ollama_service.dart';
import '../services/ondevice_llm_service.dart';
import '../services/preference_store.dart';
import '../services/sherpa_stt_service.dart';
import '../services/sherpa_tts_service.dart';
import '../services/speech_backends.dart';
import '../services/stt_service.dart';
import '../services/transcription_filters.dart';
import '../services/tts_service.dart';
import '../services/tts_text_normalizer.dart';
import '../services/translation_service.dart';

class AppController extends ChangeNotifier {
  AppController({required this.config})
    : firebase = FirebaseService(config),
      _preferences = PreferenceStore(),
      _audio = LiveAudioService(),
      _stt = SttService(),
      _translation = TranslationService(config: config),
      _ollama = OllamaService(config: config) {
    // Desktop TTS needs the audio service for echo references.
    _tts = TtsService(baseUrl: config.kokoroTtsUrl, audio: _audio);
    // Phones run STT/TTS fully on-device (sherpa); desktop keeps
    // whisper-cli + the TTS server. Firebase Auth is unchanged.
    _sherpaStt = SherpaSttService(sttVariant: config.resolvedSttVariant);
    _sherpaTts = SherpaTtsService(audio: _audio);
  }

  final AppConfig config;
  final FirebaseService firebase;
  final PreferenceStore _preferences;
  final LiveAudioService _audio;
  final SttService _stt;
  late final TtsService _tts;
  final TranslationService _translation;
  final OllamaService _ollama;
  late final SherpaSttService _sherpaStt;
  late final SherpaTtsService _sherpaTts;

  /// True on phones: STT/TTS/LLM all run from on-device models.
  bool get useOnDeviceSpeech => SherpaSttService.isSupported;

  SttBackend get _sttBackend => useOnDeviceSpeech ? _sherpaStt : _stt;
  TtsBackend get _ttsBackend => useOnDeviceSpeech ? _sherpaTts : _tts;

  TranslationSettings settings = const TranslationSettings();
  final List<ConversationTurn> turns = <ConversationTurn>[];
  final List<HistoryItem> history = <HistoryItem>[];

  StreamSubscription<SttTranscript>? _sttSubscription;
  StreamSubscription<AudioInputFrame>? _audioSubscription;
  StreamSubscription<bool>? _ttsSpeakingSubscription;
  bool initialized = false;
  bool connected = false;
  bool connecting = false;
  bool micMuted = false;
  bool outputMuted = false;
  bool aiSpeaking = false;
  double micLevel = 0;
  String? lastError;

  /// On-device (phone) translator model state. Null progress = unknown yet.
  double? onDeviceDownloadProgress;
  String? onDeviceModelStatus;

  /// On-device (phone) speech model state (sherpa whisper + Supertonic).
  double? sttDownloadProgress;
  String? sttModelStatus;
  double? ttsDownloadProgress;
  String? ttsModelStatus;
  bool _handlingTranscription = false;

  /// Latest transcript queued while a prior turn is still being handled.
  SttTranscript? _pendingTranscript;

  /// Mic stays gated this long after TTS ends (room/speaker tail).
  static const echoReleaseDelay = Duration(milliseconds: 900);

  Future<void> initialize() async {
    await _preferences.initialize();
    settings = _preferences.loadSettings();
    // Migrate legacy cloud/gemini/chat model defaults to the local
    // eb-translator model (qwen2.5:0.5b via repo Modelfile).
    final storedModel = settings.model;
    if (storedModel.toLowerCase().contains('gemini') ||
        storedModel.contains(':cloud') ||
        storedModel.contains('eburon-mobile')) {
      settings = settings.copyWith(model: config.modelName);
      await _preferences.saveSettings(settings);
    }
    history.addAll(_preferences.loadHistory());
    firebase.addListener(_relayFirebaseChange);

    // Firebase may be unavailable on macOS (no DefaultFirebaseOptions).
    try {
      await firebase.initialize().timeout(const Duration(seconds: 3));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Firebase service init skipped: $e');
      }
    }

    // Show TranslatorScreen ASAP; heavy local services continue below.
    initialized = true;
    notifyListeners();

    try {
      await _ollama.init().timeout(const Duration(seconds: 8));
      if (_ollama.lastError != null) {
        lastError = _ollama.lastError;
      }
    } on TimeoutException {
      lastError = 'Ollama init timed out';
    } catch (e) {
      lastError = 'Ollama init failed: $e';
    }

    // Phones cannot reach Ollama; fetch the on-device GGUF in the
    // background so translation works fully offline afterwards.
    if (OnDeviceLlmService.isSupported) {
      unawaited(_prepareOnDeviceModel());
    }

    try {
      if (useOnDeviceSpeech) {
        // Phones fetch sherpa models in the background (one-time downloads).
        unawaited(_prepareSherpaStt());
      } else {
        // STT model download (if needed) runs in background inside SttService.
        await _stt.init();
        _applySttLanguageHint();
        if (_stt.lastError != null) {
          lastError = _stt.lastError;
          notifyListeners();
        }
        if (_stt.isDownloading) {
          unawaited(_watchSttDownload());
        }
      }
    } catch (e) {
      lastError = 'Speech recognition init failed: $e';
    }

    try {
      if (useOnDeviceSpeech) {
        unawaited(_prepareSherpaTts());
      } else {
        await _tts.init();
      }
    } catch (e) {
      lastError = 'Text-to-speech init failed: $e';
    }

    _ttsSpeakingSubscription = _ttsBackend.onSpeakingChanged.listen((speaking) {
      aiSpeaking = speaking;
      notifyListeners();
    });

    notifyListeners();
  }

  Future<void> _watchSttDownload() async {
    for (var i = 0; i < 180; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (_stt.isReady) {
        if (lastError != null &&
            lastError!.startsWith('Downloading Whisper model')) {
          lastError = null;
        }
        notifyListeners();
        return;
      }
      if (!_stt.isDownloading && _stt.lastError != null) {
        lastError = _stt.lastError;
        notifyListeners();
        return;
      }
    }
  }

  /// Background first-run fetch of the ~400 MB phone GGUF (resumable).
  /// Afterwards the translator works fully offline.
  Future<void> _prepareOnDeviceModel() async {
    final service = _translation.onDeviceService;
    try {
      if (await service.isModelDownloaded()) {
        onDeviceModelStatus = 'ready';
        onDeviceDownloadProgress = 1;
        notifyListeners();
        return;
      }
      onDeviceModelStatus = 'downloading';
      onDeviceDownloadProgress = 0;
      notifyListeners();
      final subscription = service.onDownloadProgress.listen((progress) {
        onDeviceDownloadProgress = progress;
        notifyListeners();
      });
      try {
        await service.ensureModel();
      } finally {
        await subscription.cancel();
      }
      onDeviceModelStatus = 'ready';
      onDeviceDownloadProgress = 1;
    } catch (e) {
      onDeviceModelStatus = 'download-failed';
      lastError =
          'On-device translator download failed — connect to Wi-Fi and retry: $e';
      if (kDebugMode) {
        debugPrint('on-device model prepare failed: $e');
      }
    }
    notifyListeners();
  }

  /// Background first-run fetch of a sherpa speech model, with progress
  /// surfaced for the settings drawer. Afterwards that modality is offline.
  Future<void> _prepareSherpaModel({
    required Future<void> Function() ensure,
    required double? Function() progressOf,
    required bool Function() downloading,
    required void Function(String?) setStatus,
    required void Function(double?) setProgress,
    required String label,
  }) async {
    setStatus('downloading');
    setProgress(0);
    notifyListeners();
    var done = false;
    Object? error;
    unawaited(
      ensure()
          .then((_) {
            done = true;
          })
          .catchError((Object e) {
            error = e;
            done = true;
          }),
    );
    while (!done) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      setProgress(progressOf());
      notifyListeners();
    }
    if (error != null) {
      setStatus('download-failed');
      lastError = '$label failed — connect to Wi-Fi and retry: $error';
    } else {
      setStatus('ready');
      setProgress(1);
    }
    notifyListeners();
  }

  Future<void> _prepareSherpaStt() => _prepareSherpaModel(
    ensure: () async {
      await _sherpaStt.init();
      _applySttLanguageHint();
    },
    progressOf: () => _sherpaStt.downloadProgress,
    downloading: () => _sherpaStt.isDownloading,
    setStatus: (status) => sttModelStatus = status,
    setProgress: (progress) => sttDownloadProgress = progress,
    label: 'On-device speech recognition download',
  );

  Future<void> _prepareSherpaTts() => _prepareSherpaModel(
    ensure: () => _sherpaTts.init(),
    progressOf: () => _sherpaTts.downloadProgress,
    downloading: () => _sherpaTts.isDownloading,
    setStatus: (status) => ttsModelStatus = status,
    setProgress: (progress) => ttsDownloadProgress = progress,
    label: 'On-device speech synthesis download',
  );

  void _relayFirebaseChange() => notifyListeners();

  /// Pass language hint into STT based on autoDetect / language1 / language2.
  void _applySttLanguageHint() {
    // Script guard follows the active pair so foreign-script whisper
    // hallucinations never become turns (Latin is always allowed).
    _sttBackend.expectedScripts = TranscriptionFilters.scriptsForLanguages(
      settings.language1,
      settings.language2,
    );
    if (settings.autoDetect) {
      _sttBackend.setPreferredLanguage(null, autoDetect: true);
    } else {
      // Fixed direction: language1 → language2; hint source language for STT.
      _sttBackend.setPreferredLanguage(settings.language1, autoDetect: false);
    }
  }

  Future<void> exportHistory() async {
    await _preferences.saveHistory(history);
    notifyListeners();
  }

  void clearHistory() {
    _preferences.clearHistory();
    history.clear();
    notifyListeners();
  }

  void updateSettings(TranslationSettings next) {
    settings = next;
    _preferences.saveSettings(next);
    _applySttLanguageHint();
    notifyListeners();
  }

  Future<void> signIn(String email, String password) =>
      firebase.signIn(email, password);

  Future<void> signUp(String email, String password) =>
      firebase.signUp(email, password);

  Future<void> sendPasswordReset(String email) =>
      firebase.sendPasswordReset(email);

  Future<void> signInWithGoogle() => firebase.signInWithGoogle();

  Future<void> signOut() async {
    await disconnect();
    await firebase.signOut();
  }

  Future<void> disconnect() async {
    stopLocalTranslation();
    connected = false;
    connecting = false;
    micLevel = 0;
    aiSpeaking = false;
    _pendingTranscript = null;
    await _ttsBackend.stop();
    await _audio.stopInput();
    await _audio.stopOutput();
    notifyListeners();
  }

  Future<void> connect() async {
    if (connected || connecting) return;
    connecting = true;
    lastError = null;
    notifyListeners();
    try {
      if (TranslationService.useOnDevice()) {
        // Phone path: no Ollama server exists — load the on-device GGUF
        // (downloads on first run; afterwards fully offline). Speech models
        // (sherpa whisper + Supertonic) must be ready too.
        onDeviceModelStatus ??= 'loading';
        sttModelStatus ??= 'loading';
        ttsModelStatus ??= 'loading';
        notifyListeners();
        await _translation.onDeviceService.ensureLoaded();
        if (!_translation.onDeviceService.isReady) {
          throw StateError(
            _translation.onDeviceService.lastError ??
                'On-device translator is not ready yet.',
          );
        }
        onDeviceModelStatus = 'ready';
        await _sherpaStt.init();
        if (!_sherpaStt.isReady) {
          throw StateError(
            _sherpaStt.lastError ??
                'On-device speech recognition is not ready yet.',
          );
        }
        sttModelStatus = 'ready';
        await _sherpaTts.init();
        ttsModelStatus = 'ready';
      } else {
        if (!_ollama.isRunning) {
          await _ollama.init();
        }
        if (!_ollama.isRunning) {
          throw StateError(
            _ollama.lastError ??
                'Ollama is not reachable at ${config.ollamaUrl}.',
          );
        }
      }
      _applySttLanguageHint();
      await startLocalTranslation();
      connected = true;
    } catch (e) {
      lastError = e.toString();
      connected = false;
      stopLocalTranslation();
      try {
        await _audio.stopInput();
        await _audio.stopOutput();
      } catch (_) {}
      if (kDebugMode) {
        debugPrint('connect failed: $e');
      }
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> startLocalTranslation() async {
    turns.clear();
    _sttBackend.reset();
    _pendingTranscript = null;
    stopLocalTranslation();

    _applySttLanguageHint();

    await _ttsBackend.configure(
      language: settings.language2,
      voice: settings.voice,
    );

    // Subscribe before starting capture so early frames are not dropped.
    _sttSubscription = _sttBackend.onTranscription.listen(
      _onTranscription,
      onError: (Object error) {
        lastError = error.toString();
        notifyListeners();
      },
    );

    _audioSubscription = _audio.frames.listen(
      (AudioInputFrame frame) {
        if (!connected && !connecting) return;
        final previousLevel = micLevel;
        micLevel = frame.level;
        if ((micLevel - previousLevel).abs() > 0.03) {
          notifyListeners();
        }
        if (micMuted || !frame.shouldTransmit) return;
        // Avoid feeding speaker echo into Whisper while TTS is talking.
        if (aiSpeaking) return;
        _sttBackend.feedPcmChunk(frame.bytes);
      },
      onError: (Object error) {
        lastError = error.toString();
        notifyListeners();
      },
    );

    await _audio.startInput();
  }

  Future<void> _onTranscription(SttTranscript result) async {
    final source = result.text.trim();
    final langCode = result.languageCode.trim().toLowerCase();
    if (source.isEmpty || !connected || micMuted) return;
    if (_handlingTranscription) {
      // Keep latest transcript instead of dropping while busy.
      _pendingTranscript = (text: source, languageCode: langCode);
      return;
    }
    _handlingTranscription = true;
    try {
      await _processTranscript(source, langCode);
    } finally {
      _handlingTranscription = false;
      final pending = _pendingTranscript;
      _pendingTranscript = null;
      if (pending != null &&
          pending.text.isNotEmpty &&
          connected &&
          !micMuted) {
        // Process the latest queued transcript after the current turn.
        unawaited(_onTranscription(pending));
      }
    }
  }

  /// Recent exchanges for LLM context (pronouns, terms, tone, repair).
  String _contextBlock() {
    final pairs = <String>[];
    for (var i = turns.length - 1; i >= 0 && pairs.length < 3; i--) {
      final turn = turns[i];
      if (turn.role != ConversationRole.agent) continue;
      final src = turn.transcription?.trim() ?? '';
      final tgt = turn.translation?.trim() ?? '';
      if (src.isEmpty || tgt.isEmpty) continue;
      var line = '$src -> $tgt';
      if (line.length > 240) line = '${line.substring(0, 240)}…';
      pairs.add(line);
    }
    if (pairs.isEmpty) return '';
    return pairs.reversed.join('\n');
  }

  Future<void> _processTranscript(String source, String langCode) async {
    try {
      final staffCode = TtsVoices.langCodeFor(settings.language1);
      turns.add(
        ConversationTurn(
          role: ConversationRole.user,
          text: source,
          isFinal: true,
        ),
      );
      notifyListeners();

      // Dynamic direction: staff speech goes to the guest language, anything
      // else goes to staff. A newly heard guest language becomes the paired
      // guest for the rest of the session.
      var sourceDisplay = settings.language1;
      var targetLanguage = settings.language2;
      String? detectedDisplay;
      if (settings.autoDetect && langCode.isNotEmpty) {
        detectedDisplay =
            displayNameForLanguageCode(langCode) ?? langCode.toUpperCase();
        if (langCode == staffCode) {
          sourceDisplay = settings.language1;
          targetLanguage = settings.language2;
        } else {
          sourceDisplay = displayNameForLanguageCode(langCode) ?? langCode;
          targetLanguage = settings.language1;
          final guestDisplay = displayNameForLanguageCode(langCode);
          if (guestDisplay != null && guestDisplay != settings.language2) {
            updateSettings(settings.copyWith(language2: guestDisplay));
          }
        }
      }

      final translated = await _translation.translateTurn(
        sourceText: source,
        sourceLanguage: sourceDisplay,
        targetLanguage: targetLanguage,
        context: _contextBlock(),
        systemPrompt: _localTranslateSystemPrompt(),
        model: settings.model,
      );

      if (translated == null || translated.isEmpty) {
        lastError = _translation.lastError ?? 'Translation failed';
        notifyListeners();
        return;
      }

      // Sanitized translation only — never speak source/transcription.
      // Normalized for TTS: no symbols, artifacts, or metadata.
      final speakText = TtsTextNormalizer.normalizeForSpeech(
        TranslationService.sanitizeTranslation(translated),
      );
      if (speakText.isEmpty) {
        lastError = 'Translation sanitized to empty';
        notifyListeners();
        return;
      }

      turns.add(
        ConversationTurn(
          role: ConversationRole.agent,
          text: speakText,
          transcription: source,
          translation: speakText,
          detectedLanguage: detectedDisplay,
          isFinal: true,
        ),
      );

      history.insert(
        0,
        HistoryItem(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          sourceText: source,
          translatedText: speakText,
          language1: settings.language1,
          language2: settings.language2,
          timestamp: DateTime.now(),
        ),
      );
      unawaited(_preferences.saveHistory(history));
      notifyListeners();

      if (!outputMuted && connected) {
        aiSpeaking = true;
        notifyListeners();
        try {
          await _ttsBackend.speak(speakText, language: targetLanguage);
        } finally {
          // Hold the mic gate through the room tail so speaker output is
          // never re-captured, then flush any contaminated STT audio.
          await Future<void>.delayed(echoReleaseDelay);
          _sttBackend.reset();
          aiSpeaking = false;
          notifyListeners();
        }
      }
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
    }
  }

  /// Shared wording with the desktop Ollama path (see EbTranslatorPrompt).
  String _localTranslateSystemPrompt() =>
      EbTranslatorPrompt.system(medicalMode: settings.medicalMode);

  void stopLocalTranslation() {
    _sttSubscription?.cancel();
    _sttSubscription = null;
    _audioSubscription?.cancel();
    _audioSubscription = null;
    _sttBackend.reset();
    _pendingTranscript = null;
  }

  @override
  void dispose() {
    stopLocalTranslation();
    _ttsSpeakingSubscription?.cancel();
    unawaited(_tts.dispose());
    _stt.dispose();
    unawaited(_sherpaTts.dispose());
    _sherpaStt.dispose();
    unawaited(_translation.dispose());
    firebase.removeListener(_relayFirebaseChange);
    firebase.dispose();
    unawaited(_audio.dispose());
    super.dispose();
  }
}
