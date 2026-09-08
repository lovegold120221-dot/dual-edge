# Dual Translate — native Flutter app

Native Android and iOS conversion of the parent React/Vite Dual Translate
(Multilinguahe) app. Package name: `dual_translate`. Version: `1.0.2+2`.
Display name: **Dual Translate**. Application id / bundle id:
`ai.eburon.dualtranslate`.

This is a real-time dual-language **voice** translator for conversations
between staff (default: Dutch/Flemish) and a guest speaker. It is aimed at
live interpretation, with medical consultation as the default mode. The
Flutter app keeps the product’s working boundaries rather than only copying
the web UI: Gemini Live over WebSocket, native full-duplex PCM audio, Firebase
Authentication, per-user Firestore history, and device-persisted settings.

Requires Flutter **3.44+** (Dart **^3.12.2**). The checkout was last built
with Flutter 3.44.6 / Dart 3.12.2.

## What it does

- Sign in with email/password, create an account, reset password, or continue
  with Google. Auth state gates the translator. A Super Admin badge is shown
  for a small hardcoded email allowlist; there is no in-app admin dashboard.
- After sign-in, a dark Material 3 translator: conversation transcript, LIVE
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
- Settings and history persist on device (`shared_preferences`). Completed
  turns also sync to Firestore `users/{uid}/translations`. PDF share of
  history. Eburon emblem on launcher icons, auth, header, and empty session.

The conversation UI is a single scrolling transcript (input left, translation
right), not a split dual-pane editor.

## Project structure

```text
lib/
  main.dart             Firebase.initializeApp + AppController
  app.dart              MaterialApp; loading → config/auth/translator
  firebase_options.dart FlutterFire options (android / ios / web)
  core/                 dart-define AppConfig + dark Material theme
  data/                 languages, voices, prompts, models
  services/             Firebase, Gemini Live, PCM audio, echo guard,
                        preferences, PDF export
  state/                AppController orchestration
  ui/                   auth, configuration, translator, settings drawer,
                        conversation + mic widgets
android/app/src/main/kotlin/ai/eburon/dualtranslate/
                        AudioRecord/AudioTrack duplex bridge
ios/Runner/             AVAudioEngine duplex bridge + OAuth inject script
assets/branding/        app_logo.png (Eburon emblem)
test/                   unit + widget tests
integration_test/       native duplex audio on a device
tool/                   Gemini Live / transcription / Firebase smoke scripts
config.example.json     dart-define template (copy to config.local.json)
```

Routing is not named-route based. `DualTranslateApp` picks the home screen:

1. Loading while auth initializes
2. `ConfigurationScreen` if Firebase failed to become ready
3. `AuthScreen` if there is no signed-in user
4. `TranslatorScreen` otherwise

A missing `GEMINI_API_KEY` does **not** block auth. After sign-in the
translator shows a banner and refuses to connect until the key is baked in
via `--dart-define-from-file`.

## How translation works

Defaults (see `TranslationSettings`): staff language **Dutch (Flemish)**,
guest language **English (US)**, voice **Male**, topic
**Medical Consultation**, medical mode and auto-detect **on**. The AI Voice
setting is Male/Female and selects the Supertonic speaker (male ≈ 122 Hz
default); per-language Piper/MMS voices are single-voice models.

With **auto-detect on**, the speaker may use *any* language not just the
pair: the speech recognizer identifies the spoken language per turn
(whisper LID), staff speech goes to the guest language and everything else
to staff, bubbles show `· HEARD <LANGUAGE>`, replies are spoken in the
matching voice, and a newly heard guest language becomes the paired guest.
With auto-detect off, translation is fixed Language 1 → Language 2.

## Translation quality pipeline

Every turn runs fully automatically (never asks, never stalls):

`Mic → STT (+language ID) → translate meaning → fluency polish → language gate → TTS scrub → voice`

- **STT**: whisper with silence gating, hallucination/script/bracket filters
- **Translate**: explicit-direction meaning transfer with the last
  exchanges as context (pronouns, terms, tone, repair)
- **Polish**: rewrite as a fluent native speaker (grammar, idiom, rhythm);
  falls back to stage one on any failure — output is never worse
- **Language gate**: the final text must provably be the target language
  (no echo, no foreign script, no source-language wording) or the turn is
  dropped instead of spoken
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

## Auth, Firebase, persistence

The app uses the **FlutterFire plugins** (`firebase_core`, `firebase_auth`,
`cloud_firestore`), not the older Identity Toolkit / Realtime Database REST
client described in earlier drafts.

- Options: `lib/firebase_options.dart` (FlutterFire CLI; project
  `eburon-bd040`). Do not treat those client keys as server secrets, but do
  not paste them elsewhere.
- Native Google files (gitignored): `android/app/google-services.json` and
  `ios/Runner/GoogleService-Info.plist`. Copy them into place for a fresh
  checkout. The Android Google Services Gradle plugin is enabled.
- Auth: email/password sign-in, registration, password reset, Google
  (native `authenticate()` / web popup). First sign-up writes
  `users/{uid}`.
- History: `users/{uid}/translations/{id}` (source, translation, languages,
  timestamp). Settings merge `language1` / `language2` / `autoDetect` onto
  the user document. Deployable rules are in `firestore.rules` (owner-only
  `users/{userId}` and that translations subcollection). `firestore.indexes.json`
  is empty.
- Local cache: `shared_preferences` keys `dual_translate_settings` and
  `translation-history-storage`. Cloud sync failures surface as a banner;
  the device copy is kept.
- `tool/smoke_firebase_rest.dart` still probes Authentication + Realtime
  Database REST and expects `FIREBASE_API_KEY` / `FIREBASE_DATABASE_URL` in
  a JSON file. That is a leftover connectivity check, not how the running
  app talks to Firebase.

`firebase.json` records email/password + Google Sign-In for the Eburon
Translator brand and points at the Firestore rules files. There is no
Realtime Database usage in Dart.

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

Required to **stream**:

| Dart define | Purpose |
| --- | --- |
| `GEMINI_API_KEY` | Gemini Live WebSocket key |

Optional, for native Google Sign-In:

| Dart define | Purpose |
| --- | --- |
| `GOOGLE_SERVER_CLIENT_ID` | Web OAuth client ID (Android server client ID / ID-token audience) |
| `GOOGLE_CLIENT_ID` | iOS OAuth client ID |
| `GOOGLE_IOS_REVERSED_CLIENT_ID` | iOS reversed URL scheme |

Email/password does not need the Google defines. Android Google Sign-In
fails with `clientConfigurationError` if `GOOGLE_SERVER_CLIENT_ID` is
empty (`serverClientId must be provided on Android`).

During iOS builds, `ios/Runner/inject_google_oauth_redirect.sh` copies those
client IDs and the return URL scheme into the built `Info.plist`.

Do not copy a Google OAuth `client_secret*.json` into the client. Only
client IDs belong in dart-defines.

Firebase is **not** passed through dart-defines anymore. It comes from
`firebase_options.dart` plus the gitignored Google services files.

## Run and build

```sh
flutter pub get
flutter run --dart-define-from-file=config.local.json
```

Release (pass the same dart-defines so Gemini/Google stay configured):

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
not a supported `flutter run -d chrome` target even though
`firebase_options.dart` lists web options.

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
dart run tool/smoke_firebase_rest.dart <json-with-FIREBASE_API_KEY-and-DATABASE_URL>
```

`smoke_realtime_transcription.dart` streams a 16 kHz mono PCM16 sample
through Live and requires both input and output transcription events.

Analyzer uses `package:flutter_lints/flutter.yaml`. No coverage threshold.

A real signed-in session still needs enabled Auth providers and deployed
Firestore rules. Acoustic quality should be checked on the physical phone
at the intended speaker volume; simulators cannot reproduce room echo.

## Production key boundary

Direct Gemini Live access matches the original web architecture, but a
`--dart-define` API key is embedded in the compiled client. For an
externally distributed production app, issue short-lived Live credentials
from a trusted backend instead of shipping a long-lived shared key.

## Dependencies (direct)

`flutter_secure_storage`, `google_sign_in`, `http`, `shared_preferences`,
`record` (mic permission helper), `web_socket_channel`, `pdf`, `printing`,
`intl`, `firebase_core`, `firebase_auth`, `cloud_firestore`.
`flutter_secure_storage` is declared but unused; session state is Firebase
Auth, not a custom token store.

## eb-translator model (Ollama + qwen2.5:0.5b)

Translation runs on the local **`eb-translator`** model, built from
`gemma3:4b` (Google, multilingual incl. Tagalog/Dutch) with a strict
translation-only system prompt and deterministic decoding (`temperature 0`,
`top_p 0.9`, `top_k 40`). Qwen2.5 0.5B–3B were tried and produce Tagalog
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

Sign-in stays with Firebase Auth — everything else runs from local models:

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

