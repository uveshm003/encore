import 'dart:math' as math;

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/engine/engine_config.dart';
import 'package:encore/engine/mix_graph.dart';
import 'package:encore/engine/playback_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Plays through the real output device and checks that it keeps going.
///
/// NFR-PERF-04 asks for glitch-free multi-track playback. A stall shows up as
/// the transport position falling behind wall-clock time, which is what this
/// measures.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const config = EngineConfig();

  AudioBuffer tone(double frequency, int frames) {
    final buffer = AudioBuffer.silence(
      channelCount: 2,
      frameCount: frames,
      sampleRate: config.sampleRate,
    );
    for (var ch = 0; ch < 2; ch++) {
      for (var i = 0; i < frames; i++) {
        buffer.channels[ch][i] =
            math.sin(2 * math.pi * frequency * i / config.sampleRate) * 0.2;
      }
    }
    return buffer;
  }

  testWidgets('playback keeps up with the clock for several seconds',
      (tester) async {
    final engine = PlaybackEngine(config: config);
    await engine.start();
    addTearDown(engine.shutdown);

    const seconds = 4;
    final frames = config.sampleRate * 20;
    engine.setGraph([
      GraphTrack(
        id: 'a',
        clips: [
          GraphClip(
            asset: tone(220, frames),
            timelineStart: 0,
            assetOffset: 0,
            length: frames,
          ),
        ],
      ),
      GraphTrack(
        id: 'b',
        gain: 0.6,
        pan: 0.4,
        clips: [
          GraphClip(
            asset: tone(330, frames),
            timelineStart: 0,
            assetOffset: 0,
            length: frames,
          ),
        ],
      ),
    ]);

    final started = DateTime.now();
    engine.play();

    // Sample the position as it runs, so a stall in the middle is caught even
    // if it recovers before the end.
    final samples = <(Duration, int)>[];
    for (var i = 0; i < seconds * 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      samples.add((
        DateTime.now().difference(started),
        engine.transport.value.positionFrames,
      ));
    }
    engine.stop();

    for (final (elapsed, position) in samples) {
      final expected = elapsed.inMilliseconds * config.sampleRate ~/ 1000;
      final drift = (position - expected).abs();
      // Half a second of slack covers scheduling jitter on a busy machine;
      // a stalled output device drifts much further than that.
      expect(
        drift,
        lessThan(config.sampleRate ~/ 2),
        reason: 'at ${elapsed.inMilliseconds} ms the playhead was at '
            '$position, expected about $expected',
      );
    }
    expect(engine.outputLevel.value.peakDb, greaterThan(-40));
  });

  testWidgets('the output survives repeated start and stop', (tester) async {
    final engine = PlaybackEngine(config: config);
    await engine.start();
    addTearDown(engine.shutdown);

    final frames = config.sampleRate * 5;
    engine.setGraph([
      GraphTrack(
        id: 'a',
        clips: [
          GraphClip(
            asset: tone(440, frames),
            timelineStart: 0,
            assetOffset: 0,
            length: frames,
          ),
        ],
      ),
    ]);

    for (var cycle = 0; cycle < 4; cycle++) {
      engine.seek(0);
      engine.play();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final position = engine.transport.value.positionFrames;
      expect(
        position,
        greaterThan(config.sampleRate ~/ 8),
        reason: 'cycle $cycle did not advance',
      );
      engine.pause();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  });
}
