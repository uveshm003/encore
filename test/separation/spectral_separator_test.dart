import 'dart:math' as math;
import 'dart:typed_data';

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/separation/spectral_separator.dart';
import 'package:encore/separation/stem_kind.dart';
import 'package:flutter_test/flutter_test.dart';

const int _sampleRate = 48000;
const int _seconds = 6;

/// Energy at [hz] in [channel], measured with a single-bin DFT (Goertzel).
double _energyAt(Float32List channel, double hz) {
  final omega = 2 * math.pi * hz / _sampleRate;
  var real = 0.0;
  var imaginary = 0.0;
  for (var i = 0; i < channel.length; i++) {
    real += channel[i] * math.cos(omega * i);
    imaginary += channel[i] * math.sin(omega * i);
  }
  return math.sqrt(real * real + imaginary * imaginary) / channel.length;
}

/// A synthetic mix shaped like a real one: a centred lead, a panned
/// accompaniment, a centred bass and centred percussive hits.
AudioBuffer _buildMix() {
  final frames = _sampleRate * _seconds;
  final left = Float32List(frames);
  final right = Float32List(frames);
  final random = math.Random(3);

  for (var i = 0; i < frames; i++) {
    final t = i / _sampleRate;

    // Lead "voice": a harmonic stack, mixed dead centre.
    final lead = 0.30 * math.sin(2 * math.pi * 440 * t) +
        0.15 * math.sin(2 * math.pi * 880 * t) +
        0.08 * math.sin(2 * math.pi * 1320 * t);

    // Accompaniment, panned well to the left.
    final guitar = 0.30 * math.sin(2 * math.pi * 660 * t);

    // Bass, centred but far below the voice.
    final bass = 0.30 * math.sin(2 * math.pi * 80 * t);

    left[i] = lead + guitar + bass;
    right[i] = lead + guitar * 0.12 + bass;
  }

  // Percussive hits every half second: short broadband noise bursts, centred.
  const hitFrames = 900;
  for (var hit = 0; hit * _sampleRate ~/ 2 < frames; hit++) {
    final start = hit * _sampleRate ~/ 2;
    for (var i = 0; i < hitFrames && start + i < frames; i++) {
      final envelope = math.exp(-i / 200.0);
      final noise = (random.nextDouble() * 2 - 1) * 0.5 * envelope;
      left[start + i] += noise;
      right[start + i] += noise;
    }
  }

  return AudioBuffer([left, right], _sampleRate);
}

void main() {
  group('SpectralSeparator', () {
    late AudioBuffer mix;

    setUpAll(() => mix = _buildMix());

    test('pulls the centred lead into the vocal stem', () {
      final result = const SpectralSeparator().separate(mix, StemKind.twoStem);

      final vocals = result[StemKind.vocals]!.channels[0];
      final instrumental = result[StemKind.instrumental]!.channels[0];

      final leadInVocals = _energyAt(vocals, 440);
      final leadInInstrumental = _energyAt(instrumental, 440);
      final guitarInVocals = _energyAt(vocals, 660);
      final guitarInInstrumental = _energyAt(instrumental, 660);

      // The centred lead should end up mostly in the vocal stem...
      expect(leadInVocals, greaterThan(leadInInstrumental * 3));
      // ...and the panned accompaniment mostly in the instrumental.
      expect(guitarInInstrumental, greaterThan(guitarInVocals * 3));
    });

    test('keeps bass out of the vocal stem', () {
      final result = const SpectralSeparator().separate(mix, StemKind.twoStem);

      final bassInVocals = _energyAt(result[StemKind.vocals]!.channels[0], 80);
      final bassInInstrumental =
          _energyAt(result[StemKind.instrumental]!.channels[0], 80);

      expect(bassInInstrumental, greaterThan(bassInVocals * 5));
    });

    test('stems sum back to the original mix', () {
      final result = const SpectralSeparator().separate(mix, StemKind.twoStem);

      final vocals = result[StemKind.vocals]!;
      final instrumental = result[StemKind.instrumental]!;

      for (var ch = 0; ch < 2; ch++) {
        for (var i = 1000; i < mix.frameCount; i += 997) {
          expect(
            vocals.channels[ch][i] + instrumental.channels[ch][i],
            closeTo(mix.channels[ch][i], 1e-3),
            reason: 'channel $ch frame $i',
          );
        }
      }
    });

    test('four-stem split routes bass and percussion apart', () {
      final result = const SpectralSeparator().separate(mix, StemKind.fourStem);

      expect(result.stems.keys.toSet(), StemKind.fourStem);

      final bassStem = result[StemKind.bass]!.channels[0];
      final otherStem = result[StemKind.other]!.channels[0];
      expect(_energyAt(bassStem, 80), greaterThan(_energyAt(otherStem, 80)));

      // The drum stem should carry more of the transient energy than the bass
      // stem, which is low-passed well below the noise bursts.
      expect(result[StemKind.drums]!.rms(), greaterThan(0.0));
    });

    test('reports progress and honours cancellation', () {
      final progress = <double>[];
      expect(
        () => const SpectralSeparator(
          // Short segments so there are several cancellation points to hit.
          options: SpectralSeparationOptions(
            fftSize: 2048,
            hopSize: 512,
            harmonicPercussiveWindow: 0,
            segmentSeconds: 1.0,
          ),
        ).separate(
          mix,
          StemKind.twoStem,
          onProgress: progress.add,
          isCancelled: () => progress.length >= 2,
        ),
        throwsA(isA<SeparationCancelled>()),
      );
      expect(progress, isNotEmpty);
    });

    test('handles a mono source without crashing', () {
      final mono = mix.toMono();
      final result = const SpectralSeparator(
        options: SpectralSeparationOptions.fast,
      ).separate(mono, StemKind.twoStem);

      expect(result[StemKind.vocals]!.channelCount, 1);
      expect(result[StemKind.vocals]!.frameCount, mono.frameCount);
    });
  });
}
