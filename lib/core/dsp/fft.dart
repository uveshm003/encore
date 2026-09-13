import 'dart:math' as math;
import 'dart:typed_data';

/// In-place iterative radix-2 complex FFT.
///
/// Kept dependency-free and free of any Flutter import so it can run inside a
/// background isolate (which is where separation and offline rendering live).
class Fft {
  Fft(this.size)
    : assert(size > 1 && (size & (size - 1)) == 0, 'size must be a power of two'),
      _cos = Float64List(size ~/ 2),
      _sin = Float64List(size ~/ 2),
      _reversed = Uint32List(size) {
    for (var i = 0; i < size ~/ 2; i++) {
      final angle = -2 * math.pi * i / size;
      _cos[i] = math.cos(angle);
      _sin[i] = math.sin(angle);
    }
    final bits = size.bitLength - 1;
    for (var i = 0; i < size; i++) {
      var reversed = 0;
      for (var bit = 0; bit < bits; bit++) {
        reversed = (reversed << 1) | ((i >> bit) & 1);
      }
      _reversed[i] = reversed;
    }
  }

  final int size;
  final Float64List _cos;
  final Float64List _sin;
  final Uint32List _reversed;

  /// Forward transform. [re] and [im] are modified in place.
  void forward(Float64List re, Float64List im) => _transform(re, im, false);

  /// Inverse transform, scaled by 1/N so `inverse(forward(x)) == x`.
  void inverse(Float64List re, Float64List im) {
    _transform(re, im, true);
    final scale = 1.0 / size;
    for (var i = 0; i < size; i++) {
      re[i] *= scale;
      im[i] *= scale;
    }
  }

  void _transform(Float64List re, Float64List im, bool conjugate) {
    if (re.length != size || im.length != size) {
      throw ArgumentError('input length must equal the FFT size ($size)');
    }
    for (var i = 0; i < size; i++) {
      final j = _reversed[i];
      if (j > i) {
        final tmpRe = re[i];
        re[i] = re[j];
        re[j] = tmpRe;
        final tmpIm = im[i];
        im[i] = im[j];
        im[j] = tmpIm;
      }
    }
    final sign = conjugate ? -1.0 : 1.0;
    for (var span = 2; span <= size; span <<= 1) {
      final half = span >> 1;
      final step = size ~/ span;
      for (var start = 0; start < size; start += span) {
        var twiddle = 0;
        for (var offset = start; offset < start + half; offset++) {
          final wRe = _cos[twiddle];
          final wIm = _sin[twiddle] * sign;
          twiddle += step;
          final pair = offset + half;
          final pairRe = re[pair] * wRe - im[pair] * wIm;
          final pairIm = re[pair] * wIm + im[pair] * wRe;
          re[pair] = re[offset] - pairRe;
          im[pair] = im[offset] - pairIm;
          re[offset] += pairRe;
          im[offset] += pairIm;
        }
      }
    }
  }
}
