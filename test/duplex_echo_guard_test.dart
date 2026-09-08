import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dual_translate/services/duplex_echo_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DuplexEchoGuard', () {
    final epoch = DateTime.utc(2026, 1, 1, 12);

    test('passes microphone frames when the speaker is idle', () {
      final guard = DuplexEchoGuard();
      final microphone = _tone(16000, 40, 320, amplitude: 0.35);

      final decision = guard.filterMicrophone(microphone, at: epoch);

      expect(decision.playbackActive, isFalse);
      expect(decision.shouldTransmit, isTrue);
      expect(decision.echoDetected, isFalse);
    });

    test('suppresses microphone audio correlated with speaker PCM', () {
      final guard = DuplexEchoGuard();
      guard.registerPlayback(
        _tone(24000, 280, 700, amplitude: 0.5),
        24000,
        at: epoch,
      );

      final decision = guard.filterMicrophone(
        _tone(16000, 40, 700, amplitude: 0.18),
        at: epoch.add(const Duration(milliseconds: 80)),
      );

      expect(decision.playbackActive, isTrue);
      expect(decision.echoDetected, isTrue);
      expect(decision.echoCorrelation, greaterThan(0.75));
      expect(decision.shouldTransmit, isFalse);
      expect(guard.suppressedFrames, 1);
    });

    test('requires sustained independent speech before barge-in', () {
      final guard = DuplexEchoGuard();
      guard.registerPlayback(
        _tone(24000, 500, 900, amplitude: 0.45),
        24000,
        at: epoch,
      );
      final person = _tone(16000, 40, 260, amplitude: 0.65);

      final first = guard.filterMicrophone(
        person,
        at: epoch.add(const Duration(milliseconds: 80)),
      );
      final second = guard.filterMicrophone(
        person,
        at: epoch.add(const Duration(milliseconds: 120)),
      );

      expect(first.shouldTransmit, isFalse);
      expect(second.shouldTransmit, isTrue);
      expect(second.bargeIn, isTrue);
      expect(second.echoCorrelation, lessThan(0.20));
      expect(guard.bargeInFrames, 1);
    });

    test('clearing playback immediately reopens normal microphone input', () {
      final guard = DuplexEchoGuard();
      final speaker = _tone(24000, 240, 760, amplitude: 0.5);
      final microphone = _tone(16000, 40, 760, amplitude: 0.2);
      guard.registerPlayback(speaker, 24000, at: epoch);
      expect(
        guard
            .filterMicrophone(
              microphone,
              at: epoch.add(const Duration(milliseconds: 80)),
            )
            .shouldTransmit,
        isFalse,
      );

      guard.clearPlayback();
      final reopened = guard.filterMicrophone(
        microphone,
        at: epoch.add(const Duration(milliseconds: 100)),
      );

      expect(reopened.playbackActive, isFalse);
      expect(reopened.shouldTransmit, isTrue);
    });

    test('reports separation counters without exposing audio', () {
      final guard = DuplexEchoGuard();
      guard.registerPlayback(
        _tone(24000, 200, 600, amplitude: 0.5),
        24000,
        at: epoch,
      );
      guard.filterMicrophone(
        _tone(16000, 40, 600, amplitude: 0.15),
        at: epoch.add(const Duration(milliseconds: 80)),
      );

      final diagnostics = guard.diagnostics(
        epoch.add(const Duration(milliseconds: 80)),
      );
      expect(diagnostics['softwareEchoGuardEnabled'], isTrue);
      expect(diagnostics['speakerReferenceActive'], isTrue);
      expect(diagnostics['suppressedMicrophoneFrames'], 1);
      expect(diagnostics.containsKey('audio'), isFalse);
    });
  });
}

Uint8List _tone(
  int sampleRate,
  int milliseconds,
  double frequency, {
  required double amplitude,
}) {
  final sampleCount = sampleRate * milliseconds ~/ 1000;
  final output = Uint8List(sampleCount * 2);
  final data = ByteData.sublistView(output);
  for (var index = 0; index < sampleCount; index++) {
    final sample =
        (math.sin(2 * math.pi * frequency * index / sampleRate) *
                amplitude *
                32767)
            .round()
            .clamp(-32768, 32767);
    data.setInt16(index * 2, sample, Endian.little);
  }
  return output;
}
