import 'dart:typed_data';

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/engine/latency.dart';
import 'package:encore/engine/metronome.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Metronome', () {
    test('is silent when disabled', () {
      final metronome = Metronome(sampleRate: 48000)..enabled = false;
      final block = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 48000,
        sampleRate: 48000,
      );

      metronome.render(0, block);

      expect(block.peak(), 0.0);
    });

    test('places a click on every beat', () {
      final metronome = Metronome(sampleRate: 48000, tempoBpm: 120)
        ..enabled = true;
      final block = AudioBuffer.silence(
        channelCount: 1,
        frameCount: 48000,
        sampleRate: 48000,
      );

      metronome.render(0, block);

      // 120 bpm at 48 kHz is a beat every 24000 frames.
      expect(metronome.framesPerBeat, 24000);
      expect(block.channels[0][10].abs(), greaterThan(0.01));
      expect(block.channels[0][12000].abs(), lessThan(1e-6));
      expect(block.channels[0][24010].abs(), greaterThan(0.01));
    });

    test('accents the first beat of the bar', () {
      final metronome = Metronome(sampleRate: 48000, tempoBpm: 120)
        ..enabled = true
        ..beatsPerBar = 4;
      final block = AudioBuffer.silence(
        channelCount: 1,
        frameCount: 48000 * 3,
        sampleRate: 48000,
      );

      metronome.render(0, block);

      // The downbeat and the beat one bar later use the accent click; the
      // beats in between use the plain one, so they differ.
      final downbeat = block.channels[0].sublist(0, 1600);
      final offbeat = block.channels[0].sublist(24000, 25600);
      expect(downbeat, isNot(equals(offbeat)));
    });

    test('clicks at negative positions, which is what a count-in is', () {
      final metronome = Metronome(sampleRate: 48000, tempoBpm: 120)
        ..enabled = true;
      final block = AudioBuffer.silence(
        channelCount: 1,
        frameCount: 48000,
        sampleRate: 48000,
      );

      metronome.render(-48000, block);

      expect(block.peak(), greaterThan(0.01));
    });

    test('reports the length of a count-in', () {
      final metronome = Metronome(sampleRate: 48000, tempoBpm: 120)
        ..beatsPerBar = 4;

      // Four beats of 24000 frames.
      expect(metronome.countInFrames(1), 96000);
      expect(metronome.countInFrames(2), 192000);
      expect(metronome.countInFrames(0), 0);
    });
  });

  group('LatencyCalibrator', () {
    test('recovers a delay it was given', () {
      const calibrator = LatencyCalibrator(sampleRate: 48000);
      final probe = calibrator.buildProbe();
      const delay = 3200;

      // Build a "recording" that is silence, then the probe, then silence.
      final recorded = List<double>.filled(delay + probe.length + 8000, 0.0);
      for (var i = 0; i < probe.length; i++) {
        recorded[delay + i] = probe[i] * 0.4;
      }

      final measurement = calibrator.measure(
        probe: probe,
        recorded: float32(recorded),
      );

      expect(measurement.roundTripFrames, closeTo(delay, 2));
      expect(measurement.isReliable, isTrue);
    });

    test('accounts for a recording that began before the probe', () {
      const calibrator = LatencyCalibrator(sampleRate: 48000);
      final probe = calibrator.buildProbe();
      const delay = 1500;
      const headStart = 900;

      final recorded = List<double>.filled(delay + probe.length + 4000, 0.0);
      for (var i = 0; i < probe.length; i++) {
        recorded[delay + i] = probe[i] * 0.5;
      }

      final measurement = calibrator.measure(
        probe: probe,
        recorded: float32(recorded),
        recordingStartFrame: headStart,
      );

      expect(measurement.roundTripFrames, closeTo(delay + headStart, 2));
    });

    test('is not confident when the probe was never heard', () {
      const calibrator = LatencyCalibrator(sampleRate: 48000);
      final probe = calibrator.buildProbe();
      final silence = float32(List<double>.filled(20000, 0.0));

      final measurement = calibrator.measure(probe: probe, recorded: silence);

      expect(measurement.isReliable, isFalse);
    });
  });
}

/// Builds a Float32List from doubles, so the tests read as plain lists.
Float32List float32(List<double> values) => Float32List.fromList(values);
