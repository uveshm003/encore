import 'dart:math' as math;
import 'dart:typed_data';

import '../core/audio_buffer.dart';

/// How far recorded audio has to be shifted to land in time (REC-04).
///
/// Two delays add up between hearing the backing track and having a take on
/// disk: the output queue and the device's own buffering on the way out, and
/// the capture buffering on the way in. A take is therefore written to disk
/// later than the moment it was performed, and is moved earlier by exactly
/// this amount when it is committed to the timeline.
class LatencySettings {
  const LatencySettings({
    this.outputFrames = 0,
    this.inputFrames = 0,
    this.manualOffsetFrames = 0,
    this.isCalibrated = false,
  });

  /// Frames between rendering a sample and hearing it.
  final int outputFrames;

  /// Frames between a sound reaching the microphone and reaching the app.
  final int inputFrames;

  /// User adjustment on top of the measurement, positive to pull takes
  /// earlier.
  final int manualOffsetFrames;

  /// True once a measurement has actually been made, so the UI can prompt for
  /// calibration rather than quietly using an estimate.
  final bool isCalibrated;

  /// Total shift applied to a take, in frames.
  int get compensationFrames =>
      math.max(0, outputFrames + inputFrames + manualOffsetFrames);

  Duration roundTrip(int sampleRate) =>
      framesToDuration(outputFrames + inputFrames, sampleRate);

  LatencySettings copyWith({
    int? outputFrames,
    int? inputFrames,
    int? manualOffsetFrames,
    bool? isCalibrated,
  }) {
    return LatencySettings(
      outputFrames: outputFrames ?? this.outputFrames,
      inputFrames: inputFrames ?? this.inputFrames,
      manualOffsetFrames: manualOffsetFrames ?? this.manualOffsetFrames,
      isCalibrated: isCalibrated ?? this.isCalibrated,
    );
  }

  Map<String, Object?> toJson() => {
    'outputFrames': outputFrames,
    'inputFrames': inputFrames,
    'manualOffsetFrames': manualOffsetFrames,
    'isCalibrated': isCalibrated,
  };

  static LatencySettings fromJson(Map<String, Object?> json) {
    return LatencySettings(
      outputFrames: (json['outputFrames'] as num?)?.toInt() ?? 0,
      inputFrames: (json['inputFrames'] as num?)?.toInt() ?? 0,
      manualOffsetFrames: (json['manualOffsetFrames'] as num?)?.toInt() ?? 0,
      isCalibrated: json['isCalibrated'] as bool? ?? false,
    );
  }

  /// A starting estimate from the engine's own buffering, used until the user
  /// runs a measurement.
  static LatencySettings estimate({
    required int outputBufferFrames,
    required int sampleRate,
  }) {
    // Beyond our own queue, the device path itself typically adds a handful of
    // milliseconds in each direction. Deliberately conservative: a take that
    // is slightly late is easier to notice and fix than one pulled early.
    final devicePathFrames = (sampleRate * 0.008).round();
    return LatencySettings(
      outputFrames: outputBufferFrames + devicePathFrames,
      inputFrames: devicePathFrames,
    );
  }
}

/// Result of a round-trip measurement.
class LatencyMeasurement {
  const LatencyMeasurement({
    required this.roundTripFrames,
    required this.confidence,
    required this.sampleRate,
  });

  final int roundTripFrames;

  /// 0..1 — how clearly the test signal was found in the recording. A low
  /// value means the microphone probably could not hear the speakers.
  final double confidence;
  final int sampleRate;

  Duration get roundTrip => framesToDuration(roundTripFrames, sampleRate);

  bool get isReliable => confidence >= 0.25 && roundTripFrames > 0;
}

/// Measures the true round-trip delay by listening for a signal the app emits.
///
/// The app plays a short chirp, records through the microphone, and finds the
/// delay by cross-correlation. That measures the entire path — output queue,
/// converter, speaker, air, microphone, capture queue — instead of trusting a
/// number the platform reports, which is what makes overdubs actually line up
/// (NFR-PERF-02).
class LatencyCalibrator {
  const LatencyCalibrator({
    this.sampleRate = 48000,
    this.chirpMilliseconds = 40,
    this.searchSeconds = 1.0,
  });

  final int sampleRate;
  final int chirpMilliseconds;

  /// How far into the recording to look for the chirp.
  final double searchSeconds;

  /// The signal to play during calibration: a rising sweep, which correlates
  /// sharply and cuts through room noise better than a click.
  Float32List buildProbe() {
    final length = (sampleRate * chirpMilliseconds / 1000).round();
    final probe = Float32List(length);
    const startHz = 800.0;
    const endHz = 6000.0;
    for (var i = 0; i < length; i++) {
      final t = i / sampleRate;
      final progress = i / length;
      final frequency = startHz + (endHz - startHz) * progress;
      // Taper both ends so the sweep starts and stops without a click of its
      // own, which would blur the correlation peak.
      final window = 0.5 - 0.5 * math.cos(2 * math.pi * progress);
      probe[i] = math.sin(2 * math.pi * frequency * t) * window * 0.7;
    }
    return probe;
  }

  /// Finds [probe] inside [recorded] and reports the offset.
  ///
  /// [recordingStartFrame] is the position in the emitted signal at which the
  /// recording began, so the caller can account for a capture that started
  /// after playback did.
  LatencyMeasurement measure({
    required Float32List probe,
    required Float32List recorded,
    int recordingStartFrame = 0,
  }) {
    final maxLag = math.min(
      recorded.length - probe.length,
      (sampleRate * searchSeconds).round(),
    );
    if (maxLag <= 0 || probe.isEmpty) {
      return LatencyMeasurement(
        roundTripFrames: 0,
        confidence: 0,
        sampleRate: sampleRate,
      );
    }

    var probeEnergy = 0.0;
    for (final sample in probe) {
      probeEnergy += sample * sample;
    }
    if (probeEnergy <= 0) {
      return LatencyMeasurement(
        roundTripFrames: 0,
        confidence: 0,
        sampleRate: sampleRate,
      );
    }

    var bestLag = 0;
    var bestScore = 0.0;
    var totalScore = 0.0;
    var scored = 0;
    for (var lag = 0; lag < maxLag; lag++) {
      var correlation = 0.0;
      var energy = 0.0;
      for (var i = 0; i < probe.length; i++) {
        final sample = recorded[lag + i];
        correlation += probe[i] * sample;
        energy += sample * sample;
      }
      if (energy <= 0) continue;
      // Normalised correlation, so a loud room does not outscore a clean match.
      final score = correlation.abs() / math.sqrt(probeEnergy * energy);
      totalScore += score;
      scored++;
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
    }

    // Confidence is how far the winning lag stands above the average lag; a
    // recording of nothing but noise correlates about equally everywhere.
    final average = scored == 0 ? 0.0 : totalScore / scored;
    final confidence = bestScore <= 0
        ? 0.0
        : ((bestScore - average) / bestScore).clamp(0.0, 1.0);

    return LatencyMeasurement(
      roundTripFrames: bestLag + recordingStartFrame,
      confidence: confidence,
      sampleRate: sampleRate,
    );
  }
}
