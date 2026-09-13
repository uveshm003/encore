import 'dart:math' as math;
import 'dart:typed_data';

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/core/waveform.dart';
import 'package:flutter_test/flutter_test.dart';

AudioBuffer ramp(int frames) {
  final buffer = AudioBuffer.silence(
    channelCount: 1,
    frameCount: frames,
    sampleRate: 48000,
  );
  for (var i = 0; i < frames; i++) {
    buffer.channels[0][i] = math.sin(2 * math.pi * i / 100);
  }
  return buffer;
}

void main() {
  group('WaveformPeaks', () {
    test('reduces audio to one bucket per group of frames', () {
      final peaks = WaveformPeaks.fromBuffer(ramp(1000), framesPerBucket: 100);

      expect(peaks.bucketCount, 10);
      expect(peaks.frameCount, 1000);
      expect(peaks.maximums[0], greaterThan(0.9));
      expect(peaks.minimums[0], lessThan(-0.9));
    });

    test('keeps a trailing partial bucket', () {
      final peaks = WaveformPeaks.fromBuffer(ramp(250), framesPerBucket: 100);

      expect(peaks.bucketCount, 3);
    });

    test('survives an encode and decode', () {
      final peaks = WaveformPeaks.fromBuffer(ramp(5000));

      final restored = WaveformPeaks.decode(peaks.encode());

      expect(restored, isNotNull);
      expect(restored!.bucketCount, peaks.bucketCount);
      expect(restored.sampleRate, peaks.sampleRate);
      expect(restored.frameCount, peaks.frameCount);
      expect(restored.framesPerBucket, peaks.framesPerBucket);
      for (var i = 0; i < peaks.bucketCount; i++) {
        expect(restored.maximums[i], closeTo(peaks.maximums[i], 1e-6));
        expect(restored.minimums[i], closeTo(peaks.minimums[i], 1e-6));
      }
    });

    test('rejects bytes that are not a peaks file', () {
      expect(WaveformPeaks.decode(Uint8List.fromList(List.filled(64, 3))), isNull);
      expect(WaveformPeaks.decode(Uint8List(4)), isNull);
    });

    test('produces exactly one column per pixel asked for', () {
      final peaks = WaveformPeaks.fromBuffer(ramp(48000));

      final envelope =
          peaks.envelopeFor(columns: 320, startFrame: 0, endFrame: 48000);

      expect(envelope.length, 320);
      expect(envelope.highs.any((value) => value > 0.5), isTrue);
    });

    test('zooming into a range only shows that range', () {
      final buffer = AudioBuffer.silence(
        channelCount: 1,
        frameCount: 10000,
        sampleRate: 48000,
      );
      // Sound only in the second half.
      for (var i = 5000; i < 10000; i++) {
        buffer.channels[0][i] = 0.8;
      }
      final peaks = WaveformPeaks.fromBuffer(buffer, framesPerBucket: 100);

      final quiet =
          peaks.envelopeFor(columns: 20, startFrame: 0, endFrame: 4000);
      final loud =
          peaks.envelopeFor(columns: 20, startFrame: 6000, endFrame: 9000);

      expect(quiet.highs.every((value) => value < 0.01), isTrue);
      expect(loud.highs.every((value) => value > 0.7), isTrue);
    });

    test('an empty envelope draws nothing rather than crashing', () {
      final envelope = WaveformPeaks.empty
          .envelopeFor(columns: 100, startFrame: 0, endFrame: 1000);

      expect(envelope.length, 100);
      expect(envelope.highs.every((value) => value == 0), isTrue);
    });
  });

  group('WaveformPeaksBuilder', () {
    test('matches the one-shot result when fed in blocks', () {
      final buffer = ramp(4321);
      final expected = WaveformPeaks.fromBuffer(buffer, framesPerBucket: 256);

      final builder =
          WaveformPeaksBuilder(sampleRate: 48000, framesPerBucket: 256);
      var offset = 0;
      // Deliberately uneven blocks, so bucket boundaries fall inside them.
      for (final size in [100, 1000, 37, 2048, 1136]) {
        builder.add(buffer.slice(offset, math.min(size, 4321 - offset)));
        offset += size;
        if (offset >= 4321) break;
      }
      final built = builder.build();

      expect(built.bucketCount, expected.bucketCount);
      expect(built.frameCount, expected.frameCount);
      for (var i = 0; i < expected.bucketCount; i++) {
        expect(built.maximums[i], closeTo(expected.maximums[i], 1e-6),
            reason: 'bucket $i');
        expect(built.minimums[i], closeTo(expected.minimums[i], 1e-6),
            reason: 'bucket $i');
      }
    });
  });
}
