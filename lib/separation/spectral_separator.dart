import 'dart:math' as math;
import 'dart:typed_data';

import '../core/audio_buffer.dart';
import '../core/dsp/stft.dart';
import 'stem_kind.dart';

/// Tuning for [SpectralSeparator].
class SpectralSeparationOptions {
  const SpectralSeparationOptions({
    this.fftSize = 4096,
    this.hopSize = 1024,
    this.harmonicPercussiveWindow = 9,
    this.centreSharpness = 2.5,
    this.maskFloor = 0.02,
    this.segmentSeconds = 20.0,
    this.crossfadeSeconds = 0.75,
  });

  /// Quick pass: no harmonic/percussive analysis, coarser transform.
  static const SpectralSeparationOptions fast = SpectralSeparationOptions(
    fftSize: 2048,
    hopSize: 512,
    harmonicPercussiveWindow: 0,
    centreSharpness: 2.0,
  );

  /// The default: panning analysis plus harmonic/percussive weighting.
  static const SpectralSeparationOptions balanced = SpectralSeparationOptions();

  /// Slower, with a wider median window and a longer transform.
  static const SpectralSeparationOptions detailed = SpectralSeparationOptions(
    fftSize: 8192,
    hopSize: 2048,
    harmonicPercussiveWindow: 17,
    centreSharpness: 3.0,
  );

  final int fftSize;
  final int hopSize;

  /// Median filter length for the harmonic/percussive split, in frames and
  /// bins. Zero disables it, which is much faster but leaves more percussion
  /// in the vocal stem.
  final int harmonicPercussiveWindow;

  /// How aggressively the centre-ness measure is pushed towards 0 or 1.
  final double centreSharpness;

  /// Masks never go fully to zero; a small floor keeps the residual sounding
  /// natural instead of gated.
  final double maskFloor;

  /// Audio is separated in segments so peak memory stays bounded regardless of
  /// track length, and so progress and cancellation have somewhere to land.
  final double segmentSeconds;

  /// Segments overlap by this much and are crossfaded together, which hides
  /// the transform's edge effects at the seams.
  final double crossfadeSeconds;

  bool get usesHarmonicPercussive => harmonicPercussiveWindow >= 3;
}

/// Stems produced by a separation pass.
class SeparatedStems {
  const SeparatedStems(this.stems);

  final Map<StemKind, AudioBuffer> stems;

  AudioBuffer? operator [](StemKind kind) => stems[kind];
}

/// Offline stem separation built on spectral masking.
///
/// The method combines three cues that hold for almost all produced music:
///
/// * **Panning.** A lead vocal is mixed to the centre, so it appears in the
///   left and right channels with the same phase and nearly the same level.
///   Bins where the two channels agree are vocal candidates; bins where they
///   disagree belong to something panned, and therefore to the backing.
/// * **Harmonicity.** Voices are sustained and harmonic — bright horizontal
///   ridges on a spectrogram — while drums are transient and broadband. A
///   median filter along time versus along frequency separates the two.
/// * **Frequency range.** Bass and kick sit below the voice; cymbals sit above
///   it. Weighting the mask by frequency keeps them out of the vocal stem.
///
/// The resulting masks are complementary — they sum to one — so the stems add
/// back up to the original mix exactly, and the instrumental is guaranteed to
/// contain everything the vocal stem does not.
///
/// This runs entirely on the CPU with no model file, so it works offline on
/// first launch and on hardware that cannot host a neural separator (SEP-07).
/// It is deliberately isolate-safe: no Flutter imports, no I/O, no globals.
class SpectralSeparator {
  const SpectralSeparator({this.options = SpectralSeparationOptions.balanced});

  final SpectralSeparationOptions options;

  /// Separates [input] into [wanted].
  ///
  /// [onProgress] is called with 0..1 as segments complete, and [isCancelled]
  /// is polled between segments so a long job can be abandoned promptly
  /// (SEP-04).
  SeparatedStems separate(
    AudioBuffer input,
    Set<StemKind> wanted, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) {
    final source = input.channelCount >= 2 ? input.toStereo() : input.toMono();
    final frameCount = source.frameCount;
    final outputs = <StemKind, AudioBuffer>{
      for (final kind in wanted)
        kind: AudioBuffer.silence(
          channelCount: source.channelCount,
          frameCount: frameCount,
          sampleRate: source.sampleRate,
        ),
    };
    if (frameCount == 0) return SeparatedStems(outputs);

    final segmentFrames = math.max(
      options.fftSize * 4,
      (options.segmentSeconds * source.sampleRate).round(),
    );
    final crossfadeFrames = math.min(
      segmentFrames ~/ 4,
      (options.crossfadeSeconds * source.sampleRate).round(),
    );
    final advance = math.max(1, segmentFrames - crossfadeFrames);
    final segmentCount = math.max(1, (frameCount / advance).ceil());

    // Tracks how much weight each output sample has received, so overlapping
    // segments can be crossfaded without changing the overall level.
    final weights = Float64List(frameCount);

    for (var segment = 0; segment < segmentCount; segment++) {
      if (isCancelled?.call() ?? false) {
        throw const SeparationCancelled();
      }
      final start = segment * advance;
      if (start >= frameCount) break;
      final length = math.min(segmentFrames, frameCount - start);
      final block = source.slice(start, length);

      final stft = Stft(fftSize: options.fftSize, hopSize: options.hopSize);
      // Analysed once and reused for both the mask estimation and every
      // stem's synthesis; the transform is the expensive part of the pass.
      final spectra = [
        for (var ch = 0; ch < block.channelCount; ch++)
          stft.analyze(block.channels[ch]),
      ];
      final masks = _masksFor(block, spectra, stft, wanted);

      for (final kind in wanted) {
        final mask = masks[kind]!;
        for (var ch = 0; ch < block.channelCount; ch++) {
          final rendered = stft.synthesizeMasked(spectra[ch], length, mask);
          final destination = outputs[kind]!.channels[ch];
          for (var i = 0; i < length; i++) {
            destination[start + i] +=
                rendered[i] * _segmentWeight(i, length, crossfadeFrames,
                    isFirst: segment == 0,
                    isLast: start + length >= frameCount);
          }
        }
      }
      for (var i = 0; i < length; i++) {
        weights[start + i] += _segmentWeight(i, length, crossfadeFrames,
            isFirst: segment == 0, isLast: start + length >= frameCount);
      }
      onProgress?.call((segment + 1) / segmentCount);
    }

    // Normalise by the accumulated crossfade weight so the seams are seamless.
    for (final buffer in outputs.values) {
      for (final channel in buffer.channels) {
        for (var i = 0; i < frameCount; i++) {
          final weight = weights[i];
          if (weight > 1e-6) channel[i] = channel[i] / weight;
        }
      }
    }
    return SeparatedStems(outputs);
  }

  /// Raised-cosine ramp in and out of each segment.
  double _segmentWeight(
    int index,
    int length,
    int crossfade, {
    required bool isFirst,
    required bool isLast,
  }) {
    if (crossfade <= 0) return 1.0;
    var weight = 1.0;
    if (!isFirst && index < crossfade) {
      weight *= 0.5 - 0.5 * math.cos(math.pi * index / crossfade);
    }
    if (!isLast && index >= length - crossfade) {
      final position = length - 1 - index;
      weight *= 0.5 - 0.5 * math.cos(math.pi * position / crossfade);
    }
    return weight;
  }

  /// Builds one flat `frames * bins` gain array per requested stem.
  Map<StemKind, Float32List> _masksFor(
    AudioBuffer block,
    List<List<SpectralFrame>> spectra,
    Stft stft,
    Set<StemKind> wanted,
  ) {
    final bins = stft.binCount;
    final left = spectra[0];
    final right = spectra.length > 1 ? spectra[1] : left;
    final frames = left.length;
    final cells = frames * bins;

    final centre = Float32List(cells);
    final magnitude = Float32List(cells);
    for (var frame = 0; frame < frames; frame++) {
      final l = left[frame];
      final r = right[frame];
      final offset = frame * bins;
      for (var bin = 0; bin < bins; bin++) {
        final lRe = l.re[bin];
        final lIm = l.im[bin];
        final rRe = r.re[bin];
        final rIm = r.im[bin];
        final lMagSquared = lRe * lRe + lIm * lIm;
        final rMagSquared = rRe * rRe + rIm * rIm;
        final lMag = math.sqrt(lMagSquared);
        final rMag = math.sqrt(rMagSquared);
        magnitude[offset + bin] = (lMag + rMag) * 0.5;

        if (block.channelCount == 1) {
          // A mono source carries no panning information at all, so every bin
          // is equally "centred" and the split rests on the other two cues.
          centre[offset + bin] = 1.0;
          continue;
        }
        // |L conj(R)| relative to the total energy: 1 when the two channels
        // are in phase and proportional, 0 when they are unrelated.
        final dot = lRe * rRe + lIm * rIm;
        final cross = lIm * rRe - lRe * rIm;
        final correlation = math.sqrt(dot * dot + cross * cross);
        final coherence =
            2 * correlation / (lMagSquared + rMagSquared + 1e-12);
        // How evenly the energy sits between the speakers.
        final balance = 1 - (lMag - rMag).abs() / (lMag + rMag + 1e-12);
        centre[offset + bin] = (coherence * balance).clamp(0.0, 1.0);
      }
    }

    final harmonic = options.usesHarmonicPercussive
        ? _harmonicWeight(magnitude, frames, bins)
        : null;

    final vocalBand = _bandWeights(
      bins,
      block.sampleRate,
      stft,
      lowStopHz: 110,
      lowPassHz: 260,
      highPassHz: 7000,
      highStopHz: 16000,
      highFloor: 0.45,
    );
    final bassBand = _bandWeights(
      bins,
      block.sampleRate,
      stft,
      lowStopHz: 0,
      lowPassHz: 0,
      highPassHz: 180,
      highStopHz: 400,
      highFloor: 0.0,
    );

    // Vocal mask: centred, harmonic and in the voice's range.
    final vocals = Float32List(cells);
    for (var frame = 0; frame < frames; frame++) {
      final offset = frame * bins;
      for (var bin = 0; bin < bins; bin++) {
        var value = math.pow(centre[offset + bin], options.centreSharpness)
            .toDouble();
        value *= vocalBand[bin];
        if (harmonic != null) value *= harmonic[offset + bin];
        vocals[offset + bin] = value.clamp(0.0, 1.0);
      }
    }
    _smoothAcrossTime(vocals, frames, bins);
    for (var i = 0; i < cells; i++) {
      final value = vocals[i];
      // Squash towards the extremes: a soft decision leaves a watery residue,
      // a hard one leaves holes. This sits between the two.
      final shaped = value * value / (value * value + (1 - value) * (1 - value) + 1e-9);
      vocals[i] = shaped.clamp(options.maskFloor, 1 - options.maskFloor);
    }

    final masks = <StemKind, Float32List>{};
    if (wanted.contains(StemKind.vocals)) masks[StemKind.vocals] = vocals;

    final needsBacking = wanted.any(
      (kind) => kind != StemKind.vocals,
    );
    if (!needsBacking) return masks;

    final backing = Float32List(cells);
    for (var i = 0; i < cells; i++) {
      backing[i] = 1.0 - vocals[i];
    }
    if (wanted.contains(StemKind.instrumental)) {
      masks[StemKind.instrumental] = backing;
    }

    if (wanted.contains(StemKind.drums) ||
        wanted.contains(StemKind.bass) ||
        wanted.contains(StemKind.other)) {
      final percussive = Float32List(cells);
      for (var i = 0; i < cells; i++) {
        percussive[i] = harmonic == null ? 0.0 : 1.0 - harmonic[i];
      }

      final drums = Float32List(cells);
      final bass = Float32List(cells);
      final other = Float32List(cells);
      for (var frame = 0; frame < frames; frame++) {
        final offset = frame * bins;
        for (var bin = 0; bin < bins; bin++) {
          final index = offset + bin;
          final available = backing[index];
          final drumShare = available * percussive[index];
          final bassShare =
              (available - drumShare) * bassBand[bin];
          drums[index] = drumShare;
          bass[index] = bassShare;
          // Whatever is left is "other", which keeps the four masks summing
          // to exactly one with the vocal mask.
          other[index] = math.max(0.0, available - drumShare - bassShare);
        }
      }
      if (wanted.contains(StemKind.drums)) masks[StemKind.drums] = drums;
      if (wanted.contains(StemKind.bass)) masks[StemKind.bass] = bass;
      if (wanted.contains(StemKind.other)) masks[StemKind.other] = other;
    }
    return masks;
  }

  /// Per-cell weight in `[0, 1]`, high where the spectrogram looks harmonic.
  ///
  /// The classic median-filter split: filtering along time keeps sustained
  /// tones and erases transients; filtering along frequency does the opposite.
  /// Comparing the two gives a soft harmonic/percussive decision.
  Float32List _harmonicWeight(Float32List magnitude, int frames, int bins) {
    final window = options.harmonicPercussiveWindow;
    final harmonic = _medianAlongTime(magnitude, frames, bins, window);
    final percussive = _medianAlongFrequency(magnitude, frames, bins, window);
    final weight = Float32List(frames * bins);
    for (var i = 0; i < weight.length; i++) {
      final h = harmonic[i] * harmonic[i];
      final p = percussive[i] * percussive[i];
      weight[i] = h + p < 1e-18 ? 0.5 : h / (h + p);
    }
    return weight;
  }

  Float32List _medianAlongTime(
    Float32List source,
    int frames,
    int bins,
    int window,
  ) {
    final result = Float32List(frames * bins);
    final scratch = Float32List(window);
    final half = window ~/ 2;
    for (var bin = 0; bin < bins; bin++) {
      for (var frame = 0; frame < frames; frame++) {
        var count = 0;
        for (var offset = -half; offset <= half; offset++) {
          final index = frame + offset;
          if (index < 0 || index >= frames) continue;
          scratch[count++] = source[index * bins + bin];
        }
        result[frame * bins + bin] = _median(scratch, count);
      }
    }
    return result;
  }

  Float32List _medianAlongFrequency(
    Float32List source,
    int frames,
    int bins,
    int window,
  ) {
    final result = Float32List(frames * bins);
    final scratch = Float32List(window);
    final half = window ~/ 2;
    for (var frame = 0; frame < frames; frame++) {
      final offset = frame * bins;
      for (var bin = 0; bin < bins; bin++) {
        var count = 0;
        for (var delta = -half; delta <= half; delta++) {
          final index = bin + delta;
          if (index < 0 || index >= bins) continue;
          scratch[count++] = source[offset + index];
        }
        result[offset + bin] = _median(scratch, count);
      }
    }
    return result;
  }

  /// Insertion sort over the populated prefix of [values]; the windows are
  /// small enough that this beats anything with an allocation in it.
  static double _median(Float32List values, int count) {
    if (count == 0) return 0.0;
    for (var i = 1; i < count; i++) {
      final value = values[i];
      var j = i - 1;
      while (j >= 0 && values[j] > value) {
        values[j + 1] = values[j];
        j--;
      }
      values[j + 1] = value;
    }
    return count.isOdd
        ? values[count ~/ 2]
        : (values[count ~/ 2 - 1] + values[count ~/ 2]) / 2;
  }

  /// Three-frame smoothing, which removes the flickering that would otherwise
  /// be heard as "musical noise" around the vocal.
  static void _smoothAcrossTime(Float32List mask, int frames, int bins) {
    if (frames < 3) return;
    final previous = Float32List(bins);
    previous.setRange(0, bins, mask, 0);
    for (var frame = 1; frame < frames - 1; frame++) {
      final offset = frame * bins;
      final next = frame + 1;
      for (var bin = 0; bin < bins; bin++) {
        final current = mask[offset + bin];
        final smoothed =
            (previous[bin] + 2 * current + mask[next * bins + bin]) / 4;
        previous[bin] = current;
        mask[offset + bin] = smoothed;
      }
    }
  }

  /// A gentle band-pass envelope over the bins, with cosine ramps so there is
  /// no audible edge where the weighting starts.
  static Float32List _bandWeights(
    int bins,
    int sampleRate,
    Stft stft, {
    required double lowStopHz,
    required double lowPassHz,
    required double highPassHz,
    required double highStopHz,
    required double highFloor,
  }) {
    final weights = Float32List(bins);
    for (var bin = 0; bin < bins; bin++) {
      final hz = stft.binFrequency(bin, sampleRate);
      var weight = 1.0;
      if (lowPassHz > lowStopHz) {
        if (hz <= lowStopHz) {
          weight = 0.0;
        } else if (hz < lowPassHz) {
          weight = 0.5 -
              0.5 * math.cos(math.pi * (hz - lowStopHz) / (lowPassHz - lowStopHz));
        }
      }
      if (highStopHz > highPassHz && hz > highPassHz) {
        final ramp = hz >= highStopHz
            ? 1.0
            : 0.5 -
                0.5 *
                    math.cos(
                      math.pi * (hz - highPassHz) / (highStopHz - highPassHz),
                    );
        weight *= 1.0 - ramp * (1.0 - highFloor);
      }
      weights[bin] = weight;
    }
    return weights;
  }
}

/// Thrown from inside a separation pass when the caller cancels it.
class SeparationCancelled implements Exception {
  const SeparationCancelled();

  @override
  String toString() => 'Separation was cancelled.';
}
