import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dual_translate/services/live_audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native duplex voice path activates echo separation', (
    tester,
  ) async {
    final audio = LiveAudioService();
    final frames = <AudioInputFrame>[];
    final subscription = audio.frames.listen(frames.add);

    try {
      await audio.startInput().timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            throw TimeoutException('Native capture did not start.'),
      );
      await audio.prepareOutput().timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            throw TimeoutException('Native playback did not start.'),
      );

      final initialState = await audio.processingState().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Audio diagnostics timed out.'),
      );
      expect(initialState['duplexEngine'], isTrue);
      expect(initialState['separateInputTransport'], isTrue);
      expect(initialState['captureActive'], isTrue);
      expect(initialState['playbackPrepared'], isTrue);
      expect(initialState['softwareEchoGuardEnabled'], isTrue);
      if (Platform.isAndroid) {
        expect(initialState['audioModeInCommunication'], isTrue);
        expect(initialState['hardwareEchoCancellationActive'], isA<bool>());
        expect(initialState['playbackSharesCaptureSession'], isTrue);
      }
      if (Platform.isIOS) {
        expect(initialState['voiceProcessingEnabled'], isTrue);
        expect(initialState['outputVoiceProcessingEnabled'], isTrue);
      }

      await audio
          .playPcmChunk(_tone(24000, 480, 680), 24000)
          .timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 650));

      expect(frames, isNotEmpty);
      expect(frames.any((frame) => frame.echoSuppressed), isTrue);
      final playbackState = await audio.processingState();
      expect(
        playbackState['suppressedMicrophoneFrames'] as int,
        greaterThan(0),
      );
    } finally {
      await audio.stopOutput().timeout(const Duration(seconds: 5));
      await audio.stopInput().timeout(const Duration(seconds: 5));
      await subscription.cancel();
      await audio.dispose().timeout(const Duration(seconds: 5));
    }
  });
}

Uint8List _tone(int sampleRate, int milliseconds, double frequency) {
  final sampleCount = sampleRate * milliseconds ~/ 1000;
  final output = Uint8List(sampleCount * 2);
  final data = ByteData.sublistView(output);
  for (var index = 0; index < sampleCount; index++) {
    final sample =
        (math.sin(2 * math.pi * frequency * index / sampleRate) * 0.12 * 32767)
            .round();
    data.setInt16(index * 2, sample, Endian.little);
  }
  return output;
}
