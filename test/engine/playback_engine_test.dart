import 'package:encore/core/audio_buffer.dart';
import 'package:encore/engine/audio_output.dart';
import 'package:encore/engine/engine_config.dart';
import 'package:encore/engine/latency.dart';
import 'package:encore/engine/mix_graph.dart';
import 'package:encore/engine/playback_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const config = EngineConfig(
  sampleRate: 48000,
  channelCount: 2,
  blockFrames: 512,
  bufferedBlocks: 2,
);

AudioBuffer tone(double value, int frames) {
  final buffer = AudioBuffer.silence(
    channelCount: 2,
    frameCount: frames,
    sampleRate: config.sampleRate,
  );
  for (final channel in buffer.channels) {
    channel.fillRange(0, frames, value);
  }
  return buffer;
}

List<GraphTrack> singleTrack({int length = 48000, double level = 0.5}) => [
  GraphTrack(
    id: 'backing',
    clips: [
      GraphClip(
        asset: tone(level, length),
        timelineStart: 0,
        assetOffset: 0,
        length: length,
      ),
    ],
  ),
];

void main() {
  late NullAudioOutput output;
  late FakeAudioInput input;
  late PlaybackEngine engine;

  setUp(() async {
    output = NullAudioOutput();
    input = FakeAudioInput();
    engine = PlaybackEngine(config: config, output: output, input: input);
    await engine.start();
  });

  tearDown(() async {
    await engine.shutdown();
  });

  group('transport', () {
    test('produces silence until play is pressed', () {
      engine.setGraph(singleTrack());

      final blocks = output.pump(2);

      expect(blocks.first.peak(), 0.0);
      expect(engine.transport.value.isPlaying, isFalse);
    });

    test('plays and advances the position', () {
      engine.setGraph(singleTrack());
      engine.play();

      final blocks = output.pump(4);

      expect(blocks.last.peak(), greaterThan(0.1));
      // The reported position trails the render position by the output queue.
      expect(
        engine.transport.value.positionFrames,
        4 * config.blockFrames - config.outputBufferFrames,
      );
    });

    test('seek moves the playhead', () {
      engine.setGraph(singleTrack());
      engine.seek(24000);
      engine.play();
      output.pump(1);

      expect(
        engine.transport.value.positionFrames,
        24000 + config.blockFrames - config.outputBufferFrames,
      );
    });

    test('stop returns to the start', () {
      engine.setGraph(singleTrack());
      engine.play();
      output.pump(3);
      engine.stop();

      expect(engine.transport.value.isPlaying, isFalse);
      expect(engine.transport.value.positionFrames, 0);
    });

    test('stops on its own at the end of the material', () {
      engine.setGraph(singleTrack(length: 600));
      engine.play();

      output.pump(4);

      expect(engine.transport.value.isPlaying, isFalse);
    });

    test('loops back to the region start', () {
      engine.setGraph(singleTrack());
      engine.setLoop(enabled: true, start: 0, end: 700);
      engine.play();

      output.pump(3);

      // 1536 frames rendered over a 700-frame loop wraps to 136.
      expect(engine.transport.value.isPlaying, isTrue);
      expect(engine.transport.value.positionFrames, lessThan(700));
    });
  });

  group('mixing', () {
    test('applies master gain', () {
      engine.setGraph(singleTrack(level: 0.4));
      engine.setMaster(gain: 0.5, limiterEnabled: false);
      engine.play();

      final blocks = output.pump(2);

      // 0.4 through the centre pan law, halved by the master fader.
      expect(blocks.last.channels[0][0], closeTo(0.4 * 0.70710678 * 0.5, 1e-4));
    });

    test('the master limiter holds the output below the ceiling', () {
      engine.setGraph(singleTrack(level: 4.0));
      engine.setMaster(limiterEnabled: true, ceilingDb: -1.0);
      engine.play();

      final blocks = output.pump(8);

      expect(blocks.last.peak(), lessThanOrEqualTo(0.9));
    });

    test('reports the output level', () {
      engine.setGraph(singleTrack(level: 0.5));
      engine.play();
      output.pump(3);

      expect(engine.outputLevel.value.peakDb, greaterThan(-20));
    });
  });

  group('recording', () {
    test('captures audio and compensates for latency', () async {
      engine.latency = const LatencySettings(
        outputFrames: 480,
        inputFrames: 240,
      );
      engine.setGraph(singleTrack());
      engine.seek(10000);
      await engine.startRecording();

      // Render two blocks, then let the first capture block arrive: the take
      // belongs 720 frames earlier than the position it was received at.
      output.pump(2);
      final anchor = 10000 + 2 * config.blockFrames;
      await input.emit(FakeAudioInput.block(0.3, frames: 1024));
      output.pump(1);

      final take = await engine.stopRecording();

      expect(take, isNotNull);
      expect(take!.compensationFrames, 720);
      expect(take.timelineStart, anchor - 720);
      expect(take.audio.frameCount, 1024);
      expect(take.audio.peak(), closeTo(0.3, 1e-3));
    });

    test('joins several capture blocks into one take', () async {
      engine.latency = const LatencySettings();
      engine.setGraph(singleTrack());
      await engine.startRecording();

      output.pump(1);
      await input.emit(FakeAudioInput.block(0.2, frames: 512));
      await input.emit(FakeAudioInput.block(0.4, frames: 512));
      output.pump(1);

      final take = await engine.stopRecording();

      expect(take!.audio.frameCount, 1024);
      expect(take.audio.channels[0][0], closeTo(0.2, 1e-3));
      expect(take.audio.channels[0][600], closeTo(0.4, 1e-3));
    });

    test('drops the count-in from the front of a take', () async {
      engine.latency = const LatencySettings();
      engine.setMetronome(enabled: true, tempoBpm: 120, beatsPerBar: 4);
      engine.setGraph(singleTrack());
      engine.seek(96000);

      // One bar at 120 bpm is two seconds, so the transport starts 96000
      // frames early and the first second of capture is count-in.
      await engine.startRecording(countInBars: 1);
      expect(engine.transport.value.isRecording, isTrue);

      output.pump(1);
      await input.emit(FakeAudioInput.block(0.5, frames: 192000));
      final take = await engine.stopRecording();

      expect(take, isNotNull);
      expect(take!.timelineStart, 96000);
      // Everything captured before the punch-in point is discarded.
      expect(take.audio.frameCount, lessThan(192000));
    });

    test('reports the input level while capturing', () async {
      await engine.startRecording();
      output.pump(1);
      await input.emit(FakeAudioInput.block(0.5));

      expect(engine.inputLevel.value.peakDb, greaterThan(-12));
      await engine.stopRecording();
    });

    test('returns nothing when no audio arrived', () async {
      await engine.startRecording();
      output.pump(1);

      expect(await engine.stopRecording(), isNull);
    });

    test('passes the chosen input device through', () async {
      await engine.startRecording(deviceId: 'built-in');
      expect(input.lastDeviceId, 'built-in');
      await engine.stopRecording();
      expect(input.stopCount, greaterThan(0));
    });
  });
}
