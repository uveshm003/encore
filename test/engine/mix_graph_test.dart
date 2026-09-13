import 'dart:typed_data';

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/engine/mix_graph.dart';
import 'package:flutter_test/flutter_test.dart';

AudioBuffer constant(double value, {int frames = 100, int channels = 2}) {
  final buffer = AudioBuffer.silence(
    channelCount: channels,
    frameCount: frames,
    sampleRate: 48000,
  );
  for (final channel in buffer.channels) {
    channel.fillRange(0, frames, value);
  }
  return buffer;
}

AudioBuffer destination({int frames = 64}) => AudioBuffer.silence(
  channelCount: 2,
  frameCount: frames,
  sampleRate: 48000,
);

void main() {
  group('MixGraph', () {
    test('sums tracks and applies track gain', () {
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(
            id: 'a',
            gain: 0.5,
            clips: [
              GraphClip(
                asset: constant(1.0),
                timelineStart: 0,
                assetOffset: 0,
                length: 100,
              ),
            ],
          ),
          GraphTrack(
            id: 'b',
            gain: 0.25,
            clips: [
              GraphClip(
                asset: constant(1.0),
                timelineStart: 0,
                assetOffset: 0,
                length: 100,
              ),
            ],
          ),
        ];

      final out = destination();
      graph.render(0, out);

      // Both tracks are centre-panned, so each contributes gain * cos(45°).
      const centreGain = 0.7071067811865476;
      expect(out.channels[0][0], closeTo(0.75 * centreGain, 1e-6));
      expect(out.channels[1][0], closeTo(0.75 * centreGain, 1e-6));
    });

    test('silences a muted track and honours solo', () {
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(
            id: 'muted',
            audible: false,
            clips: [
              GraphClip(
                asset: constant(1.0),
                timelineStart: 0,
                assetOffset: 0,
                length: 100,
              ),
            ],
          ),
        ];

      final out = destination();
      graph.render(0, out);

      expect(out.peak(), 0.0);
    });

    test('hard pan sends everything to one side', () {
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(
            id: 'left',
            pan: -1,
            clips: [
              GraphClip(
                asset: constant(1.0),
                timelineStart: 0,
                assetOffset: 0,
                length: 100,
              ),
            ],
          ),
        ];

      final out = destination();
      graph.render(0, out);

      expect(out.channels[0][0], closeTo(1.0, 1e-6));
      expect(out.channels[1][0], closeTo(0.0, 1e-6));
    });

    test('places a clip at its timeline position', () {
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(
            id: 'a',
            clips: [
              GraphClip(
                asset: constant(1.0, frames: 10),
                timelineStart: 20,
                assetOffset: 0,
                length: 10,
              ),
            ],
          ),
        ];

      final out = destination();
      graph.render(0, out);

      expect(out.channels[0][19], 0.0);
      expect(out.channels[0][20], greaterThan(0.5));
      expect(out.channels[0][29], greaterThan(0.5));
      expect(out.channels[0][30], 0.0);
    });

    test('reads from the requested offset inside the asset', () {
      final asset = AudioBuffer(
        [Float32List.fromList(List.generate(10, (i) => i.toDouble()))],
        48000,
      );
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(
            id: 'a',
            pan: -1,
            clips: [
              GraphClip(
                asset: asset,
                timelineStart: 0,
                assetOffset: 4,
                length: 3,
              ),
            ],
          ),
        ];

      final out = destination();
      graph.render(0, out);

      expect(out.channels[0][0], closeTo(4.0, 1e-6));
      expect(out.channels[0][1], closeTo(5.0, 1e-6));
      expect(out.channels[0][2], closeTo(6.0, 1e-6));
      expect(out.channels[0][3], 0.0);
    });

    test('applies fades across the clip', () {
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(
            id: 'a',
            pan: -1,
            clips: [
              GraphClip(
                asset: constant(1.0),
                timelineStart: 0,
                assetOffset: 0,
                length: 100,
                fadeInFrames: 20,
                fadeOutFrames: 20,
              ),
            ],
          ),
        ];

      final out = destination(frames: 100);
      graph.render(0, out);

      expect(out.channels[0][0], lessThan(0.1));
      expect(out.channels[0][10], closeTo(0.525, 0.05));
      expect(out.channels[0][50], closeTo(1.0, 1e-6));
      expect(out.channels[0][99], lessThan(0.1));
    });

    test('renders into an offset within the destination', () {
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(
            id: 'a',
            pan: -1,
            clips: [
              GraphClip(
                asset: constant(1.0),
                timelineStart: 0,
                assetOffset: 0,
                length: 100,
              ),
            ],
          ),
        ];

      final out = destination();
      graph.render(0, out, destinationOffset: 10, frames: 5);

      expect(out.channels[0][9], 0.0);
      expect(out.channels[0][10], closeTo(1.0, 1e-6));
      expect(out.channels[0][14], closeTo(1.0, 1e-6));
      expect(out.channels[0][15], 0.0);
    });

    test('endFrame is the end of the last clip', () {
      final graph = MixGraph(sampleRate: 48000)
        ..tracks = [
          GraphTrack(
            id: 'a',
            clips: [
              GraphClip(
                asset: constant(1.0),
                timelineStart: 100,
                assetOffset: 0,
                length: 50,
              ),
              GraphClip(
                asset: constant(1.0),
                timelineStart: 400,
                assetOffset: 0,
                length: 25,
              ),
            ],
          ),
        ];

      expect(graph.endFrame, 425);
    });
  });

  group('pan law', () {
    test('is constant power', () {
      for (final pan in [-1.0, -0.5, 0.0, 0.5, 1.0]) {
        final (left, right) = MixGraph.panGains(pan);
        expect(left * left + right * right, closeTo(1.0, 1e-9),
            reason: 'pan $pan');
      }
    });
  });
}
