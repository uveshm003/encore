import 'dart:math' as math;
import 'dart:typed_data';

import '../audio_buffer.dart';

/// Windowed-sinc sample-rate conversion.
///
/// Imported files keep their own sample rate as metadata (IMP-03), but the
/// mixing graph runs at one fixed rate, so anything that does not match is
/// converted once on import rather than in the playback path.
class Resampler {
  const Resampler({this.halfWidth = 24});

  /// Number of source samples used either side of each output position.
  /// Wider is cleaner and slower; 24 is transparent for music.
  final int halfWidth;

  /// Converts [buffer] to [targetSampleRate], returning it unchanged if the
  /// rate already matches.
  AudioBuffer resample(AudioBuffer buffer, int targetSampleRate) {
    if (buffer.sampleRate == targetSampleRate) return buffer;
    if (buffer.isEmpty) {
      return AudioBuffer.silence(
        channelCount: buffer.channelCount,
        frameCount: 0,
        sampleRate: targetSampleRate,
      );
    }
    final ratio = targetSampleRate / buffer.sampleRate;
    final outputFrames = math.max(1, (buffer.frameCount * ratio).floor());
    final output = AudioBuffer.silence(
      channelCount: buffer.channelCount,
      frameCount: outputFrames,
      sampleRate: targetSampleRate,
    );
    // When downsampling, the reconstruction filter has to move down to the new
    // Nyquist frequency or we alias.
    final cutoff = ratio < 1.0 ? ratio : 1.0;
    for (var ch = 0; ch < buffer.channelCount; ch++) {
      _resampleChannel(
        buffer.channels[ch],
        output.channels[ch],
        1.0 / ratio,
        cutoff,
      );
    }
    return output;
  }

  void _resampleChannel(
    Float32List source,
    Float32List destination,
    double step,
    double cutoff,
  ) {
    for (var i = 0; i < destination.length; i++) {
      final position = i * step;
      final centre = position.floor();
      var sum = 0.0;
      var weightSum = 0.0;
      for (var tap = -halfWidth + 1; tap <= halfWidth; tap++) {
        final index = centre + tap;
        if (index < 0 || index >= source.length) continue;
        final distance = position - index;
        final weight = _sinc(distance * cutoff) * cutoff * _blackman(distance);
        sum += source[index] * weight;
        weightSum += weight;
      }
      destination[i] = weightSum.abs() > 1e-9 ? sum / weightSum : 0.0;
    }
  }

  double _sinc(double x) {
    if (x.abs() < 1e-9) return 1.0;
    final piX = math.pi * x;
    return math.sin(piX) / piX;
  }

  double _blackman(double distance) {
    final normalised = distance / halfWidth;
    if (normalised.abs() >= 1.0) return 0.0;
    final phase = math.pi * (normalised + 1) / 2 * 2;
    return 0.42 - 0.5 * math.cos(phase) + 0.08 * math.cos(2 * phase);
  }
}
