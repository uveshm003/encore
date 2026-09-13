import 'dart:io';
import 'dart:math' as math;

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/io/audio_file_format.dart';
import 'package:encore/io/codec/codec_registry.dart';
import 'package:encore/io/codec/wav_codec.dart';
import 'package:encore/io/codec/wav_transcoder.dart';
import 'package:encore/io/export_service.dart';
import 'package:encore/project/models/audio_asset.dart';
import 'package:encore/project/models/clip.dart';
import 'package:encore/project/models/mix_settings.dart';
import 'package:encore/project/models/project.dart';
import 'package:encore/project/models/track.dart';
import 'package:encore/storage/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';

AudioBuffer tone(double frequency, {int frames = 48000, double level = 0.4}) {
  final buffer = AudioBuffer.silence(
    channelCount: 2,
    frameCount: frames,
    sampleRate: 48000,
  );
  for (var ch = 0; ch < 2; ch++) {
    for (var i = 0; i < frames; i++) {
      buffer.channels[ch][i] =
          math.sin(2 * math.pi * frequency * i / 48000) * level;
    }
  }
  return buffer;
}

void main() {
  late Directory root;
  late AppPaths paths;
  late ExportService exporter;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('encore-export-');
    paths = AppPaths(root);
    await paths.ensureDirectories();
    // Only the built-in WAV backend, so the test does not depend on what
    // happens to be installed on the machine running it.
    final codecs = CodecRegistry([const WavTranscoder()]);
    await codecs.initialise();
    exporter = ExportService(codecs: codecs, paths: paths);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Project buildProject({double masterGain = 1.0, bool limiter = false}) {
    return Project(
      id: 'p',
      name: 'Mix test',
      sampleRate: 48000,
      createdAt: DateTime(2026),
      modifiedAt: DateTime(2026),
      mix: MixSettings(masterGain: masterGain, limiterEnabled: limiter),
      assets: const [
        AudioAsset(
          id: 'a',
          path: 'unused',
          origin: AssetOrigin.separated,
          sampleRate: 48000,
          channelCount: 2,
          frameCount: 48000,
        ),
        AudioAsset(
          id: 'b',
          path: 'unused',
          origin: AssetOrigin.recorded,
          sampleRate: 48000,
          channelCount: 2,
          frameCount: 48000,
        ),
      ],
      tracks: const [
        Track(
          id: 't1',
          name: 'Instrumental',
          kind: TrackKind.instrumental,
          clips: [
            Clip(
              id: 'c1',
              assetId: 'a',
              timelineStart: 0,
              assetOffset: 0,
              length: 48000,
            ),
          ],
        ),
        Track(
          id: 't2',
          name: 'My vocal',
          kind: TrackKind.recording,
          clips: [
            Clip(
              id: 'c2',
              assetId: 'b',
              timelineStart: 24000,
              assetOffset: 0,
              length: 24000,
            ),
          ],
        ),
      ],
    );
  }

  Map<String, AudioBuffer> buffers() => {
    'a': tone(220),
    'b': tone(880),
  };

  group('ExportService', () {
    test('writes a WAV of the whole project', () async {
      final destination = '${root.path}/mix.wav';

      final result = await exporter.exportMix(
        project: buildProject(),
        buffers: buffers(),
        settings: const ExportSettings(bitDepth: ExportBitDepth.pcm16),
        destinationPath: destination,
      );

      expect(await File(destination).exists(), isTrue);
      expect(result.sizeBytes, greaterThan(0));

      final written = await WavCodec.readInfo(destination);
      expect(written.sampleRate, 48000);
      expect(written.channelCount, 2);
      expect(written.frameCount, 48000);
      expect(written.bitsPerSample, 16);
    });

    test('the exported audio contains both tracks in the right places',
        () async {
      final destination = '${root.path}/placed.wav';

      await exporter.exportMix(
        project: buildProject(),
        buffers: buffers(),
        settings: const ExportSettings(bitDepth: ExportBitDepth.float32),
        destinationPath: destination,
      );
      final mixed = await WavCodec.read(destination);

      // The overdub starts halfway through, so the second half is louder.
      final firstHalf = mixed.slice(0, 24000).rms();
      final secondHalf = mixed.slice(24000, 24000).rms();
      expect(secondHalf, greaterThan(firstHalf * 1.2));
    });

    test('reports progress from zero to one', () async {
      final progress = <double>[];

      await exporter.exportMix(
        project: buildProject(),
        buffers: buffers(),
        settings: const ExportSettings(),
        destinationPath: '${root.path}/progress.wav',
        onProgress: progress.add,
      );

      expect(progress, isNotEmpty);
      expect(progress.last, closeTo(1.0, 1e-9));
      expect(progress, everyElement(inInclusiveRange(0.0, 1.0)));
    });

    test('the master limiter keeps a hot mix under the ceiling', () async {
      final destination = '${root.path}/loud.wav';
      final loud = {
        'a': tone(220, level: 1.5),
        'b': tone(880, level: 1.5),
      };

      await exporter.exportMix(
        project: buildProject(masterGain: 2.0, limiter: true),
        buffers: loud,
        settings: const ExportSettings(bitDepth: ExportBitDepth.float32),
        destinationPath: destination,
      );
      final mixed = await WavCodec.read(destination);

      expect(mixed.peak(), lessThanOrEqualTo(1.0));
    });

    test('limiter latency does not delay the exported audio', () async {
      final destination = '${root.path}/aligned.wav';

      await exporter.exportMix(
        project: buildProject(limiter: true),
        buffers: buffers(),
        settings: const ExportSettings(bitDepth: ExportBitDepth.float32),
        destinationPath: destination,
      );
      final mixed = await WavCodec.read(destination);

      // The material starts at frame zero, so the file must too.
      expect(mixed.slice(0, 480).rms(), greaterThan(0.01));
    });

    test('resamples to the chosen export rate', () async {
      final destination = '${root.path}/44k.wav';

      await exporter.exportMix(
        project: buildProject(),
        buffers: buffers(),
        settings: const ExportSettings(sampleRate: 44100),
        destinationPath: destination,
      );

      final info = await WavCodec.readInfo(destination);
      expect(info.sampleRate, 44100);
      expect(info.frameCount, closeTo(44100, 10));
    });

    test('exports one file per track', () async {
      final directory = '${root.path}/stems';

      final results = await exporter.exportStems(
        project: buildProject(),
        buffers: buffers(),
        settings: const ExportSettings(),
        destinationDirectory: directory,
      );

      expect(results, hasLength(2));
      expect(
        results.map((result) => result.fileName),
        containsAll(['Instrumental.wav', 'My vocal.wav']),
      );
      for (final result in results) {
        expect(await File(result.path).exists(), isTrue);
      }
    });

    test('a stem contains only its own track', () async {
      final directory = '${root.path}/stems2';

      final results = await exporter.exportStems(
        project: buildProject(),
        buffers: buffers(),
        settings: const ExportSettings(bitDepth: ExportBitDepth.float32),
        destinationDirectory: directory,
      );
      final vocal = await WavCodec.read(
        results.firstWhere((r) => r.fileName == 'My vocal.wav').path,
      );

      // The vocal clip only starts halfway through, so the first half of its
      // stem is silent.
      expect(vocal.slice(0, 20000).peak(), lessThan(1e-6));
      expect(vocal.slice(30000, 10000).peak(), greaterThan(0.1));
    });

    test('offers only formats this build can actually write', () {
      expect(exporter.availableFormats(), [AudioFileFormat.wav]);
    });

    test('refuses to export an empty project', () async {
      final empty = Project(
        id: 'e',
        name: 'Empty',
        sampleRate: 48000,
        createdAt: DateTime(2026),
        modifiedAt: DateTime(2026),
      );

      await expectLater(
        exporter.exportMix(
          project: empty,
          buffers: const {},
          settings: const ExportSettings(),
          destinationPath: '${root.path}/empty.wav',
        ),
        throwsA(anything),
      );
    });
  });
}
