# Repository Guidelines

## Project Structure & Module Organization

- `lib/main.dart` — entry point: `AppController` bootstrap (no accounts)
- `lib/app.dart` — `DualTranslateApp` with routing: Loading → `TranslatorScreen` (no sign-in)
- `lib/core/app_config.dart` — `AppConfig.fromEnvironment()` reads dart-defines: `GEMINI_API_KEY`, `GOOGLE_CLIENT_ID`, `GOOGLE_SERVER_CLIENT_ID`, `GOOGLE_IOS_REVERSED_CLIENT_ID`; `hasGemini` checks `GEMINI_API_KEY` is non-empty
- `lib/core/app_theme.dart` — dark Material 3 theme, `buildAppTheme()`
- `lib/data/` — languages, voices, medical terminology, system prompt generation (`translation_data.dart`); models: `conversation_turn.dart`, `history_item.dart`, `translation_settings.dart`
- `lib/services/` — on-device LLM/STT/TTS, `LiveAudioService` (native duplex PCM), `DuplexEchoGuard` (echo cancellation), `PdfExportService`, `PreferenceStore`
- `lib/state/app_controller.dart` — orchestrates auth, connection, translation turns, history, settings, persistence; `canStream` requires `hasGemini && user != null`
- `lib/ui/` — auth, configuration, translator, settings drawer, conversation widgets
- Platform audio bridges: `android/app/src/main/kotlin/` (AudioRecord/AudioTrack duplex), `ios/Runner/` (AVAudioEngine duplex)
- `test/` — unit/widget tests; `integration_test/duplex_audio_integration_test.dart` — native full-duplex audio on **physical device**
- `assets/branding/` — app_logo.png (Eburon emblem)
- `tool/` — smoke scripts: `smoke_gemini_live.dart`, `smoke_realtime_transcription.dart`, `smoke_ollama_translate.dart`
- Branding/assets are under `assets/branding/`; manual API smoke checks in `tool/`

## Build, Test, and Development Commands

- `flutter pub get` — installs dependencies from `pubspec.lock`
- `flutter run --dart-define-from-file=config.local.json` — runs the configured app on a selected device
- `flutter analyze` — applies `flutter_lints` rules from `analysis_options.yaml`
- `dart format --set-exit-if-changed .` — checks canonical Dart formatting
- `flutter test` — runs all unit and widget tests in `test/`
- `flutter test integration_test/duplex_audio_integration_test.dart -d <device-id>` — verifies native full-duplex audio on a **physical device** (simulators cannot reproduce room echo)
- `flutter build apk --release --dart-define-from-file=config.local.json` — Android release APK; use `appbundle` or `ios` for other targets
- `flutter build appbundle --release --dart-define-from-file=config.local.json`
- `flutter build ios --release --dart-define-from-file=config.local.json`

Run smoke scripts when changing provider integrations:
- `dart run tool/smoke_gemini_live.dart config.local.json`
- `dart run tool/smoke_realtime_transcription.dart config.local.json <16khz-mono-pcm16>`
- `dart run tool/smoke_ollama_translate.dart config.local.json`

## Coding Style & Naming Conventions

- Dart two-space indentation; run `dart format` before submitting
- Name files `lower_snake_case.dart`, types `UpperCamelCase`, members `lowerCamelCase`
- Keep UI code in widgets; state transitions in `AppController`; network, persistence, or audio concerns in focused services
- Do not suppress analyzer warnings without a narrow, documented reason
- `AppConfig` reads from dart-defines via `String.fromEnvironment()`; missing `GEMINI_API_KEY` means `hasGemini` is false and the translator cannot connect

## Testing Guidelines

- Use `flutter_test`; name tests `*_test.dart` and describe observable behavior
- Add unit tests for parsing and signal logic, widget tests for visible state, integration tests for platform channels or real audio
- No coverage threshold is configured, but every behavior change should include a regression test
- Run `flutter analyze` and the relevant test suite before opening a pull request
- Key test files:
  - `test/widget_test.dart` — prompt pairing rules; configuration screen copy
  - `test/live_transcription_test.dart` — Live event decoding (camelCase and snake_case)
  - `test/realtime_transcription_widget_test.dart` — partial INPUT/TRANSLATION bubbles
  - `test/duplex_echo_guard_test.dart` — echo suppress, barge-in, playback clear
- Integration tests require a **physical device**; simulators cannot reproduce room echo or protected duplex audio

## Commit & Pull Request Guidelines

- This checkout has no Git history; no project-specific commit format can be inferred
- Use short, imperative subjects such as `Fix duplex echo suppression`
- Keep commits focused; pull requests should explain the user-visible change, list verification commands and devices, link related issues, and include screenshots for UI work or logs for native-audio changes

## Security & Configuration

- Copy `config.example.json` to ignored `config.local.json`; never commit real API keys
- `config.local.json` is gitignored; fill values locally
- Never commit Ollama/translation endpoint overrides with secrets, Android signing files, keystores, or client secrets
- `GEMINI_API_KEY` is embedded in the compiled client via `--dart-define`; for production, issue short-lived Live credentials from a trusted backend instead of shipping a long-lived shared key
- Android `GOOGLE_SERVER_CLIENT_ID` is required for Google Sign-In; empty value causes `clientConfigurationError`
- Native Google files are gitignored: `android/app/google-services.json` and `ios/Runner/GoogleService-Info.plist`; copy them into place for a fresh checkout
- Console-side Firebase files (`firebase.json`, `firestore.rules`) are deploy records only; the app itself uses no Firebase
- A real signed-in session needs enabled Auth providers and deployed Firestore rules
- Acoustic quality should be checked on the physical phone at the intended speaker volume

## Provider Smoke Checks (require real config)

- `dart run tool/smoke_gemini_live.dart config.local.json` — needs `GEMINI_API_KEY`; never prints the key in output
- `dart run tool/smoke_realtime_transcription.dart config.local.json <16khz-mono-pcm16>` — streams a 16 kHz mono PCM16 sample through Live; requires both input and output transcription events
- `dart run tool/smoke_ollama_translate.dart config.local.json` — needs Ollama `eb-translator`; prints the translation, never any key