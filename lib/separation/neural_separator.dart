import 'dart:math' as math;
import 'dart:typed_data';

import '../core/audio_buffer.dart';
import '../core/dsp/resampler.dart';
import 'inference_backend.dart';
import 'spectral_separator.dart' show SeparatedStems, SeparationCancelled;
import 'stem_kind.dart';

/// Runs a neural separation model over a whole track (SEP-02).
///
/// This is the half of SEP-02 that is not the runtime: chunking the audio to
/// the size the model wants, running it, and putting the pieces back together
/// without seams. It is written against [InferenceSession] rather than any
/// particular runtime, which is what lets the whole path be tested with a
/// stand-in session and makes the choice of runtime replaceable.
///
/// Three things it has to get right:
///
/// * **Rate.** Models are trained at one sample rate (44.1 kHz for Demucs) and
///   the app runs at another. Audio is converted in, and the stems converted
///   back out, so the caller never sees the model's rate.
/// * **Seams.** Windows overlap, and the overlap is crossfaded rather than
///   butt-joined — a hard join between two independently-inferred windows is
///   audible as a click on sustained material.
/// * **Memory.** One window is held at a time, so a ten-minute song costs no
///   more than a one-minute one. That is the same reason the spectral
///   separator is segmented, and it is what makes progress and cancellation
///   have somewhere to land (SEP-04).
class NeuralSeparator {
  const NeuralSeparator({
    required this.session,
    required this.outputOrder,
    this.resampler = const Resampler(),
  });

  final InferenceSession session;

  /// Which stem each of the model's outputs is, in the order it returns them.
  ///
  /// Models do not describe themselves, so this comes from the catalogue.
  /// Demucs, for instance, emits drums, bass, other, vocals — in that order.
  final List<StemKind> outputOrder;

  final Resampler resampler;

  /// Separates [input] into [wanted].
  ///
  /// Stems the model does not produce directly are derived where they can be:
  /// an instrumental is the mix minus the vocal, which is exactly right rather
  /// than an approximation, because the stems sum back to the mix.
  Future<SeparatedStems> separate(
    AudioBuffer input,
    Set<StemKind> wanted, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final source = input.channelCount >= 2 ? input.toStereo() : input.toMono();
    if (source.frameCount == 0) {
      return SeparatedStems({
        for (final kind in wanted)
          kind: AudioBuffer.silence(
            channelCount: source.channelCount,
            frameCount: 0,
            sampleRate: source.sampleRate,
          ),
      });
    }

    final originalRate = source.sampleRate;
    final model = resampler.resample(source, session.sampleRate);

    final produced = await _runWindows(
      model,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );

    // Back to the app's rate before anything else looks at it.
    final atSourceRate = <StemKind, AudioBuffer>{
      for (final entry in produced.entries)
        entry.key: resampler.resample(entry.value, originalRate),
    };

    final result = <StemKind, AudioBuffer>{};
    for (final kind in wanted) {
      final direct = atSourceRate[kind];
      if (direct != null) {
        result[kind] = _trimTo(direct, source.frameCount);
        continue;
      }
      if (kind == StemKind.instrumental) {
        final vocals = atSourceRate[StemKind.vocals];
        if (vocals != null) {
          result[kind] = _subtract(source, _trimTo(vocals, source.frameCount));
          continue;
        }
      }
      // The model does not make this stem and it cannot be derived. Silence is
      // the honest answer; the caller asked for something this model cannot
      // give, which availabilityOf should have prevented.
      result[kind] = AudioBuffer.silence(
        channelCount: source.channelCount,
        frameCount: source.frameCount,
        sampleRate: originalRate,
      );
    }
    return SeparatedStems(result);
  }

  /// Slides the model's window over the track, crossfading the overlaps.
  Future<Map<StemKind, AudioBuffer>> _runWindows(
    AudioBuffer source, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final windowFrames = math.max(1, session.windowFrames);
    // An overlap at or beyond half the window would advance by nothing.
    final overlapFrames = session.overlapFrames.clamp(0, windowFrames ~/ 2);
    final hop = windowFrames - overlapFrames;

    final outputs = <StemKind, AudioBuffer>{
      for (final kind in outputOrder)
        kind: AudioBuffer.silence(
          channelCount: source.channelCount,
          frameCount: source.frameCount,
          sampleRate: source.sampleRate,
        ),
    };
    // Summed fade weights per frame, so the crossfade can be normalised at the
    // end instead of assuming the windows line up perfectly.
    final weights = Float32List(source.frameCount);

    final windowCount = math.max(1, (source.frameCount / hop).ceil());
    for (var index = 0; index < windowCount; index++) {
      if (isCancelled?.call() ?? false) throw const SeparationCancelled();

      final start = index * hop;
      if (start >= source.frameCount) break;
      final length = math.min(windowFrames, source.frameCount - start);

      final chunk = _sliceChannels(source, start, windowFrames, length);
      final stems = await session.run(chunk);

      for (var output = 0; output < stems.length; output++) {
        if (output >= outputOrder.length) break;
        final target = outputs[outputOrder[output]]!;
        _accumulate(
          target: target,
          produced: stems[output],
          start: start,
          length: length,
          overlapFrames: overlapFrames,
          isFirst: index == 0,
          isLast: start + length >= source.frameCount,
        );
      }
      _accumulateWeights(
        weights: weights,
        start: start,
        length: length,
        overlapFrames: overlapFrames,
        isFirst: index == 0,
        isLast: start + length >= source.frameCount,
      );

      onProgress?.call((index + 1) / windowCount);
    }

    for (final buffer in outputs.values) {
      _normalise(buffer, weights);
    }
    return outputs;
  }

  /// Copies a window out of [source], zero-padded to the model's window size.
  ///
  /// The model expects a fixed-size input, so the final short window is padded
  /// rather than run at a different length.
  List<Float32List> _sliceChannels(
    AudioBuffer source,
    int start,
    int windowFrames,
    int length,
  ) {
    return [
      for (final channel in source.channels)
        Float32List(windowFrames)..setRange(0, length, channel, start),
    ];
  }

  /// Adds one window's output into the running stem, faded at the joins.
  void _accumulate({
    required AudioBuffer target,
    required List<Float32List> produced,
    required int start,
    required int length,
    required int overlapFrames,
    required bool isFirst,
    required bool isLast,
  }) {
    for (var channel = 0; channel < target.channelCount; channel++) {
      // A mono model output feeding a stereo buffer reuses its only channel.
      final from = produced[math.min(channel, produced.length - 1)];
      final into = target.channels[channel];
      for (var i = 0; i < length; i++) {
        final position = start + i;
        if (position >= into.length || i >= from.length) break;
        into[position] +=
            from[i] *
            _fade(
              i,
              length: length,
              overlapFrames: overlapFrames,
              isFirst: isFirst,
              isLast: isLast,
            );
      }
    }
  }

  void _accumulateWeights({
    required Float32List weights,
    required int start,
    required int length,
    required int overlapFrames,
    required bool isFirst,
    required bool isLast,
  }) {
    for (var i = 0; i < length; i++) {
      final position = start + i;
      if (position >= weights.length) break;
      weights[position] += _fade(
        i,
        length: length,
        overlapFrames: overlapFrames,
        isFirst: isFirst,
        isLast: isLast,
      );
    }
  }

  /// Equal-gain ramp across the overlap, flat everywhere else.
  ///
  /// The ramps are not normalised here — the summed weight is divided out
  /// afterwards — which keeps the joins exact even where only one window
  /// covers a frame, such as the very start and end of the track.
  double _fade(
    int offset, {
    required int length,
    required int overlapFrames,
    required bool isFirst,
    required bool isLast,
  }) {
    if (overlapFrames <= 0) return 1;
    var gain = 1.0;
    if (!isFirst && offset < overlapFrames) {
      gain *= (offset + 1) / (overlapFrames + 1);
    }
    if (!isLast && offset >= length - overlapFrames) {
      final into = length - offset;
      gain *= into / (overlapFrames + 1);
    }
    return gain.clamp(0.0, 1.0);
  }

  /// Divides out the summed crossfade weights.
  void _normalise(AudioBuffer buffer, Float32List weights) {
    for (final channel in buffer.channels) {
      for (var i = 0; i < channel.length && i < weights.length; i++) {
        final weight = weights[i];
        if (weight > 1e-6) channel[i] /= weight;
      }
    }
  }

  /// The mix minus a stem.
  ///
  /// Exact rather than approximate: the point of deriving the instrumental
  /// this way is that whatever the model failed to pull into the vocal stem
  /// stays in the backing, where the user can still hear it.
  AudioBuffer _subtract(AudioBuffer mix, AudioBuffer stem) {
    final result = AudioBuffer.silence(
      channelCount: mix.channelCount,
      frameCount: mix.frameCount,
      sampleRate: mix.sampleRate,
    );
    for (var channel = 0; channel < mix.channelCount; channel++) {
      final from = mix.channels[channel];
      final take = stem.channels[math.min(channel, stem.channelCount - 1)];
      final into = result.channels[channel];
      for (var i = 0; i < into.length; i++) {
        into[i] = from[i] - (i < take.length ? take[i] : 0);
      }
    }
    return result;
  }

  /// Resampling can land a frame or two either side of the original length.
  AudioBuffer _trimTo(AudioBuffer buffer, int frameCount) {
    if (buffer.frameCount == frameCount) return buffer;
    final result = AudioBuffer.silence(
      channelCount: buffer.channelCount,
      frameCount: frameCount,
      sampleRate: buffer.sampleRate,
    );
    for (var channel = 0; channel < buffer.channelCount; channel++) {
      final from = buffer.channels[channel];
      final into = result.channels[channel];
      final count = math.min(from.length, into.length);
      into.setRange(0, count, from);
    }
    return result;
  }
}
