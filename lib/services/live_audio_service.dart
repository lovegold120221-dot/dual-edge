import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'duplex_echo_guard.dart';

class AudioInputFrame {
  const AudioInputFrame({
    required this.bytes,
    required this.level,
    this.shouldTransmit = true,
    this.echoSuppressed = false,
  });

  final Uint8List bytes;
  final double level;
  final bool shouldTransmit;
  final bool echoSuppressed;
}

/// PCM16 mono payload extracted from a WAV file.
class WavPcm16 {
  const WavPcm16({required this.pcm, required this.sampleRate});

  final Uint8List pcm;
  final int sampleRate;

  /// Parse 16-bit PCM WAV bytes (mono or multi-channel, downmixed).
  /// Returns null for anything else (float, compressed, malformed).
  static WavPcm16? parse(List<int> bytes) {
    if (bytes.length < 44) return null;
    if (bytes[0] != 0x52 ||
        bytes[1] != 0x49 ||
        bytes[2] != 0x46 ||
        bytes[3] != 0x46) {
      return null; // RIFF
    }
    if (bytes[8] != 0x57 ||
        bytes[9] != 0x41 ||
        bytes[10] != 0x56 ||
        bytes[11] != 0x45) {
      return null; // WAVE
    }
    int readU16(int offset) => bytes[offset] | (bytes[offset + 1] << 8);
    int readU32(int offset) =>
        bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
    var offset = 12;
    var audioFormat = -1;
    var channels = 0;
    var sampleRate = 0;
    var bitsPerSample = 0;
    var dataStart = -1;
    var dataLength = 0;
    while (offset + 8 <= bytes.length) {
      final tag = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = readU32(offset + 4);
      if (tag == 'fmt ' && size >= 16 && offset + 24 <= bytes.length) {
        audioFormat = readU16(offset + 8);
        channels = readU16(offset + 10);
        sampleRate = readU32(offset + 12);
        bitsPerSample = readU16(offset + 22);
      } else if (tag == 'data') {
        dataStart = offset + 8;
        dataLength = math.min(size, bytes.length - dataStart);
        break;
      }
      offset += 8 + size + (size.isOdd ? 1 : 0);
    }
    if (audioFormat != 1 ||
        bitsPerSample != 16 ||
        channels <= 0 ||
        sampleRate <= 0 ||
        dataStart < 0 ||
        dataLength < 2) {
      return null;
    }
    final frameCount = dataLength ~/ (2 * channels);
    if (frameCount == 0) return null;
    final pcm = Uint8List(frameCount * 2);
    final view = ByteData.sublistView(pcm);
    for (var i = 0; i < frameCount; i++) {
      var sum = 0;
      for (var c = 0; c < channels; c++) {
        final at = dataStart + (i * channels + c) * 2;
        var sample = bytes[at] | (bytes[at + 1] << 8);
        if (sample > 32767) sample -= 65536;
        sum += sample;
      }
      view.setInt16(i * 2, (sum / channels).round(), Endian.little);
    }
    return WavPcm16(pcm: pcm, sampleRate: sampleRate);
  }
}

class LiveAudioService {
  static const inputSampleRate = 16000;
  static const outputSampleRate = 24000;
  static const inputFrameBytes = inputSampleRate * 2 * 40 ~/ 1000;
  static const _channel = MethodChannel('ai.eburon.translator/live_pcm_v1');
  static const _inputChannel = EventChannel(
    'ai.eburon.translator/live_pcm_input_v1',
  );

  LiveAudioService({DuplexEchoGuard? echoGuard})
    : _echoGuard = echoGuard ?? DuplexEchoGuard();

  final AudioRecorder _permissionRecorder = AudioRecorder();
  final AudioRecorder _fallbackRecorder = AudioRecorder();
  final DuplexEchoGuard _echoGuard;
  final StreamController<AudioInputFrame> _frames =
      StreamController<AudioInputFrame>.broadcast();
  final List<int> _pendingInput = <int>[];
  StreamSubscription<dynamic>? _nativeInputSubscription;
  StreamSubscription<Uint8List>? _fallbackInputSubscription;
  bool _recording = false;
  bool _usingFallbackCapture = false;
  bool _hardwareEchoCancellationActive = false;

  Stream<AudioInputFrame> get frames => _frames.stream;
  bool get isRecording => _recording;

  static bool get _isDesktopFallbackPlatform {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  Future<void> startInput() async {
    if (_recording) return;
    if (!await _permissionRecorder.hasPermission()) {
      throw StateError(
        'Microphone permission was denied. Enable it in system settings.',
      );
    }
    _pendingInput.clear();
    _echoGuard.reset();
    _recording = true;
    _usingFallbackCapture = false;
    _hardwareEchoCancellationActive = false;

    // macOS/desktop: never touch native EventChannel (no plugin → spam).
    if (_isDesktopFallbackPlatform) {
      try {
        await _startFallbackCapture();
        return;
      } on Object {
        _recording = false;
        _usingFallbackCapture = false;
        _hardwareEchoCancellationActive = false;
        rethrow;
      }
    }

    try {
      await _startNativeCapture();
    } on Object catch (error) {
      await _stopNativeCaptureQuietly();
      if (_shouldUseDesktopFallback(error)) {
        try {
          await _startFallbackCapture();
          return;
        } on Object {
          _recording = false;
          _usingFallbackCapture = false;
          _hardwareEchoCancellationActive = false;
          rethrow;
        }
      }
      _recording = false;
      _usingFallbackCapture = false;
      _hardwareEchoCancellationActive = false;
      rethrow;
    }
  }

  Future<void> _startNativeCapture() async {
    // Invoke method channel first so MissingPlugin fails before EventChannel listen.
    await _channel.invokeMethod<void>('startCapture', <String, int>{
      'sampleRate': inputSampleRate,
    });
    _nativeInputSubscription = _inputChannel.receiveBroadcastStream().listen(
      _handleNativeInput,
      onError: (Object error, StackTrace stack) {
        if (error is MissingPluginException) return;
        if (!_frames.isClosed) _frames.addError(error, stack);
      },
    );
    final state = await _nativeProcessingState();
    final hardwareEchoCancellationActive =
        state['voiceProcessingEnabled'] == true ||
        state['acousticEchoCancelerEnabled'] == true;
    final separatedDuplexTransport =
        state['duplexEngine'] == true &&
        state['separateInputTransport'] == true &&
        state['softwareEchoGuardEnabled'] == true;
    if (!separatedDuplexTransport) {
      throw StateError(
        'The protected duplex audio layer is unavailable. Microphone capture '
        'was stopped to prevent speaker audio from entering the input stream.',
      );
    }
    _hardwareEchoCancellationActive = hardwareEchoCancellationActive;
    _usingFallbackCapture = false;
  }

  Future<void> _startFallbackCapture() async {
    _usingFallbackCapture = true;
    _hardwareEchoCancellationActive = false;
    _pendingInput.clear();

    final stream = await _fallbackRecorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: inputSampleRate,
        numChannels: 1,
      ),
    );
    _fallbackInputSubscription = stream.listen(
      _onFallbackMicrophoneData,
      onError: _frames.addError,
    );
  }

  bool _shouldUseDesktopFallback(Object error) {
    if (error is MissingPluginException) return true;
    if (error is StateError &&
        error.message.contains('protected duplex audio layer is unavailable')) {
      return true;
    }
    return false;
  }

  Future<void> _stopNativeCaptureQuietly() async {
    final sub = _nativeInputSubscription;
    _nativeInputSubscription = null;
    try {
      await sub?.cancel();
    } on Object {
      // MissingPlugin on cancel is expected when native channel absent.
    }
    try {
      await _channel.invokeMethod<void>('stopCapture');
    } on Object {
      // Best-effort cleanup while switching to fallback or aborting start.
    }
  }

  void _handleNativeInput(dynamic event) {
    if (!_recording || _usingFallbackCapture) return;
    if (event is Uint8List && event.isNotEmpty) {
      _onMicrophoneData(event, useEchoGuard: true);
    } else if (event is List<int> && event.isNotEmpty) {
      _onMicrophoneData(Uint8List.fromList(event), useEchoGuard: true);
    }
  }

  void _onFallbackMicrophoneData(Uint8List chunk) {
    if (!_recording || !_usingFallbackCapture) return;
    if (chunk.isEmpty) return;
    // Echo guard stays on: desktop TTS registers its WAV as the reference
    // so speaker output never re-enters as microphone input.
    _onMicrophoneData(chunk, useEchoGuard: true);
  }

  void _onMicrophoneData(Uint8List chunk, {required bool useEchoGuard}) {
    _pendingInput.addAll(chunk);
    while (_pendingInput.length >= inputFrameBytes) {
      final frame = Uint8List.fromList(
        _pendingInput.sublist(0, inputFrameBytes),
      );
      _pendingInput.removeRange(0, inputFrameBytes);
      if (useEchoGuard) {
        final separation = _echoGuard.filterMicrophone(frame);
        _frames.add(
          AudioInputFrame(
            bytes: frame,
            level: separation.shouldTransmit ? normalizedPcm16Level(frame) : 0,
            shouldTransmit: separation.shouldTransmit,
            echoSuppressed: !separation.shouldTransmit,
          ),
        );
      } else {
        _frames.add(
          AudioInputFrame(
            bytes: frame,
            level: normalizedPcm16Level(frame),
            shouldTransmit: true,
            echoSuppressed: false,
          ),
        );
      }
    }
  }

  static double normalizedPcm16Level(Uint8List pcmData) {
    final sampleCount = pcmData.length ~/ 2;
    if (sampleCount == 0) return 0;
    final samples = ByteData.sublistView(pcmData);
    var sumSquares = 0.0;
    for (var index = 0; index < sampleCount; index++) {
      final sample = samples.getInt16(index * 2, Endian.little) / 32768.0;
      sumSquares += sample * sample;
    }
    final rms = math.sqrt(sumSquares / sampleCount);
    if (rms <= 0.000001) return 0;
    final decibels = 20 * (math.log(rms) / math.ln10);
    return ((decibels + 60) / 54).clamp(0.0, 1.0);
  }

  Future<void> stopInput() async {
    _recording = false;
    _hardwareEchoCancellationActive = false;
    _pendingInput.clear();

    if (_usingFallbackCapture) {
      await _fallbackInputSubscription?.cancel();
      _fallbackInputSubscription = null;
      try {
        await _fallbackRecorder.stop();
      } on Object {
        // Recorder may already be stopped.
      }
      _usingFallbackCapture = false;
      return;
    }

    await _stopNativeCaptureQuietly();
  }

  Future<void> prepareOutput([int sampleRate = outputSampleRate]) async {
    if (_isDesktopFallbackPlatform) return;
    try {
      await _channel.invokeMethod<void>('prepare', <String, int>{
        'sampleRate': sampleRate,
      });
    } on MissingPluginException {
      // Desktop fallback / tests: TTS uses local Kokoro HTTP TTS, not PCM playback.
    }
  }

  /// Register locally synthesized TTS audio as an echo reference so the
  /// microphone never re-captures speaker output as user input.
  /// Works on every platform (including desktop afplay playback).
  void registerTtsPlayback(List<int> wavBytes) {
    try {
      final parsed = WavPcm16.parse(wavBytes);
      if (parsed == null) return;
      _echoGuard.registerPlayback(parsed.pcm, parsed.sampleRate);
    } catch (_) {}
  }

  Future<void> playPcmChunk(Uint8List bytes, int sampleRate) async {
    if (bytes.isEmpty) return;
    _echoGuard.registerPlayback(bytes, sampleRate);
    if (_isDesktopFallbackPlatform) return;
    try {
      await _channel.invokeMethod<void>('write', <String, Object>{
        'data': bytes,
        'sampleRate': sampleRate,
      });
    } on MissingPluginException {
      // Soft no-op when native write is unavailable.
    }
  }

  Future<void> stopOutput() async {
    _echoGuard.clearPlayback();
    if (_isDesktopFallbackPlatform) return;
    try {
      await _channel.invokeMethod<void>(_recording ? 'stopPlayback' : 'stop');
    } on MissingPluginException {
      // Unit tests do not register the native audio channel.
    }
  }

  Future<Map<String, Object?>> _nativeProcessingState() async {
    final state = await _channel.invokeMapMethod<String, Object?>(
      'getProcessingState',
    );
    return <String, Object?>{...?state};
  }

  Future<Map<String, Object?>> processingState() async {
    if (_usingFallbackCapture || _isDesktopFallbackPlatform) {
      return <String, Object?>{
        'duplexEngine': false,
        'separateInputTransport': false,
        'softwareEchoGuardEnabled': false,
        'voiceProcessingEnabled': false,
        'acousticEchoCancelerEnabled': false,
        'capturePath': 'record-pcm16-fallback',
        'desktopFallbackCapture': true,
        'separationLayer': 'desktop-record-fallback',
        'hardwareEchoCancellationActive': false,
        ..._echoGuard.diagnostics(),
      };
    }

    try {
      final state = await _nativeProcessingState();
      return <String, Object?>{
        ...state,
        'separationLayer': 'platform-aec+far-end-echo-guard',
        'hardwareEchoCancellationActive': _hardwareEchoCancellationActive,
        'desktopFallbackCapture': false,
        ..._echoGuard.diagnostics(),
      };
    } on MissingPluginException {
      return <String, Object?>{
        'duplexEngine': false,
        'separateInputTransport': false,
        'softwareEchoGuardEnabled': false,
        'capturePath': 'record-pcm16-fallback',
        'desktopFallbackCapture': true,
        'separationLayer': 'desktop-record-fallback',
        'hardwareEchoCancellationActive': false,
        ..._echoGuard.diagnostics(),
      };
    }
  }

  Future<void> dispose() async {
    _recording = false;
    _hardwareEchoCancellationActive = false;
    _pendingInput.clear();
    _echoGuard.reset();
    await _fallbackInputSubscription?.cancel();
    _fallbackInputSubscription = null;
    try {
      if (_usingFallbackCapture) {
        await _fallbackRecorder.stop();
      }
    } on Object {
      // Best-effort.
    }
    _usingFallbackCapture = false;
    await _stopNativeCaptureQuietly();
    if (!_isDesktopFallbackPlatform) {
      try {
        await _channel.invokeMethod<void>('stop');
      } on MissingPluginException {
        // Unit tests do not register the native audio channel.
      }
    }
    await _frames.close();
    await _permissionRecorder.dispose();
    await _fallbackRecorder.dispose();
  }
}
