import 'dart:math' as math;
import 'dart:typed_data';

/// Filter shapes supported by [Biquad].
enum BiquadType { lowPass, highPass, bandPass, lowShelf, highShelf, peaking, notch }

/// A direct-form-I biquad, the building block for the EQ and for the
/// band-splitting used by 4-stem separation.
///
/// One instance carries the state for a single channel; use [reset] between
/// discontinuous blocks and one instance per channel for stereo.
class Biquad {
  Biquad({
    required BiquadType type,
    required double frequency,
    required int sampleRate,
    double q = 0.7071067811865476,
    double gainDb = 0.0,
  }) {
    setCoefficients(
      type: type,
      frequency: frequency,
      sampleRate: sampleRate,
      q: q,
      gainDb: gainDb,
    );
  }

  double _b0 = 1, _b1 = 0, _b2 = 0, _a1 = 0, _a2 = 0;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  void setCoefficients({
    required BiquadType type,
    required double frequency,
    required int sampleRate,
    double q = 0.7071067811865476,
    double gainDb = 0.0,
  }) {
    // Keep the corner strictly inside the Nyquist band; a cutoff at or above
    // Nyquist makes the bilinear transform blow up.
    final nyquist = sampleRate / 2;
    final f = frequency.clamp(1.0, nyquist * 0.99);
    final safeQ = q <= 0 ? 0.0001 : q;
    final omega = 2 * math.pi * f / sampleRate;
    final sin = math.sin(omega);
    final cos = math.cos(omega);
    final alpha = sin / (2 * safeQ);
    final a = math.pow(10, gainDb / 40).toDouble();

    double b0, b1, b2, a0, a1, a2;
    switch (type) {
      case BiquadType.lowPass:
        b0 = (1 - cos) / 2;
        b1 = 1 - cos;
        b2 = (1 - cos) / 2;
        a0 = 1 + alpha;
        a1 = -2 * cos;
        a2 = 1 - alpha;
      case BiquadType.highPass:
        b0 = (1 + cos) / 2;
        b1 = -(1 + cos);
        b2 = (1 + cos) / 2;
        a0 = 1 + alpha;
        a1 = -2 * cos;
        a2 = 1 - alpha;
      case BiquadType.bandPass:
        b0 = alpha;
        b1 = 0;
        b2 = -alpha;
        a0 = 1 + alpha;
        a1 = -2 * cos;
        a2 = 1 - alpha;
      case BiquadType.notch:
        b0 = 1;
        b1 = -2 * cos;
        b2 = 1;
        a0 = 1 + alpha;
        a1 = -2 * cos;
        a2 = 1 - alpha;
      case BiquadType.peaking:
        b0 = 1 + alpha * a;
        b1 = -2 * cos;
        b2 = 1 - alpha * a;
        a0 = 1 + alpha / a;
        a1 = -2 * cos;
        a2 = 1 - alpha / a;
      case BiquadType.lowShelf:
        final sqrtA = 2 * math.sqrt(a) * alpha;
        b0 = a * ((a + 1) - (a - 1) * cos + sqrtA);
        b1 = 2 * a * ((a - 1) - (a + 1) * cos);
        b2 = a * ((a + 1) - (a - 1) * cos - sqrtA);
        a0 = (a + 1) + (a - 1) * cos + sqrtA;
        a1 = -2 * ((a - 1) + (a + 1) * cos);
        a2 = (a + 1) + (a - 1) * cos - sqrtA;
      case BiquadType.highShelf:
        final sqrtA = 2 * math.sqrt(a) * alpha;
        b0 = a * ((a + 1) + (a - 1) * cos + sqrtA);
        b1 = -2 * a * ((a - 1) + (a + 1) * cos);
        b2 = a * ((a + 1) + (a - 1) * cos - sqrtA);
        a0 = (a + 1) - (a - 1) * cos + sqrtA;
        a1 = 2 * ((a - 1) - (a + 1) * cos);
        a2 = (a + 1) - (a - 1) * cos - sqrtA;
    }
    _b0 = b0 / a0;
    _b1 = b1 / a0;
    _b2 = b2 / a0;
    _a1 = a1 / a0;
    _a2 = a2 / a0;
  }

  /// Clears the delay line.
  void reset() {
    _x1 = _x2 = _y1 = _y2 = 0;
  }

  double processSample(double input) {
    final output =
        _b0 * input + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
    _x2 = _x1;
    _x1 = input;
    _y2 = _y1;
    _y1 = output;
    return output;
  }

  /// Filters [samples] in place.
  void processInPlace(Float32List samples) {
    for (var i = 0; i < samples.length; i++) {
      samples[i] = processSample(samples[i]);
    }
  }
}
