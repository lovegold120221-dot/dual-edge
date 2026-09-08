import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dual_translate/services/duplex_echo_guard.dart';
import 'package:dual_translate/services/live_audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _wavBytes({
  required List<int> samples,
  int sampleRate = 24000,
  int channels = 1,
  int format = 1,
  int bits = 16,
}) {
  final data = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(data);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i].clamp(-32768, 32767), Endian.little);
  }
  final header = Uint8List(44);
  final hv = ByteData.sublistView(header);
  header.setRange(0, 4, [0x52, 0x49, 0x46, 0x46]); // RIFF
  hv.setUint32(4, 36 + data.length, Endian.little);
  header.setRange(8, 12, [0x57, 0x41, 0x56, 0x45]); // WAVE
  header.setRange(12, 16, [0x66, 0x6D, 0x74, 0x20]); // fmt
  hv.setUint32(16, 16, Endian.little);
  hv.setUint16(20, format, Endian.little);
  hv.setUint16(22, channels, Endian.little);
  hv.setUint32(24, sampleRate, Endian.little);
  hv.setUint32(28, sampleRate * channels * (bits ~/ 8), Endian.little);
  hv.setUint16(32, channels * (bits ~/ 8), Endian.little);
  hv.setUint16(34, bits, Endian.little);
  header.setRange(36, 40, [0x64, 0x61, 0x74, 0x61]); // data
  hv.setUint32(40, data.length, Endian.little);
  return Uint8List.fromList([...header, ...data]);
}

List<int> _toneSamples(int sampleRate, int ms, double freq) {
  final count = sampleRate * ms ~/ 1000;
  return List<int>.generate(
    count,
    (i) => (math.sin(2 * math.pi * freq * i / sampleRate) * 20000).round(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('WavPcm16.parse', () {
    test('parses mono pcm16 with sample rate', () {
      final parsed = WavPcm16.parse(
        _wavBytes(samples: _toneSamples(24000, 100, 440), sampleRate: 24000),
      );
      expect(parsed, isNotNull);
      expect(parsed!.sampleRate, 24000);
      expect(parsed.pcm.length, 24000 ~/ 10 * 2);
    });

    test('rejects float, garbage, and truncated input', () {
      expect(
        WavPcm16.parse(_wavBytes(samples: [0, 0], format: 3, bits: 32)),
        isNull,
      );
      expect(WavPcm16.parse(Uint8List.fromList([1, 2, 3])), isNull);
      expect(
        WavPcm16.parse(Uint8List.fromList(List<int>.filled(100, 0))),
        isNull,
      );
    });

    test('downmixes stereo to mono', () {
      final left = _toneSamples(16000, 50, 440);
      final right = List<int>.filled(left.length, 0);
      final interleaved = <int>[];
      for (var i = 0; i < left.length; i++) {
        interleaved.addAll([left[i], right[i]]);
      }
      // Build stereo manually: reuse helper pieces.
      final data = Uint8List(interleaved.length * 2);
      final view = ByteData.sublistView(data);
      for (var i = 0; i < interleaved.length; i++) {
        view.setInt16(
          i * 2,
          interleaved[i].clamp(-32768, 32767),
          Endian.little,
        );
      }
      final header = Uint8List(44);
      final hv = ByteData.sublistView(header);
      header.setRange(0, 4, [0x52, 0x49, 0x46, 0x46]);
      hv.setUint32(4, 36 + data.length, Endian.little);
      header.setRange(8, 12, [0x57, 0x41, 0x56, 0x45]);
      header.setRange(12, 16, [0x66, 0x6D, 0x74, 0x20]);
      hv.setUint32(16, 16, Endian.little);
      hv.setUint16(20, 1, Endian.little);
      hv.setUint16(22, 2, Endian.little);
      hv.setUint32(24, 16000, Endian.little);
      hv.setUint32(28, 16000 * 2 * 2, Endian.little);
      hv.setUint16(32, 4, Endian.little);
      hv.setUint16(34, 16, Endian.little);
      header.setRange(36, 40, [0x64, 0x61, 0x74, 0x61]);
      hv.setUint32(40, data.length, Endian.little);
      final parsed = WavPcm16.parse(Uint8List.fromList([...header, ...data]));
      expect(parsed, isNotNull);
      expect(parsed!.pcm.length, left.length * 2);
    });
  });

  group('speaker echo never re-enters the mic', () {
    test('registered TTS playback suppresses its own capture', () {
      // Simulate the registerTtsPlayback path: parse a TTS WAV at 24 kHz,
      // register it, then the mic captures the same tone at 16 kHz.
      final wav = _wavBytes(samples: _toneSamples(24000, 500, 700));
      final parsed = WavPcm16.parse(wav)!;
      final guard = DuplexEchoGuard();
      final epoch = DateTime.utc(2026, 1, 1, 12);
      guard.registerPlayback(parsed.pcm, parsed.sampleRate, at: epoch);
      final decision = guard.filterMicrophone(
        _toneSamplesToPcm(_toneSamples(16000, 40, 700)),
        at: epoch.add(const Duration(milliseconds: 80)),
      );
      expect(decision.playbackActive, isTrue);
      expect(decision.shouldTransmit, isFalse);
      expect(guard.suppressedFrames, 1);
    });

    test('independent speech still barges in during playback', () {
      final guard = DuplexEchoGuard();
      final epoch = DateTime.utc(2026, 1, 1, 12);
      final wav = _wavBytes(samples: _toneSamples(24000, 2000, 700));
      final parsed = WavPcm16.parse(wav)!;
      guard.registerPlayback(parsed.pcm, parsed.sampleRate, at: epoch);
      // Loud unrelated tone (user talking over the speaker).
      var transmitted = 0;
      for (var i = 0; i < 14; i++) {
        final decision = guard.filterMicrophone(
          _toneSamplesToPcm(_toneSamples(16000, 40, 260)),
          at: epoch.add(Duration(milliseconds: 80 + i * 40)),
        );
        if (decision.shouldTransmit) transmitted++;
      }
      expect(transmitted, greaterThan(0));
    });
  });
}

Uint8List _toneSamplesToPcm(List<int> samples) {
  final bytes = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i].clamp(-32768, 32767), Endian.little);
  }
  return bytes;
}
