import 'dart:math' as math;
import 'dart:typed_data';

/// A de-interleaved (planar) block of 32-bit float PCM.
///
/// This is the single internal audio representation for the whole app
/// (IMP-02): every decoder produces one, every encoder consumes one, and the
/// mixing graph works exclusively in this format. Samples are nominally in
/// [-1, 1] but are deliberately not clamped — intermediate mix stages are
/// allowed to overshoot and the master limiter deals with it at the end.
class AudioBuffer {
  AudioBuffer(this.channels, this.sampleRate)
    : assert(channels.isNotEmpty, 'an AudioBuffer needs at least one channel'),
      assert(sampleRate > 0, 'sampleRate must be positive') {
    final expected = channels.first.length;
    for (final channel in channels) {
      if (channel.length != expected) {
        throw ArgumentError('all channels must have the same frame count');
      }
    }
  }

  /// Allocates a silent buffer.
  factory AudioBuffer.silence({
    required int channelCount,
    required int frameCount,
    required int sampleRate,
  }) {
    return AudioBuffer(
      List<Float32List>.generate(
        channelCount,
        (_) => Float32List(frameCount),
        growable: false,
      ),
      sampleRate,
    );
  }

  /// De-interleaves `[L, R, L, R, ...]` float samples.
  factory AudioBuffer.fromInterleavedFloat32(
    Float32List interleaved, {
    required int channelCount,
    required int sampleRate,
  }) {
    final frames = interleaved.length ~/ channelCount;
    final result = AudioBuffer.silence(
      channelCount: channelCount,
      frameCount: frames,
      sampleRate: sampleRate,
    );
    for (var frame = 0; frame < frames; frame++) {
      final base = frame * channelCount;
      for (var ch = 0; ch < channelCount; ch++) {
        result.channels[ch][frame] = interleaved[base + ch];
      }
    }
    return result;
  }

  /// De-interleaves signed 16-bit PCM, the format most capture APIs deliver.
  factory AudioBuffer.fromInterleavedInt16(
    Int16List interleaved, {
    required int channelCount,
    required int sampleRate,
  }) {
    final frames = interleaved.length ~/ channelCount;
    final result = AudioBuffer.silence(
      channelCount: channelCount,
      frameCount: frames,
      sampleRate: sampleRate,
    );
    for (var frame = 0; frame < frames; frame++) {
      final base = frame * channelCount;
      for (var ch = 0; ch < channelCount; ch++) {
        result.channels[ch][frame] = interleaved[base + ch] / 32768.0;
      }
    }
    return result;
  }

  final List<Float32List> channels;
  final int sampleRate;

  int get channelCount => channels.length;

  int get frameCount => channels.first.length;

  bool get isEmpty => frameCount == 0;

  Duration get duration => framesToDuration(frameCount, sampleRate);

  Float32List operator [](int channel) => channels[channel];

  /// Interleaves back to `[L, R, L, R, ...]`.
  Float32List toInterleavedFloat32() {
    final out = Float32List(frameCount * channelCount);
    for (var ch = 0; ch < channelCount; ch++) {
      final source = channels[ch];
      for (var frame = 0; frame < frameCount; frame++) {
        out[frame * channelCount + ch] = source[frame];
      }
    }
    return out;
  }

  /// Interleaves to signed 16-bit PCM with hard clipping at full scale.
  Int16List toInterleavedInt16() {
    final out = Int16List(frameCount * channelCount);
    for (var ch = 0; ch < channelCount; ch++) {
      final source = channels[ch];
      for (var frame = 0; frame < frameCount; frame++) {
        out[frame * channelCount + ch] = floatToInt16(source[frame]);
      }
    }
    return out;
  }

  /// Sums all channels down to one (IMP-03).
  AudioBuffer toMono() {
    if (channelCount == 1) return this;
    final mono = Float32List(frameCount);
    final scale = 1.0 / channelCount;
    for (var ch = 0; ch < channelCount; ch++) {
      final source = channels[ch];
      for (var frame = 0; frame < frameCount; frame++) {
        mono[frame] += source[frame] * scale;
      }
    }
    return AudioBuffer([mono], sampleRate);
  }

  /// Converts to exactly two channels (IMP-03).
  ///
  /// Mono is duplicated to both sides; anything wider than stereo is folded
  /// down with the surround channels split evenly between L and R.
  AudioBuffer toStereo() {
    if (channelCount == 2) return this;
    if (channelCount == 1) {
      final source = channels.first;
      return AudioBuffer(
        [Float32List.fromList(source), Float32List.fromList(source)],
        sampleRate,
      );
    }
    final left = Float32List(frameCount);
    final right = Float32List(frameCount);
    for (var ch = 0; ch < channelCount; ch++) {
      final source = channels[ch];
      // Even channels lean left, odd channels lean right; everything is
      // attenuated so a wide source does not come out louder than a stereo one.
      final toLeft = ch.isEven ? 1.0 : 0.5;
      final toRight = ch.isEven ? 0.5 : 1.0;
      final scale = 2.0 / (channelCount * 1.5);
      for (var frame = 0; frame < frameCount; frame++) {
        left[frame] += source[frame] * toLeft * scale;
        right[frame] += source[frame] * toRight * scale;
      }
    }
    return AudioBuffer([left, right], sampleRate);
  }

  /// Forces the buffer to [channelCount] channels.
  AudioBuffer withChannelCount(int count) {
    if (count == channelCount) return this;
    if (count == 1) return toMono();
    if (count == 2) return toStereo();
    throw ArgumentError('unsupported target channel count: $count');
  }

  /// A copy of `[start, start + length)`, zero-padded if it runs past the end.
  AudioBuffer slice(int start, int length) {
    final out = AudioBuffer.silence(
      channelCount: channelCount,
      frameCount: length,
      sampleRate: sampleRate,
    );
    if (length <= 0) return out;
    final from = math.max(0, start);
    final to = math.min(frameCount, start + length);
    if (to <= from) return out;
    final offset = from - start;
    for (var ch = 0; ch < channelCount; ch++) {
      out.channels[ch].setRange(offset, offset + (to - from), channels[ch], from);
    }
    return out;
  }

  AudioBuffer copy() {
    return AudioBuffer(
      [for (final channel in channels) Float32List.fromList(channel)],
      sampleRate,
    );
  }

  /// Highest absolute sample value across all channels.
  double peak() {
    var peak = 0.0;
    for (final channel in channels) {
      for (final sample in channel) {
        final magnitude = sample.abs();
        if (magnitude > peak) peak = magnitude;
      }
    }
    return peak;
  }

  /// Root-mean-square level across all channels.
  double rms() {
    if (isEmpty) return 0.0;
    var sum = 0.0;
    for (final channel in channels) {
      for (final sample in channel) {
        sum += sample * sample;
      }
    }
    return math.sqrt(sum / (frameCount * channelCount));
  }

  /// Scales every sample in place.
  void applyGain(double gain) {
    if (gain == 1.0) return;
    for (final channel in channels) {
      for (var i = 0; i < channel.length; i++) {
        channel[i] *= gain;
      }
    }
  }
}

/// Converts a frame count at [sampleRate] to wall-clock time.
Duration framesToDuration(int frames, int sampleRate) {
  return Duration(microseconds: (frames * 1000000 / sampleRate).round());
}

/// Converts wall-clock time to a frame count at [sampleRate].
int durationToFrames(Duration duration, int sampleRate) {
  return (duration.inMicroseconds * sampleRate / 1000000).round();
}

/// Clamps and quantises one float sample to signed 16-bit.
///
/// Scaling by 32768 rather than 32767 keeps this the exact inverse of the
/// read path, so a float → int16 → float round trip never loses more than
/// half a least-significant bit. Full scale is clamped rather than wrapped.
int floatToInt16(double sample) {
  if (sample.isNaN) return 0;
  final scaled = (sample * 32768.0).round();
  if (scaled > 32767) return 32767;
  if (scaled < -32768) return -32768;
  return scaled;
}

/// Linear amplitude to decibels, floored at [floorDb] so silence is finite.
double amplitudeToDb(double amplitude, {double floorDb = -120.0}) {
  if (amplitude <= 0) return floorDb;
  final db = 20 * (math.log(amplitude) / math.ln10);
  return db < floorDb ? floorDb : db;
}

/// Decibels to linear amplitude.
double dbToAmplitude(double db) => math.pow(10, db / 20).toDouble();
