import 'dart:math' as math;
import 'dart:typed_data';

class DuplexFilterDecision {
  const DuplexFilterDecision({
    required this.shouldTransmit,
    required this.playbackActive,
    required this.echoDetected,
    required this.bargeIn,
    required this.microphoneRms,
    required this.echoCorrelation,
  });

  final bool shouldTransmit;
  final bool playbackActive;
  final bool echoDetected;
  final bool bargeIn;
  final double microphoneRms;
  final double echoCorrelation;
}

/// A second line of defense behind the platform acoustic echo canceller.
///
/// Android AEC and iOS Voice Processing remove the far-end speaker signal in
/// hardware. This guard also keeps a short, resampled copy of the exact model
/// PCM sent to the speaker. During playback it suppresses low-level or strongly
/// correlated microphone frames, while allowing sustained independent speech
/// through so a person can still interrupt the model.
class DuplexEchoGuard {
  DuplexEchoGuard({
    this.inputSampleRate = 16000,
    this.frameDuration = const Duration(milliseconds: 40),
    this.playbackLead = const Duration(milliseconds: 35),
    this.echoTail = const Duration(milliseconds: 260),
  });

  final int inputSampleRate;
  final Duration frameDuration;
  final Duration playbackLead;
  final Duration echoTail;

  static const _quietRms = 0.006;
  static const _echoCorrelationThreshold = 0.28;
  static const _bargeInCorrelationCeiling = 0.20;
  static const _bargeInHold = Duration(milliseconds: 420);
  static const _referenceRetention = Duration(milliseconds: 900);
  static const _referenceLookAhead = Duration(milliseconds: 120);

  final List<_ReferenceFrame> _references = <_ReferenceFrame>[];
  DateTime? _playoutCursor;
  DateTime? _playbackActiveFrom;
  DateTime? _playbackActiveUntil;
  DateTime? _bargeInUntil;
  int _independentSpeechFrames = 0;
  double _adaptiveCoupling = 0.12;

  int suppressedFrames = 0;
  int transmittedFrames = 0;
  int bargeInFrames = 0;

  bool isPlaybackActive([DateTime? at]) {
    final now = at ?? DateTime.now();
    final from = _playbackActiveFrom;
    final until = _playbackActiveUntil;
    if (from == null || until == null) return false;
    return !now.isBefore(from.subtract(const Duration(milliseconds: 80))) &&
        !now.isAfter(until);
  }

  void registerPlayback(Uint8List pcmData, int sampleRate, {DateTime? at}) {
    if (pcmData.length < 2 || sampleRate <= 0) return;
    final now = at ?? DateTime.now();
    final source = _decodePcm16(pcmData);
    final resampled = sampleRate == inputSampleRate
        ? source
        : _resample(source, sampleRate, inputSampleRate);
    if (resampled.isEmpty) return;

    final minimumStart = now.add(playbackLead);
    var cursor = _playoutCursor ?? minimumStart;
    if (cursor.isBefore(minimumStart)) cursor = minimumStart;
    _playbackActiveFrom ??= cursor;

    final samplesPerFrame = math.max(
      1,
      inputSampleRate * frameDuration.inMicroseconds ~/ 1000000,
    );
    for (var offset = 0; offset < resampled.length; offset += samplesPerFrame) {
      final end = math.min(offset + samplesPerFrame, resampled.length);
      final samples = Int16List(samplesPerFrame);
      samples.setRange(0, end - offset, resampled, offset);
      _references.add(
        _ReferenceFrame(start: cursor, samples: samples, rms: _rms(samples)),
      );
      final actualSamples = end - offset;
      cursor = cursor.add(
        Duration(microseconds: actualSamples * 1000000 ~/ inputSampleRate),
      );
    }
    _playoutCursor = cursor;
    _playbackActiveUntil = cursor.add(echoTail);
    _pruneReferences(now);
  }

  DuplexFilterDecision filterMicrophone(Uint8List pcmData, {DateTime? at}) {
    final now = at ?? DateTime.now();
    final microphone = _decodePcm16(pcmData);
    final microphoneRms = _rms(microphone);
    final playbackActive = isPlaybackActive(now);
    _pruneReferences(now);

    if (!playbackActive || microphone.isEmpty) {
      _independentSpeechFrames = 0;
      _bargeInUntil = null;
      transmittedFrames++;
      return DuplexFilterDecision(
        shouldTransmit: true,
        playbackActive: false,
        echoDetected: false,
        bargeIn: false,
        microphoneRms: microphoneRms,
        echoCorrelation: 0,
      );
    }

    var strongestCorrelation = 0.0;
    var strongestReferenceRms = 0.0;
    for (final reference in _references) {
      final age = now.difference(reference.start);
      if (age > _referenceRetention || age < -_referenceLookAhead) continue;
      final correlation = _maximumCorrelation(microphone, reference.samples);
      if (correlation > strongestCorrelation) {
        strongestCorrelation = correlation;
        strongestReferenceRms = reference.rms;
      }
    }

    final echoDetected = strongestCorrelation >= _echoCorrelationThreshold;
    if (echoDetected && strongestReferenceRms > _quietRms) {
      final observedCoupling = (microphoneRms / strongestReferenceRms).clamp(
        0.01,
        1.5,
      );
      _adaptiveCoupling =
          (_adaptiveCoupling * 0.88) + (observedCoupling * 0.12);
    }

    final echoCeiling = math.max(
      0.025,
      strongestReferenceRms * _adaptiveCoupling * 2.4,
    );
    final independentSpeech =
        microphoneRms > math.max(0.035, echoCeiling) &&
        strongestCorrelation < _bargeInCorrelationCeiling;
    if (independentSpeech) {
      _independentSpeechFrames++;
      if (_independentSpeechFrames >= 2) {
        _bargeInUntil = now.add(_bargeInHold);
      }
    } else {
      _independentSpeechFrames = 0;
    }

    final bargeIn =
        _bargeInUntil?.isAfter(now) == true &&
        microphoneRms > _quietRms &&
        strongestCorrelation < 0.55;
    // During far-end playback, only sustained independent speech is allowed
    // through. A single non-correlated transient is withheld so speaker
    // leakage and room reflections cannot reopen the microphone by accident.
    final shouldTransmit = bargeIn;

    if (shouldTransmit) {
      transmittedFrames++;
      if (bargeIn) bargeInFrames++;
    } else {
      suppressedFrames++;
    }
    return DuplexFilterDecision(
      shouldTransmit: shouldTransmit,
      playbackActive: true,
      echoDetected: echoDetected || microphoneRms <= echoCeiling,
      bargeIn: bargeIn,
      microphoneRms: microphoneRms,
      echoCorrelation: strongestCorrelation,
    );
  }

  Map<String, Object?> diagnostics([DateTime? at]) => <String, Object?>{
    'softwareEchoGuardEnabled': true,
    'speakerReferenceActive': isPlaybackActive(at),
    'suppressedMicrophoneFrames': suppressedFrames,
    'transmittedMicrophoneFrames': transmittedFrames,
    'bargeInFrames': bargeInFrames,
    'adaptiveEchoCoupling': _adaptiveCoupling,
  };

  void clearPlayback() {
    _references.clear();
    _playoutCursor = null;
    _playbackActiveFrom = null;
    _playbackActiveUntil = null;
    _bargeInUntil = null;
    _independentSpeechFrames = 0;
  }

  void reset() {
    clearPlayback();
    suppressedFrames = 0;
    transmittedFrames = 0;
    bargeInFrames = 0;
    _adaptiveCoupling = 0.12;
  }

  void _pruneReferences(DateTime now) {
    _references.removeWhere(
      (reference) => now.difference(reference.start) > _referenceRetention,
    );
  }

  static Int16List _decodePcm16(Uint8List bytes) {
    final sampleCount = bytes.length ~/ 2;
    final samples = Int16List(sampleCount);
    final data = ByteData.sublistView(bytes);
    for (var index = 0; index < sampleCount; index++) {
      samples[index] = data.getInt16(index * 2, Endian.little);
    }
    return samples;
  }

  static Int16List _resample(Int16List source, int sourceRate, int targetRate) {
    if (source.isEmpty || sourceRate <= 0 || targetRate <= 0) {
      return Int16List(0);
    }
    final targetLength = math.max(
      1,
      (source.length * targetRate / sourceRate).round(),
    );
    final output = Int16List(targetLength);
    final ratio = sourceRate / targetRate;
    for (var index = 0; index < targetLength; index++) {
      final position = index * ratio;
      final left = position.floor().clamp(0, source.length - 1);
      final right = math.min(left + 1, source.length - 1);
      final fraction = position - left;
      output[index] =
          (source[left] + ((source[right] - source[left]) * fraction)).round();
    }
    return output;
  }

  static double _rms(Int16List samples) {
    if (samples.isEmpty) return 0;
    var sumSquares = 0.0;
    for (final sample in samples) {
      final normalized = sample / 32768.0;
      sumSquares += normalized * normalized;
    }
    return math.sqrt(sumSquares / samples.length);
  }

  static double _maximumCorrelation(Int16List input, Int16List reference) {
    if (input.length < 32 || reference.length < 32) return 0;
    var maximum = 0.0;
    for (var lag = -96; lag <= 96; lag += 16) {
      var dot = 0.0;
      var inputEnergy = 0.0;
      var referenceEnergy = 0.0;
      var samples = 0;
      for (var inputIndex = 0; inputIndex < input.length; inputIndex += 2) {
        final referenceIndex = inputIndex + lag;
        if (referenceIndex < 0 || referenceIndex >= reference.length) continue;
        final inputSample = input[inputIndex].toDouble();
        final referenceSample = reference[referenceIndex].toDouble();
        dot += inputSample * referenceSample;
        inputEnergy += inputSample * inputSample;
        referenceEnergy += referenceSample * referenceSample;
        samples++;
      }
      if (samples < 16 || inputEnergy == 0 || referenceEnergy == 0) continue;
      final correlation = dot.abs() / math.sqrt(inputEnergy * referenceEnergy);
      if (correlation > maximum) maximum = correlation;
    }
    return maximum.clamp(0.0, 1.0);
  }
}

class _ReferenceFrame {
  const _ReferenceFrame({
    required this.start,
    required this.samples,
    required this.rms,
  });

  final DateTime start;
  final Int16List samples;
  final double rms;
}
