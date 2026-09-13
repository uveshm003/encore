import 'dart:math' as math;
import 'dart:typed_data';

/// Analysis/synthesis window functions used by the STFT.
class Window {
  const Window._();

  /// Periodic Hann window — the right variant for overlap-add resynthesis.
  static Float64List hann(int size) {
    final window = Float64List(size);
    for (var i = 0; i < size; i++) {
      window[i] = 0.5 * (1 - math.cos(2 * math.pi * i / size));
    }
    return window;
  }

  /// Periodic Hamming window.
  static Float64List hamming(int size) {
    final window = Float64List(size);
    for (var i = 0; i < size; i++) {
      window[i] = 0.54 - 0.46 * math.cos(2 * math.pi * i / size);
    }
    return window;
  }
}
