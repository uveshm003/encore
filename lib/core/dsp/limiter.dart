import 'dart:math' as math;
import 'dart:typed_data';

/// Look-ahead peak limiter on the master bus (MIX-04).
///
/// The delay line holds [lookaheadFrames] of audio so the gain can be pulled
/// down *before* a transient arrives rather than clipping it and then reacting.
/// Gain reduction is smoothed with a fast attack and a slow release so the
/// limiter does not audibly pump on sustained loud passages.
class Limiter {
  Limiter({
    required this.sampleRate,
    required this.channelCount,
    this.thresholdLinear = 0.98,
    double lookaheadMs = 5.0,
    double releaseMs = 120.0,
  })  : lookaheadFrames = math.max(1, (sampleRate * lookaheadMs / 1000).round()),
        _releaseCoefficient =
            math.exp(-1.0 / (sampleRate * (releaseMs / 1000))) {
    _delay = List<Float32List>.generate(
      channelCount,
      (_) => Float32List(lookaheadFrames),
      growable: false,
    );
    _envelope = Float32List(lookaheadFrames);
  }

  final int sampleRate;
  final int channelCount;
  final double thresholdLinear;
  final int lookaheadFrames;

  final double _releaseCoefficient;
  late final List<Float32List> _delay;
  late final Float32List _envelope;
  int _writeIndex = 0;
  double _gain = 1.0;

  /// Total latency the limiter adds, in frames. Callers that need
  /// sample-accurate alignment (offline export) compensate for this.
  int get latencyFrames => lookaheadFrames;

  void reset() {
    for (final channel in _delay) {
      channel.fillRange(0, channel.length, 0);
    }
    _envelope.fillRange(0, _envelope.length, 0);
    _writeIndex = 0;
    _gain = 1.0;
  }

  /// Limits [channels] in place. Every channel must have the same length.
  void process(List<Float32List> channels) {
    if (channels.length != channelCount) {
      throw ArgumentError('expected $channelCount channels');
    }
    final frames = channels.first.length;
    for (var frame = 0; frame < frames; frame++) {
      var peak = 0.0;
      for (var ch = 0; ch < channelCount; ch++) {
        final magnitude = channels[ch][frame].abs();
        if (magnitude > peak) peak = magnitude;
      }

      // Read the sample that is leaving the look-ahead window, then overwrite
      // that slot with the incoming one.
      final readIndex = _writeIndex;
      final delayed = List<double>.filled(channelCount, 0.0);
      for (var ch = 0; ch < channelCount; ch++) {
        delayed[ch] = _delay[ch][readIndex];
        _delay[ch][readIndex] = channels[ch][frame];
      }
      _envelope[readIndex] = peak;
      _writeIndex = (_writeIndex + 1) % lookaheadFrames;

      // The target gain is whatever keeps the loudest sample still inside the
      // look-ahead window under the threshold.
      var windowPeak = 0.0;
      for (var i = 0; i < lookaheadFrames; i++) {
        if (_envelope[i] > windowPeak) windowPeak = _envelope[i];
      }
      final targetGain =
          windowPeak > thresholdLinear ? thresholdLinear / windowPeak : 1.0;
      if (targetGain < _gain) {
        _gain = targetGain; // Attack instantly so nothing gets through.
      } else {
        _gain = targetGain + (_gain - targetGain) * _releaseCoefficient;
      }

      for (var ch = 0; ch < channelCount; ch++) {
        channels[ch][frame] = delayed[ch] * _gain;
      }
    }
  }
}
