import 'dart:math' as math;
import 'dart:typed_data';

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/core/dsp/fft.dart';
import 'package:encore/core/dsp/limiter.dart';
import 'package:encore/core/dsp/resampler.dart';
import 'package:encore/core/dsp/stft.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Fft', () {
    test('inverse undoes forward', () {
      final fft = Fft(64);
      final random = math.Random(7);
      final original = Float64List.fromList(
        List.generate(64, (_) => random.nextDouble() * 2 - 1),
      );
      final re = Float64List.fromList(original);
      final im = Float64List(64);

      fft.forward(re, im);
      fft.inverse(re, im);

      for (var i = 0; i < 64; i++) {
        expect(re[i], closeTo(original[i], 1e-9));
        expect(im[i], closeTo(0.0, 1e-9));
      }
    });

    test('resolves a pure tone into a single bin', () {
      const size = 256;
      final fft = Fft(size);
      final re = Float64List(size);
      final im = Float64List(size);
      // Exactly 8 cycles across the window, so it lands on bin 8 with no leak.
      for (var i = 0; i < size; i++) {
        re[i] = math.sin(2 * math.pi * 8 * i / size);
      }
      fft.forward(re, im);

      final magnitudes = [
        for (var bin = 0; bin < size ~/ 2; bin++)
          math.sqrt(re[bin] * re[bin] + im[bin] * im[bin]),
      ];
      final loudest = magnitudes.indexOf(magnitudes.reduce(math.max));
      expect(loudest, 8);
    });
  });

  group('Stft', () {
    test('analyse then synthesise reproduces the signal', () {
      final stft = Stft(fftSize: 512, hopSize: 128);
      final random = math.Random(11);
      final samples = Float32List.fromList(
        List.generate(4000, (_) => random.nextDouble() * 2 - 1),
      );

      final restored = stft.synthesize(stft.analyze(samples), samples.length);

      for (var i = 0; i < samples.length; i++) {
        expect(restored[i], closeTo(samples[i], 1e-4), reason: 'sample $i');
      }
    });

    test('masked synthesis with a unit mask matches plain synthesis', () {
      final stft = Stft(fftSize: 256, hopSize: 64);
      final samples = Float32List.fromList(
        List.generate(1000, (i) => math.sin(i * 0.05)),
      );
      final frames = stft.analyze(samples);
      final mask = Float32List(frames.length * stft.binCount)
        ..fillRange(0, frames.length * stft.binCount, 1.0);

      final plain = stft.synthesize(frames, samples.length);
      final masked = stft.synthesizeMasked(frames, samples.length, mask);

      for (var i = 0; i < samples.length; i++) {
        expect(masked[i], closeTo(plain[i], 1e-6));
      }
    });
  });

  group('Resampler', () {
    test('preserves the frequency of a tone across a rate change', () {
      const sourceRate = 48000;
      const targetRate = 24000;
      const toneHz = 1000.0;
      final samples = Float32List(sourceRate);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = math.sin(2 * math.pi * toneHz * i / sourceRate);
      }
      final buffer = AudioBuffer([samples], sourceRate);

      final resampled = const Resampler().resample(buffer, targetRate);

      expect(resampled.sampleRate, targetRate);
      expect(resampled.frameCount, closeTo(targetRate, 2));
      // Count zero crossings over the middle second to recover the frequency,
      // ignoring the filter's edges.
      var crossings = 0;
      final channel = resampled.channels[0];
      for (var i = 2001; i < channel.length - 2000; i++) {
        if (channel[i - 1] < 0 && channel[i] >= 0) crossings++;
      }
      final seconds = (channel.length - 4001) / targetRate;
      expect(crossings / seconds, closeTo(toneHz, 5));
    });

    test('is a no-op when the rate already matches', () {
      final buffer = AudioBuffer([Float32List(10)], 44100);
      expect(identical(const Resampler().resample(buffer, 44100), buffer), isTrue);
    });
  });

  group('Limiter', () {
    test('holds peaks under the threshold', () {
      final limiter = Limiter(
        sampleRate: 48000,
        channelCount: 1,
        thresholdLinear: 0.5,
      );
      final loud = Float32List(48000);
      for (var i = 0; i < loud.length; i++) {
        loud[i] = math.sin(2 * math.pi * 220 * i / 48000) * 2.0;
      }

      limiter.process([loud]);

      // Skip the look-ahead delay at the very start, which is still silence.
      for (var i = limiter.latencyFrames * 2; i < loud.length; i++) {
        expect(loud[i].abs(), lessThanOrEqualTo(0.51), reason: 'sample $i');
      }
    });

    test('leaves quiet material untouched', () {
      final limiter = Limiter(sampleRate: 48000, channelCount: 1);
      final quiet = Float32List(2048);
      for (var i = 0; i < quiet.length; i++) {
        quiet[i] = math.sin(i * 0.01) * 0.2;
      }
      final expected = Float32List.fromList(quiet);

      limiter.process([quiet]);

      final delay = limiter.latencyFrames;
      for (var i = delay; i < quiet.length; i++) {
        expect(quiet[i], closeTo(expected[i - delay], 1e-6));
      }
    });
  });

  group('AudioBuffer', () {
    test('round-trips through interleaved int16', () {
      final buffer = AudioBuffer([
        Float32List.fromList([0.0, 0.5, -0.5]),
        Float32List.fromList([1.0, -1.0, 0.25]),
      ], 48000);

      final restored = AudioBuffer.fromInterleavedInt16(
        buffer.toInterleavedInt16(),
        channelCount: 2,
        sampleRate: 48000,
      );

      for (var ch = 0; ch < 2; ch++) {
        for (var i = 0; i < 3; i++) {
          expect(restored.channels[ch][i], closeTo(buffer.channels[ch][i], 1e-4));
        }
      }
    });

    test('slice pads beyond the end with silence', () {
      final buffer = AudioBuffer([
        Float32List.fromList([1.0, 2.0, 3.0]),
      ], 48000);

      final slice = buffer.slice(2, 4);

      expect(slice.frameCount, 4);
      expect(slice.channels[0][0], 3.0);
      expect(slice.channels[0][1], 0.0);
    });

    test('slice before the start aligns the copied region', () {
      final buffer = AudioBuffer([
        Float32List.fromList([1.0, 2.0]),
      ], 48000);

      final slice = buffer.slice(-2, 4);

      expect(slice.channels[0][0], 0.0);
      expect(slice.channels[0][1], 0.0);
      expect(slice.channels[0][2], 1.0);
      expect(slice.channels[0][3], 2.0);
    });
  });
}
