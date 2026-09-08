# Dual Translate — native Flutter app

Native Android and iOS conversion of the parent React/Vite Dual Translate
(Multilinguahe) app. Package name: `dual_translate`. Version: `1.0.2+2`.
Display name: **Dual Translate**. Application id / bundle id:
`ai.eburon.dualtranslate`.

This is a real-time dual-language **voice** translator for conversations
between staff (default: Dutch/Flemish) and a guest speaker. It is aimed at
live interpretation, with medical consultation as the default mode. The
Flutter app is fully local and account-free: on-device LLM translation,
sherpa speech recognition and synthesis, native full-duplex PCM audio, and
device-persisted settings and history.

Requires Flutter **3.44+** (Dart **^3.12.2**). The checkout was last built
with Flutter 3.44.6 / Dart 3.12.2.

## What it does

- No accounts, no sign-in: the translator opens directly and works fully
  offline after the one-time model downloads.
- A dark Material 3 translator: conversation transcript, LIVE
  badge, settings drawer, mic visualizer, and a control tray (mic mute, speaker
  mute, session reset, play/pause).
- Gemini Live (`gemini-3.1-flash-live-preview` by default) streams 16 kHz mono
  PCM16 microphone audio and plays 24 kHz PCM16 speech back. Independent
  **INPUT** and **TRANSLATION** bubbles update from `inputTranscription` /
  `outputTranscription` (plus model text). Partial text streams with a cursor
  until the turn is finalized.
- Language pairing is Dutch/Flemish vs. the latest guest language. The Live
  `setGuestLanguage` tool updates Language 2 when a new non-Dutch language is
  detected. Auto-detect, full language/voice menus, medical vs. general mode,
  topic-aware prompt generation, and medical terminology lists are included.
- Settings and history persist on device (`shared_preferences`). PDF share of
  history. Eburon emblem on launcher icons, header, and empty session.

The conversation UI is a single scrolling transcript (input left, translation
right), not a split dual-pane editor.

## Project structure

```text
lib/
  main.dart             AppController bootstrap (no accounts, no backends)
  app.dart              MaterialApp; loading → translator
  core/                 dart-define AppConfig + dark Material theme
  data/                 languages, voices, prompts, models
  services/             on-device LLM/STT/TTS, PCM audio, echo guard,
                        preferences, PDF export
  state/                AppController orchestration
  ui/                   translator, settings drawer, conversation + mic widgets
android/app/src/main/kotlin/ai/eburon/dualtranslate/
                        AudioRecord/AudioTrack duplex bridge
ios/Runner/             AVAudioEngine duplex bridge
assets/branding/        app_logo.png (Eburon emblem)
test/                   unit + widget tests
integration_test/       native duplex audio on a device
tool/                   Gemini Live / transcription smoke scripts
config.example.json     dart-define template (copy to config.local.json)
```

Routing is not named-route based. `DualTranslateApp` picks the home screen:

1. Loading while services initialize
2. `TranslatorScreen` — always, no account gate

## How translation works

Defaults (see `TranslationSettings`): staff language **Dutch (Flemish)**,
guest language **English (US)**, voice **Male**, topic
**Medical Consultation**, medical mode and auto-detect **on**. The AI Voice
setting is Male/Female and selects the Supertonic speaker (male ≈ 122 Hz
default). Per-language Piper voices use pitch-verified male voices where a
male bundle exists (Basque, Icelandic, Malayalam, Nepali, and others);
Catalan, Kurdish, and Luxembourgish have no male Piper bundle, MMS voices
are fixed single voices, and Chinese falls back to Supertonic English —
no local male voice exists for those yet.

With **auto-detect on**, the speaker may use *any* language not just the
pair: the speech recognizer identifies the spoken language per turn
(whisper LID), staff speech goes to the guest language and everything else
to staff, bubbles show `· HEARD <LANGUAGE>`, replies are spoken in the
matching voice, and a newly heard guest language becomes the paired guest.
With auto-detect off, translation is fixed Language 1 → Language 2.

## Translation quality pipeline

Every turn runs fully automatically (never asks, never stalls):

`Mic → STT (+language ID) → translate meaning → fluency polish → language gate → TTS scrub → voice`

- **STT**: Silero VAD segments speech into complete utterances (never
  cut words, silence never decoded) with whisper language ID, silence
  gating, and hallucination/script/bracket filters. Only finalized
  utterances translate — partials are held (max-speech cuts accumulate
  until the utterance ends), never sent to the engine
- **Translate**: explicit-direction meaning transfer with the last
  exchanges as context (pronouns, terms, tone, repair)
- **Polish**: rewrite as a fluent native speaker (grammar, idiom, rhythm);
  falls back to stage one on any failure — output is never worse
- **Language gate**: the final text must provably be the target language
  (no echo, no foreign script, no source-language wording, no looped
  garble, no length drift) or the turn is dropped instead of spoken
- **Repair cascade**: polished → stage-one → one fresh-sampling retry →
  drop with an error (never spoken, never asks the user)
- **TTS scrub**: deterministic removal of markdown, symbols, emoji, and
  artifacts so only speakable text reaches Supertonic/Piper/MMS

`generateSystemPrompt` builds a strict translator instruction (not a chat
agent):

- **Dutch/Flemish group** ↔ **latest paired other language** (`language2`)
- Guest speech in a *new* other language should call `setGuestLanguage`
- Dutch/Flemish input is translated into the current guest language
- Auto-detect adds Tagalog/English-aware transcription rules
- Medical mode injects terminology for Dutch (Flemish), French, German,
  Spanish, Italian, and Portuguese (Portugal)

Gemini Live WebSocket:

`wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`

Setup enables AUDIO responses, a prebuilt voice, `setGuestLanguage`, input
and output audio transcription, and high-sensitivity automatic activity
detection. `AppController` finalizes turns (local history + Firestore) after
`turnComplete`, handles interruption by stopping playback, and mutes mic or
output independently.

## Persistence (local only, no accounts)

- Settings and history live entirely on device (`shared_preferences` keys
  `dual_translate_settings` and `translation-history-storage`).
- No sign-in, no cloud sync, no tracking. PDF export shares history
  directly from the device.

## Full-duplex audio

Microphone capture and model playback stay on separate native transports so
speaker writes cannot block or re-enter the mic stream.

- **Android:** communication-mode `AudioRecord` / `AudioTrack`, AEC / noise
  suppression / AGC when the device provides them, shared audio session.
  Permissions: `INTERNET`, `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`.
- **iOS:** `AVAudioEngine` with `playAndRecord` / `voiceChat`, voice
  processing on I/O nodes. `NSMicrophoneUsageDescription` is set. Minimum
  iOS in the Podfile: **15.0**.
- Channel names (historical): `ai.eburon.translator/live_pcm_v1` and
  `.../live_pcm_input_v1`.

`DuplexEchoGuard` keeps a short 16 kHz reference of PCM sent to the speaker.
While playback is active, speaker-correlated mic frames are not sent to
Gemini. Sustained independent speech can barge in; the mic reopens when
output stops.

Capture will refuse to start unless the native layer reports a protected
duplex engine (`duplexEngine`, `separateInputTransport`,
`softwareEchoGuardEnabled`).

## Configure without committing credentials

```sh
cp config.example.json config.local.json
```

`config.local.json` is gitignored. Fill values locally; never commit them.

Translation runs fully offline after the one-time model downloads; no API
keys or accounts are required. Copy `config.example.json` to
`config.local.json` to override the default Ollama URL, model names, or
model download URLs (all optional — defaults work out of the box).


## Run and build

```sh
flutter pub get
flutter run --dart-define-from-file=config.local.json
```

Release (pass the same dart-defines so local endpoints stay configured):

```sh
flutter build apk --release --dart-define-from-file=config.local.json
flutter build appbundle --release --dart-define-from-file=config.local.json
flutter build ios --release --dart-define-from-file=config.local.json
```

Android `applicationId` / iOS `PRODUCT_BUNDLE_IDENTIFIER`:
`ai.eburon.dualtranslate`. Android `minSdk` is Flutter’s default
(`flutter.minSdkVersion`). Release signing uses `android/key.properties` and
a local keystore when that file exists (both gitignored). Configure a
production keystore before distributing an APK or Play bundle.

`web/` only contains Digital Asset Links (`web/well-known/assetlinks.json`).
There is no Flutter web host (`index.html` / `manifest.json`), so this is
not a supported `flutter run -d chrome` target.

## Tests and smoke checks

```sh
flutter analyze
dart format --set-exit-if-changed .
flutter test
flutter test integration_test/duplex_audio_integration_test.dart -d <device>
```

| Path | What it covers |
| --- | --- |
| `test/widget_test.dart` | Prompt pairing rules; configuration screen copy |
| `test/live_transcription_test.dart` | Live event decoding (camelCase and snake_case) |
| `test/realtime_transcription_widget_test.dart` | Partial INPUT / TRANSLATION bubbles |
| `test/duplex_echo_guard_test.dart` | Echo suppress, barge-in, playback clear |
| `integration_test/duplex_audio_integration_test.dart` | Native capture + playback + echo suppression on device |

Provider smokes (need a real config file; they never print the API key):

```sh
dart run tool/smoke_gemini_live.dart config.local.json
dart run tool/smoke_realtime_transcription.dart config.local.json <16khz-mono-pcm16>
```

`smoke_realtime_transcription.dart` streams a 16 kHz mono PCM16 sample
through Live and requires both input and output transcription events.

Analyzer uses `package:flutter_lints/flutter.yaml`. No coverage threshold.

Acoustic quality should be checked on the physical phone
at the intended speaker volume; simulators cannot reproduce room echo.

## Production key boundary

Direct Gemini Live access matches the original web architecture, but a
`--dart-define` API key is embedded in the compiled client. For an
externally distributed production app, issue short-lived Live credentials
from a trusted backend instead of shipping a long-lived shared key.

## Dependencies (direct)

`flutter_secure_storage`, `http`, `shared_preferences`,
`record` (mic permission helper), `web_socket_channel`, `pdf`, `printing`,
`intl`.
`flutter_secure_storage` is declared but unused.

## eb-translator model (Ollama + qwen2.5:0.5b)

Translation runs on the local **`eb-translator`** model, built from
`gemma3:4b` (Google, multilingual incl. Tagalog/Dutch) with the STRICT MODE
system prompt (pure realtime translator doctrine: Dutch/Flemish ↔ latest
paired guest language, dynamic monitoring, command-ignore, no meta-chat)
and deterministic decoding (`temperature 0`, `top_p 0.9`, `top_k 40`). Qwen2.5 0.5B–3B were tried and produce Tagalog
word salad on medical sentences. The definition lives in the repo-root
`Modelfile`:

```sh
ollama pull gemma3:4b
ollama create eb-translator -f Modelfile
ollama run eb-translator "Translate to Tagalog: I have a fever."
```

Verify the wiring end to end (checks `/api/tags` for the model, then a
live EN → NL translation):

```sh
dart run tool/smoke_ollama_translate.dart config.local.json
```

`config.example.json` defaults to `"OLLAMA_MODEL": "eb-translator"`. Legacy
`eburon-mobile` installs were conversational chat models, not translators;
stored settings still pointing at them are migrated automatically, and
`TranslationService.resolveModel` canonicalizes them to `eb-translator`.

## On-device phone inference (Android / iOS)

Phones cannot run an Ollama server, so on Android/iOS the same Qwen2.5 0.5B
weights run **fully on-device** via llama.cpp (`flutter_local_llm`, ChatML
template, Metal on iOS / Vulkan+OpenMP on Android, deterministic sampling
matching the Modelfile). Desktop keeps using Ollama; backend selection is
automatic (`TranslationService.useOnDevice`), and both backends share the
exact prompt builders in `lib/data/eb_translator_prompt.dart`.

First launch downloads `qwen2.5-0.5b-instruct-q4_k_m.gguf` (~400 MB,
resumable, Hugging Face) into Application Support — progress is shown in the
settings drawer under “On-device translator”. Afterwards translation works
with the radio off. Override the URL with
`--dart-define=EB_TRANSLATOR_GGUF_URL=…` (or `EB_TRANSLATOR_GGUF_URL` in the
dart-define file).

Build validation (engines are bundled as `libflutter_local_llm.so` and
`sherpa-onnx`/`onnxruntime` `.so`s):

```sh
flutter build apk --debug   # Android SDK + NDK r28 + CMake 3.22 required
```

## On-device speech: STT + TTS (Android / iOS)

Everything runs from local models, no accounts:

| Modality | Desktop | Phone (offline after first fetch) |
| --- | --- | --- |
| STT | whisper-cli + ggml bins | sherpa whisper base int8, multilingual |
| LLM | Ollama `eb-translator` | Qwen2.5 0.5B GGUF via llama.cpp |
| TTS | multilingual server (below) | sherpa Supertonic + per-language Piper |

Phone speech models download once (resumable) into Application Support —
whisper encoder/decoder/tokens from Hugging Face (`csukuangfj`), Kokoro
`model.onnx` + `voices.bin` + `tokens.txt` plus `espeak-ng-data.zip`, and one
~21 MB Piper bundle per spoken non-English language — with progress in
Settings → “On-device models”. STT decodes inside a worker isolate so the UI
never blocks; TTS streams synthesized chunks straight into the native duplex
output, keeping the mic echo gate (`aiSpeaking`) accurate.

Backend selection is automatic (`SherpaSttService.isSupported`); desktop
behavior is byte-identical to before (shared `TranscriptionFilters`).
Tune the phone STT size with `--dart-define=SHERPA_STT_VARIANT=tiny`
(`tiny` ≈ 100 MB, `base` ≈ 200 MB, default `base`).

## Multilingual TTS (Supertonic server + Piper/MMS voices)

`tool/kokoro-tts-server/server.js` speaks each translation in its own
language: **Supertonic 3** covers 31 languages in one 129 MB bundle
(English, Dutch, French, German, Spanish, Korean, Japanese, …),
remaining covered languages use native per-language Piper voices
(sherpa int8 bundles, ~21 MB each, loaded lazily into
`tool/kokoro-tts-server/models/` — gitignored), long-tail languages
(Tagalog, Thai, Bengali, …) use the local MMS sidecar
(`mms_server.py`, Meta MMS-TTS, offline after first download), and
anything else falls back to Supertonic English. Phones use the same voice
table (`lib/data/tts_voices.dart`) with the same engines via sherpa —
except MMS, which is desktop-only for now.

Why not Kokoro: the `kokoro-js` frontend phonemizes everything as English,
so French/Dutch text through Kokoro voices is mispronounced; Supertonic
phonemizes all 31 languages natively with better quality. The `/tts`
endpoint takes `text`, `voice` (legacy Kokoro ids still accepted),
`language` (preferred), and `speed`, and reports the choice via
`X-TTS-Engine` / `X-TTS-Language` headers. `GET /voices` lists the table;
output is always PCM16 mono WAV.

## macOS local STT (whisper-cpp)

Debug/Release entitlements set `com.apple.security.app-sandbox` to **false** so the app can:

- `Process.start` Homebrew `/opt/homebrew/bin/whisper-cli`
- Call Ollama at `http://localhost:11434`

Install: `brew install whisper-cpp`. On first `SttService.init()`, `ggml-tiny.bin` is downloaded via curl into Application Support (`…/models/ggml-tiny.bin`). Ensure Ollama is running with model `eb-translator` (or your `--dart-define=OLLAMA_MODEL=…`).

