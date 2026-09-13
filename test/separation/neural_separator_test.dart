import 'dart:math' as math;
import 'dart:typed_data';

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/separation/inference_backend.dart';
import 'package:encore/separation/neural_separator.dart';
import 'package:encore/separation/spectral_separator.dart';
import 'package:encore/separation/stem_kind.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for a real model.
///
/// [split] decides how each window is divided between the outputs, so a test
/// can make a model that is perfect, that is lopsided, or that returns the
/// input untouched — without needing a runtime or a weights file.
class FakeSession implements InferenceSession {
  FakeSession({
    required this.split,
    this.windowFrames = 1024,
    this.overlapFrames = 256,
    this.sampleRate = 48000,
  });

  /// One gain per output stem, applied to the window.
  final List<double> split;

  @override
  final int windowFrames;

  @override
  final int overlapFrames;

  @override
  final int sampleRate;

  int runs = 0;
  bool closed = false;

  @override
  Future<List<List<Float32List>>> run(List<Float32List> input) async {
    runs++;
    return [
      for (final gain in split)
        [
          for (final channel in input)
            Float32List.fromList([for (final sample in channel) sample * gain]),
        ],
    ];
  }

  @override
  Future<void> close() async => closed = true;
}

AudioBuffer tone({
  int frames = 8000,
  int channels = 2,
  int sampleRate = 48000,
  double frequency = 220,
}) {
  final buffer = AudioBuffer.silence(
    channelCount: channels,
    frameCount: frames,
    sampleRate: sampleRate,
  );
  for (var channel = 0; channel < channels; channel++) {
    for (var i = 0; i < frames; i++) {
      buffer.channels[channel][i] =
          math.sin(2 * math.pi * frequency * i / sampleRate) * 0.5;
    }
  }
  return buffer;
}

double peakOf(AudioBuffer buffer) {
  var peak = 0.0;
  for (final channel in buffer.channels) {
    for (final sample in channel) {
      peak = math.max(peak, sample.abs());
    }
  }
  return peak;
}

void main() {
  group('NeuralSeparator', () {
    test('splits a track into the stems the model declares', () async {
      // A model that puts a quarter of the signal in each of four stems.
      final session = FakeSession(split: const [0.25, 0.25, 0.25, 0.25]);
      final subject = NeuralSeparator(
        session: session,
        outputOrder: const [
          StemKind.drums,
          StemKind.bass,
          StemKind.other,
          StemKind.vocals,
        ],
      );
      final result = await subject.separate(tone(), StemKind.fourStem);

      expect(result.stems.keys, containsAll(StemKind.fourStem));
      for (final kind in StemKind.fourStem) {
        expect(result[kind]!.frameCount, 8000);
        expect(peakOf(result[kind]!), greaterThan(0));
      }
    });

    test('reconstructs the input when the stems sum to it', () async {
      // Half and half: adding the two outputs back together must return the
      // original, which is the property that proves the overlap-add and its
      // crossfade normalisation are right.
      final session = FakeSession(split: const [0.5, 0.5]);
      final subject = NeuralSeparator(
        session: session,
        outputOrder: const [StemKind.vocals, StemKind.other],
      );
      final input = tone();
      final result = await subject.separate(input, const {
        StemKind.vocals,
        StemKind.other,
      });

      final vocals = result[StemKind.vocals]!;
      final other = result[StemKind.other]!;
      for (var i = 0; i < input.frameCount; i++) {
        expect(
          vocals.channels[0][i] + other.channels[0][i],
          closeTo(input.channels[0][i], 1e-4),
          reason: 'frame $i should reconstruct',
        );
      }
    });

    test('the crossfade leaves no seam at a window join', () async {
      // A model that returns its input unchanged: any discontinuity in the
      // output is the separator's own doing, not the model's.
      final session = FakeSession(
        split: const [1.0],
        windowFrames: 1024,
        overlapFrames: 256,
      );
      final subject = NeuralSeparator(
        session: session,
        outputOrder: const [StemKind.vocals],
      );
      final input = tone(frames: 6000);
      final result = await subject.separate(input, const {StemKind.vocals});
      final output = result[StemKind.vocals]!;

      // Identity in, identity out — everywhere, joins included.
      for (var i = 0; i < input.frameCount; i++) {
        expect(
          output.channels[0][i],
          closeTo(input.channels[0][i], 1e-4),
          reason: 'frame $i sits on or near a window join',
        );
      }
      expect(session.runs, greaterThan(1), reason: 'must take several windows');
    });

    test('derives the instrumental as the mix minus the vocal', () async {
      final session = FakeSession(split: const [0.3]);
      final subject = NeuralSeparator(
        session: session,
        outputOrder: const [StemKind.vocals],
      );
      final input = tone();
      final result = await subject.separate(input, StemKind.twoStem);

      final vocals = result[StemKind.vocals]!;
      final instrumental = result[StemKind.instrumental]!;
      for (var i = 0; i < input.frameCount; i += 97) {
        expect(
          vocals.channels[0][i] + instrumental.channels[0][i],
          closeTo(input.channels[0][i], 1e-4),
          reason: 'the two stems must add back up to the mix',
        );
      }
    });

    test('converts to the model rate and back again', () async {
      // The model wants 44.1 kHz; the app is at 48 kHz. The caller should
      // never see the model's rate.
      final session = FakeSession(split: const [1.0], sampleRate: 44100);
      final subject = NeuralSeparator(
        session: session,
        outputOrder: const [StemKind.vocals],
      );
      final input = tone(frames: 4800, sampleRate: 48000);
      final result = await subject.separate(input, const {StemKind.vocals});

      expect(result[StemKind.vocals]!.sampleRate, 48000);
      expect(result[StemKind.vocals]!.frameCount, 4800);
    });

    test('reports progress and reaches 1', () async {
      final session = FakeSession(split: const [1.0]);
      final subject = NeuralSeparator(
        session: session,
        outputOrder: const [StemKind.vocals],
      );
      final reported = <double>[];
      await subject.separate(tone(), const {
        StemKind.vocals,
      }, onProgress: reported.add);

      expect(reported, isNotEmpty);
      expect(reported.last, closeTo(1, 1e-9));
      expect(reported, orderedEquals(List.of(reported)..sort()));
    });

    test('cancels between windows', () async {
      final session = FakeSession(split: const [1.0]);
      final subject = NeuralSeparator(
        session: session,
        outputOrder: const [StemKind.vocals],
      );
      var calls = 0;
      await expectLater(
        subject.separate(tone(frames: 40000), const {
          StemKind.vocals,
        }, isCancelled: () => ++calls > 2),
        throwsA(isA<SeparationCancelled>()),
      );
      // It stopped early rather than running the whole track.
      expect(session.runs, lessThan(10));
    });

    test('an empty track produces empty stems', () async {
      final session = FakeSession(split: const [1.0]);
      final subject = NeuralSeparator(
        session: session,
        outputOrder: const [StemKind.vocals],
      );
      final empty = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 0,
        sampleRate: 48000,
      );
      final result = await subject.separate(empty, StemKind.twoStem);

      expect(result[StemKind.vocals]!.frameCount, 0);
      expect(result[StemKind.instrumental]!.frameCount, 0);
      expect(session.runs, 0);
    });

    test(
      'a stem the model cannot make comes back silent, not missing',
      () async {
        final session = FakeSession(split: const [1.0]);
        final subject = NeuralSeparator(
          session: session,
          outputOrder: const [StemKind.vocals],
        );
        final result = await subject.separate(tone(), const {StemKind.drums});

        expect(result[StemKind.drums], isNotNull);
        expect(peakOf(result[StemKind.drums]!), 0);
      },
    );

    test('a mono source stays mono', () async {
      final session = FakeSession(split: const [1.0]);
      final subject = NeuralSeparator(
        session: session,
        outputOrder: const [StemKind.vocals],
      );
      final result = await subject.separate(tone(channels: 1), const {
        StemKind.vocals,
      });

      expect(result[StemKind.vocals]!.channelCount, 1);
    });
  });
}
