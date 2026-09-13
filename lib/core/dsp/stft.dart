import 'dart:math' as math;
import 'dart:typed_data';

import 'fft.dart';
import 'window.dart';

/// One analysed frame: the positive-frequency half of a complex spectrum.
class SpectralFrame {
  SpectralFrame(this.re, this.im);

  factory SpectralFrame.zeros(int bins) =>
      SpectralFrame(Float64List(bins), Float64List(bins));

  final Float64List re;
  final Float64List im;

  int get binCount => re.length;

  double magnitudeAt(int bin) => math.sqrt(re[bin] * re[bin] + im[bin] * im[bin]);

  /// Multiplies bin [bin] by a real gain, preserving phase.
  void scaleBin(int bin, double gain) {
    re[bin] *= gain;
    im[bin] *= gain;
  }

  SpectralFrame copy() =>
      SpectralFrame(Float64List.fromList(re), Float64List.fromList(im));
}

/// Short-time Fourier transform with weighted overlap-add resynthesis.
///
/// This is the workhorse behind stem separation: [analyze] turns a channel of
/// PCM into frames, masks are applied per bin, and [synthesize] puts it back
/// together. The synthesis divides by the accumulated squared window so the
/// round trip is transparent (unity) even at the very start and end of the
/// signal, where fewer windows overlap.
class Stft {
  Stft({this.fftSize = 2048, this.hopSize = 512})
    : assert(fftSize > 0 && (fftSize & (fftSize - 1)) == 0,
          'fftSize must be a power of two'),
      assert(hopSize > 0 && hopSize <= fftSize, 'hopSize must be within the frame'),
      _fft = Fft(fftSize),
      _window = Window.hann(fftSize);

  final int fftSize;
  final int hopSize;
  final Fft _fft;
  final Float64List _window;

  /// Number of usable bins (DC through Nyquist).
  int get binCount => fftSize ~/ 2 + 1;

  /// Number of frames [frameCount] samples will produce.
  int frameCountFor(int sampleCount) {
    if (sampleCount <= 0) return 0;
    return (sampleCount / hopSize).ceil() + 1;
  }

  /// Splits [samples] into overlapping windowed spectra.
  ///
  /// The signal is treated as if padded with `fftSize` zeros at the front, so
  /// frame `i` covers samples `[i * hopSize - fftSize, i * hopSize)`.
  List<SpectralFrame> analyze(Float32List samples) {
    final frames = <SpectralFrame>[];
    final re = Float64List(fftSize);
    final im = Float64List(fftSize);
    final total = frameCountFor(samples.length);
    for (var frame = 0; frame < total; frame++) {
      final start = frame * hopSize - fftSize;
      for (var i = 0; i < fftSize; i++) {
        final index = start + i;
        final sample =
            (index >= 0 && index < samples.length) ? samples[index] : 0.0;
        re[i] = sample * _window[i];
        im[i] = 0.0;
      }
      _fft.forward(re, im);
      final spectrum = SpectralFrame.zeros(binCount);
      for (var bin = 0; bin < binCount; bin++) {
        spectrum.re[bin] = re[bin];
        spectrum.im[bin] = im[bin];
      }
      frames.add(spectrum);
    }
    return frames;
  }

  /// Rebuilds a signal of [outputLength] samples from [frames].
  Float32List synthesize(List<SpectralFrame> frames, int outputLength) {
    final accumulator = Float64List(outputLength);
    final normalisation = Float64List(outputLength);
    final re = Float64List(fftSize);
    final im = Float64List(fftSize);
    for (var frame = 0; frame < frames.length; frame++) {
      final spectrum = frames[frame];
      // Rebuild the full conjugate-symmetric spectrum before inverting.
      for (var bin = 0; bin < binCount; bin++) {
        re[bin] = spectrum.re[bin];
        im[bin] = spectrum.im[bin];
      }
      for (var bin = binCount; bin < fftSize; bin++) {
        final mirror = fftSize - bin;
        re[bin] = spectrum.re[mirror];
        im[bin] = -spectrum.im[mirror];
      }
      _fft.inverse(re, im);
      final start = frame * hopSize - fftSize;
      for (var i = 0; i < fftSize; i++) {
        final index = start + i;
        if (index < 0 || index >= outputLength) continue;
        final windowValue = _window[i];
        accumulator[index] += re[i] * windowValue;
        normalisation[index] += windowValue * windowValue;
      }
    }
    final output = Float32List(outputLength);
    for (var i = 0; i < outputLength; i++) {
      final weight = normalisation[i];
      // Below this threshold the sample is covered by essentially no window;
      // dividing would amplify numerical noise into a click.
      output[i] = weight > 1e-8 ? accumulator[i] / weight : 0.0;
    }
    return output;
  }

  /// Rebuilds a signal after scaling every bin by a real gain.
  ///
  /// [mask] is a flat `frames.length * binCount` array of per-bin gains. This
  /// exists so stem separation can synthesise each stem straight from the
  /// original spectra instead of copying a whole spectrogram per stem — with a
  /// four-stem split that is the difference between tens and hundreds of
  /// megabytes.
  Float32List synthesizeMasked(
    List<SpectralFrame> frames,
    int outputLength,
    Float32List mask,
  ) {
    if (mask.length < frames.length * binCount) {
      throw ArgumentError('mask must cover every frame and bin');
    }
    final accumulator = Float64List(outputLength);
    final normalisation = Float64List(outputLength);
    final re = Float64List(fftSize);
    final im = Float64List(fftSize);
    for (var frame = 0; frame < frames.length; frame++) {
      final spectrum = frames[frame];
      final maskOffset = frame * binCount;
      for (var bin = 0; bin < binCount; bin++) {
        final gain = mask[maskOffset + bin];
        re[bin] = spectrum.re[bin] * gain;
        im[bin] = spectrum.im[bin] * gain;
      }
      for (var bin = binCount; bin < fftSize; bin++) {
        final mirror = fftSize - bin;
        re[bin] = re[mirror];
        im[bin] = -im[mirror];
      }
      _fft.inverse(re, im);
      final start = frame * hopSize - fftSize;
      for (var i = 0; i < fftSize; i++) {
        final index = start + i;
        if (index < 0 || index >= outputLength) continue;
        final windowValue = _window[i];
        accumulator[index] += re[i] * windowValue;
        normalisation[index] += windowValue * windowValue;
      }
    }
    final output = Float32List(outputLength);
    for (var i = 0; i < outputLength; i++) {
      final weight = normalisation[i];
      output[i] = weight > 1e-8 ? accumulator[i] / weight : 0.0;
    }
    return output;
  }

  /// Centre frequency of [bin] in Hz.
  double binFrequency(int bin, int sampleRate) => bin * sampleRate / fftSize;

  /// The bin whose centre frequency is closest to [hz].
  int binForFrequency(double hz, int sampleRate) {
    final bin = (hz * fftSize / sampleRate).round();
    return bin.clamp(0, binCount - 1);
  }
}
