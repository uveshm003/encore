import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/io/codec/codec_exception.dart';
import 'package:encore/io/codec/wav_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('encore-wav-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  AudioBuffer sampleBuffer({int channels = 2, int frames = 5000}) {
    final buffer = AudioBuffer.silence(
      channelCount: channels,
      frameCount: frames,
      sampleRate: 48000,
    );
    for (var ch = 0; ch < channels; ch++) {
      for (var i = 0; i < frames; i++) {
        buffer.channels[ch][i] =
            math.sin(2 * math.pi * (220 + ch * 110) * i / 48000) * 0.8;
      }
    }
    return buffer;
  }

  group('WavCodec', () {
    test('round-trips 32-bit float exactly', () async {
      final path = '${temporary.path}/float.wav';
      final original = sampleBuffer();

      await WavCodec.write(path, original, depth: WavBitDepth.float32);
      final restored = await WavCodec.read(path);

      expect(restored.sampleRate, 48000);
      expect(restored.channelCount, 2);
      expect(restored.frameCount, original.frameCount);
      for (var ch = 0; ch < 2; ch++) {
        for (var i = 0; i < original.frameCount; i += 97) {
          expect(restored.channels[ch][i],
              closeTo(original.channels[ch][i], 1e-7));
        }
      }
    });

    test('round-trips 16-bit within quantisation error', () async {
      final path = '${temporary.path}/pcm16.wav';
      final original = sampleBuffer(channels: 1, frames: 2000);

      await WavCodec.write(path, original, depth: WavBitDepth.pcm16);
      final restored = await WavCodec.read(path);

      for (var i = 0; i < original.frameCount; i += 17) {
        expect(restored.channels[0][i],
            closeTo(original.channels[0][i], 1 / 32768));
      }
    });

    test('round-trips 24-bit within quantisation error', () async {
      final path = '${temporary.path}/pcm24.wav';
      final original = sampleBuffer(channels: 2, frames: 1500);

      await WavCodec.write(path, original, depth: WavBitDepth.pcm24);
      final restored = await WavCodec.read(path);

      expect(restored.frameCount, original.frameCount);
      for (var i = 0; i < original.frameCount; i += 31) {
        expect(restored.channels[1][i],
            closeTo(original.channels[1][i], 1 / 8388608 * 2));
      }
    });

    test('readInfo reports the header without decoding', () async {
      final path = '${temporary.path}/info.wav';
      await WavCodec.write(path, sampleBuffer(frames: 48000));

      final info = await WavCodec.readInfo(path);

      expect(info.sampleRate, 48000);
      expect(info.channelCount, 2);
      expect(info.frameCount, 48000);
      expect(info.isFloat, isTrue);
      expect(info.duration.inSeconds, 1);
    });

    test('streams blocks that reassemble into the whole file', () async {
      final path = '${temporary.path}/blocks.wav';
      final original = sampleBuffer(channels: 1, frames: 10000);
      await WavCodec.write(path, original);

      var frames = 0;
      var firstSample = 0.0;
      await for (final block in WavCodec.readBlocks(path, framesPerBlock: 1024)) {
        if (frames == 0) firstSample = block.channels[0][0];
        frames += block.frameCount;
      }

      expect(frames, original.frameCount);
      expect(firstSample, closeTo(original.channels[0][0], 1e-7));
    });

    test('reports a missing file rather than throwing a raw IO error', () async {
      await expectLater(
        WavCodec.read('${temporary.path}/nope.wav'),
        throwsA(isA<CodecException>().having(
          (error) => error.kind,
          'kind',
          CodecErrorKind.notFound,
        )),
      );
    });

    test('rejects a file that is not WAV', () async {
      final path = '${temporary.path}/not-audio.wav';
      await File(path).writeAsBytes(Uint8List.fromList(List.filled(200, 7)));

      await expectLater(
        WavCodec.readInfo(path),
        throwsA(isA<CodecException>().having(
          (error) => error.kind,
          'kind',
          CodecErrorKind.unsupportedFormat,
        )),
      );
    });

    test('reads a data chunk whose declared size overruns the file', () async {
      // Some encoders write a placeholder length for streamed output; the
      // reader should fall back to the real file length instead of failing.
      final path = '${temporary.path}/overrun.wav';
      final original = sampleBuffer(channels: 1, frames: 1000);
      await WavCodec.write(path, original, depth: WavBitDepth.pcm16);

      final bytes = await File(path).readAsBytes();
      ByteData.sublistView(bytes).setUint32(40, 0xFFFFFFF0, Endian.little);
      await File(path).writeAsBytes(bytes);

      final restored = await WavCodec.read(path);
      expect(restored.frameCount, 1000);
    });
  });
}
