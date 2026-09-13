import 'dart:math' as math;
import 'dart:typed_data';

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/core/dsp/limiter.dart';
import 'package:encore/core/dsp/resampler.dart';
import 'package:encore/core/waveform.dart';
import 'package:encore/engine/mix_graph.dart';
import 'package:flutter_test/flutter_test.dart';

/// Numbers that should never reach the speakers.
///
/// The failures here are quieter than a crash and worse to debug: a NaN that
/// spreads through a mix and silences a whole take, a clip index that reads
/// past the end of its asset, a gain that sends the output to infinity. None
/// of them throw. They just ruin the audio, and the first anyone knows is an
/// exported file that is wrong.
void main() {
  AudioBuffer buffer({
    int frames = 512,
    int channels = 2,
    double fill = 0.5,
  }) {
    final b = AudioBuffer.silence(
      channelCount: channels,
      frameCount: frames,
      sampleRate: 48000,
    );
    for (final channel in b.channels) {
      channel.fillRange(0, frames, fill);
    }
    return b;
  }

  bool allFinite(AudioBuffer b) {
    for (final channel in b.channels) {
      for (final sample in channel) {
        if (sample.isNaN || sample.isInfinite) return false;
      }
    }
    return true;
  }

  double peak(AudioBuffer b) {
    var p = 0.0;
    for (final channel in b.channels) {
      for (final sample in channel) {
        if (sample.isFinite) p = math.max(p, sample.abs());
      }
    }
    return p;
  }

  group('the master limiter', () {
    test('holds a loud signal below the threshold', () {
      final limiter = Limiter(sampleRate: 48000, channelCount: 2);
      final loud = buffer(frames: 4096, fill: 8);
      limiter.process(loud.channels);
      expect(peak(loud), lessThanOrEqualTo(1.0));
    });

    test('does not produce NaN from a silent input', () {
      final limiter = Limiter(sampleRate: 48000, channelCount: 2);
      final silence = buffer(frames: 2048, fill: 0);
      limiter.process(silence.channels);
      expect(allFinite(silence), isTrue);
    });

    test('a NaN in the input does not spread through the whole block', () {
      // A NaN reaching the limiter's envelope follower would poison the gain
      // for every following sample — one bad frame silencing the rest of the
      // song, which is exactly the kind of fault nobody traces back.
      final limiter = Limiter(sampleRate: 48000, channelCount: 2);
      final b = buffer(frames: 2048, fill: 0.4);
      b.channels[0][100] = double.nan;
      limiter.process(b.channels);

      var poisoned = 0;
      for (final sample in b.channels[0]) {
        if (sample.isNaN) poisoned++;
      }
      expect(
        poisoned,
        lessThan(b.frameCount ~/ 2),
        reason: 'one bad sample must not take the block with it',
      );
    });

    test('a NaN does not poison the gain state for later blocks', () {
      // The worse version of the previous case. The limiter carries an
      // envelope between calls, so a NaN folded into it would silence every
      // block that follows — the take keeps recording and plays back empty,
      // with nothing in the file to explain why.
      final limiter = Limiter(sampleRate: 48000, channelCount: 2);
      final poisoned = buffer(frames: 1024, fill: 0.4);
      poisoned.channels[0][10] = double.nan;
      limiter.process(poisoned.channels);

      final clean = buffer(frames: 1024, fill: 0.4);
      limiter.process(clean.channels);

      expect(allFinite(clean), isTrue, reason: 'later blocks must stay finite');
      expect(
        peak(clean),
        greaterThan(0.05),
        reason: 'later blocks must still carry audio, not be gated to silence',
      );
    });

    test('an infinite input does not leave the output infinite', () {
      final limiter = Limiter(sampleRate: 48000, channelCount: 2);
      final b = buffer(frames: 2048, fill: 0.4);
      b.channels[1][50] = double.infinity;
      limiter.process(b.channels);
      expect(
        peak(b),
        lessThanOrEqualTo(1.0),
        reason: 'the finite samples around it must still be limited',
      );
    });
  });

  group('the mixing graph', () {
    GraphClip clip({
      required AudioBuffer asset,
      int timelineStart = 0,
      int assetOffset = 0,
      int? length,
      double gain = 1,
    }) => GraphClip(
      asset: asset,
      timelineStart: timelineStart,
      assetOffset: assetOffset,
      length: length ?? asset.frameCount,
      gain: gain,
    );

    test('a clip reading past the end of its asset does not throw', () {
      final asset = buffer(frames: 100);
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(
            id: 't',
            clips: [clip(asset: asset, assetOffset: 90, length: 5000)],
          ),
        ];
      final out = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 2048,
        sampleRate: 48000,
      );
      expect(() => graph.render(0, out), returnsNormally);
      expect(allFinite(out), isTrue);
    });

    test('a negative asset offset does not read before the buffer', () {
      final asset = buffer(frames: 500);
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(
            id: 't',
            clips: [clip(asset: asset, assetOffset: -1000, length: 500)],
          ),
        ];
      final out = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 1024,
        sampleRate: 48000,
      );
      expect(() => graph.render(0, out), returnsNormally);
      expect(allFinite(out), isTrue);
    });

    test('a clip starting at a negative timeline position is safe', () {
      final asset = buffer(frames: 500);
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(
            id: 't',
            clips: [clip(asset: asset, timelineStart: -2000)],
          ),
        ];
      final out = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 1024,
        sampleRate: 48000,
      );
      expect(() => graph.render(0, out), returnsNormally);
      expect(allFinite(out), isTrue);
    });

    test('a mono asset feeding a stereo bus does not go out of range', () {
      final mono = buffer(frames: 1024, channels: 1);
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(id: 't', clips: [clip(asset: mono)]),
        ];
      final out = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 1024,
        sampleRate: 48000,
      );
      expect(() => graph.render(0, out), returnsNormally);
      expect(peak(out), greaterThan(0), reason: 'mono must still be heard');
    });

    test('rendering past the end of the destination is clamped', () {
      final asset = buffer(frames: 4096);
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(id: 't', clips: [clip(asset: asset)]),
        ];
      final out = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 512,
        sampleRate: 48000,
      );
      expect(
        () => graph.render(0, out, destinationOffset: 400, frames: 4096),
        returnsNormally,
      );
      expect(allFinite(out), isTrue);
    });

    test('an extreme gain stays finite so the limiter can catch it', () {
      final asset = buffer(frames: 1024, fill: 1);
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(
            id: 't',
            gain: 1e9,
            clips: [clip(asset: asset, gain: 1e9)],
          ),
        ];
      final out = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 1024,
        sampleRate: 48000,
      );
      graph.render(0, out);
      expect(
        allFinite(out),
        isTrue,
        reason: 'infinity here would survive the limiter and reach the file',
      );
    });

    test('an empty graph renders silence rather than throwing', () {
      final graph = MixGraph(sampleRate: 48000)..tracks = const [];
      final out = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 256,
        sampleRate: 48000,
      );
      expect(() => graph.render(0, out), returnsNormally);
      expect(peak(out), 0);
    });

    test('a zero-length clip is skipped', () {
      final asset = buffer(frames: 512);
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(id: 't', clips: [clip(asset: asset, length: 0)]),
        ];
      final out = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 512,
        sampleRate: 48000,
      );
      expect(() => graph.render(0, out), returnsNormally);
    });
  });

  group('the resampler', () {
    test('an extreme downward ratio does not throw or produce NaN', () {
      final input = buffer(frames: 48000, fill: 0.3);
      final out = const Resampler().resample(input, 1000);
      expect(out.frameCount, greaterThan(0));
      expect(allFinite(out), isTrue);
    });

    test('an extreme upward ratio stays finite', () {
      final input = buffer(frames: 480, fill: 0.3);
      final out = const Resampler().resample(input, 192000);
      expect(allFinite(out), isTrue);
    });

    test('an empty buffer resamples to empty', () {
      final empty = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 0,
        sampleRate: 48000,
      );
      final out = const Resampler().resample(empty, 44100);
      expect(out.frameCount, 0);
    });

    test('the same rate returns the buffer untouched', () {
      final input = buffer(frames: 128);
      expect(identical(const Resampler().resample(input, 48000), input), isTrue);
    });
  });

  group('waveform envelopes', () {
    test('corrupt sidecar bytes decode to null rather than throwing', () {
      expect(
        () => WaveformPeaks.decode(Uint8List.fromList([1, 2, 3, 4, 5])),
        returnsNormally,
      );
      expect(WaveformPeaks.decode(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('an empty byte list decodes to null', () {
      expect(WaveformPeaks.decode(Uint8List(0)), isNull);
    });

    test('a header claiming a huge count does not allocate wildly', () {
      // Four bytes of magic/count that claim billions of buckets.
      final bytes = Uint8List(32);
      bytes.buffer.asByteData().setUint32(0, 0x7FFFFFFF);
      expect(() => WaveformPeaks.decode(bytes), returnsNormally);
    });

    test('a buffer of NaN produces a finite envelope', () {
      final b = buffer(frames: 2048);
      for (final channel in b.channels) {
        channel.fillRange(0, 2048, double.nan);
      }
      final peaks = WaveformPeaks.fromBuffer(b);
      for (final value in peaks.minimums) {
        expect(value.isFinite, isTrue);
      }
      for (final value in peaks.maximums) {
        expect(value.isFinite, isTrue);
      }
    });
  });
}
