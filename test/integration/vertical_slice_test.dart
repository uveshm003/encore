import 'dart:io';
import 'dart:math' as math;

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/engine/audio_output.dart';
import 'package:encore/engine/engine_config.dart';
import 'package:encore/engine/latency.dart';
import 'package:encore/engine/playback_engine.dart';
import 'package:encore/io/codec/codec_registry.dart';
import 'package:encore/io/codec/wav_codec.dart';
import 'package:encore/io/codec/wav_transcoder.dart';
import 'package:encore/io/export_service.dart';
import 'package:encore/library/media_library.dart';
import 'package:encore/project/asset_store.dart';
import 'package:encore/project/project_controller.dart';
import 'package:encore/project/project_factory.dart';
import 'package:encore/project/project_repository.dart';
import 'package:encore/separation/model_store.dart';
import 'package:encore/separation/separation_model.dart';
import 'package:encore/separation/separation_service.dart';
import 'package:encore/separation/stem_cache.dart';
import 'package:encore/separation/stem_kind.dart';
import 'package:encore/storage/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine/fakes.dart';

const config = EngineConfig(
  sampleRate: 48000,
  channelCount: 2,
  blockFrames: 512,
  bufferedBlocks: 2,
);

/// A stereo mix with a centred "vocal" and a hard-panned accompaniment, which
/// is the shape the separator is designed for.
Future<String> writeSongFile(String path) async {
  const frames = 48000 * 4;
  final buffer = AudioBuffer.silence(
    channelCount: 2,
    frameCount: frames,
    sampleRate: 48000,
  );
  for (var i = 0; i < frames; i++) {
    final t = i / 48000;
    final lead = 0.35 * math.sin(2 * math.pi * 440 * t);
    final guitar = 0.30 * math.sin(2 * math.pi * 660 * t);
    buffer.channels[0][i] = lead + guitar;
    buffer.channels[1][i] = lead + guitar * 0.1;
  }
  await WavCodec.write(path, buffer, depth: WavBitDepth.pcm16);
  return path;
}

void main() {
  late Directory root;
  late AppPaths paths;
  late CodecRegistry codecs;
  late MediaLibrary library;
  late ProjectRepository projects;
  late AssetStore assets;
  late SeparationService separation;
  late PlaybackEngine engine;
  late NullAudioOutput output;
  late FakeAudioInput input;
  late ProjectController controller;
  late ExportService exporter;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('encore-slice-');
    paths = AppPaths(root);
    await paths.ensureDirectories();

    codecs = CodecRegistry([const WavTranscoder()]);
    await codecs.initialise();
    library = MediaLibrary(paths: paths, codecs: codecs, config: config);
    await library.load();

    projects = ProjectRepository(paths: paths);
    assets = AssetStore(repository: projects);
    separation = SeparationService(
      paths: paths,
      cache: StemCache(paths),
      models: ModelStore(paths),
    );

    output = NullAudioOutput();
    input = FakeAudioInput();
    engine = PlaybackEngine(config: config, output: output, input: input);
    await engine.start();
    controller = ProjectController(
      repository: projects,
      assets: assets,
      engine: engine,
      // Save explicitly in the test rather than waiting on a timer.
      autoSaveDelay: const Duration(hours: 1),
    );
    exporter = ExportService(codecs: codecs, paths: paths);
  });

  tearDown(() async {
    controller.dispose();
    await engine.shutdown();
    separation.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'import, separate, record an overdub, export and reopen',
    () async {
      // 1. Import a song (acceptance criterion 1).
      final songPath = await writeSongFile('${root.path}/song.wav');
      final stages = <String>[];
      final item = await library.import(
        songPath,
        onProgress: (progress) => stages.add(progress.stage.name),
      );

      expect(item.title, 'song');
      expect(item.frameCount, 48000 * 4);
      expect(item.sampleRate, config.sampleRate);
      expect(stages, contains('decoding'));
      expect(await File(library.audioPathFor(item)).exists(), isTrue);
      expect(item.sourceKey, isNotEmpty);

      // Re-importing the same file recognises it by content and does not
      // decode it twice.
      final again = await library.import(songPath);
      expect(again.id, item.id);
      expect(library.items, hasLength(1));

      // 2. Separate it (acceptance criterion 2).
      final job = await separation.separate(
        sourceWavPath: library.audioPathFor(item),
        sourceKey: item.sourceKey,
        model: SeparationCatalog.spectralFast,
        stems: StemKind.twoStem,
        title: item.title,
      );
      final stems = await job.result;

      expect(stems.paths.keys, containsAll(StemKind.twoStem));
      final instrumental =
          await WavCodec.read(stems.paths[StemKind.instrumental]!);
      final vocals = await WavCodec.read(stems.paths[StemKind.vocals]!);
      expect(instrumental.frameCount, 48000 * 4);
      expect(instrumental.rms(), greaterThan(0.0));
      expect(vocals.rms(), greaterThan(0.0));

      // Asking again is a cache hit rather than a second separation
      // (SEP-03).
      final cached = await separation.cached(
        sourceKey: item.sourceKey,
        model: SeparationCatalog.spectralFast,
        stems: StemKind.twoStem,
      );
      expect(cached, isNotNull);

      // 3. Build a project from the stems and open it.
      final factory = ProjectFactory(repository: projects, assets: assets);
      final project = await factory.fromStems(
        source: item,
        stems: stems,
        config: config,
      );
      await controller.open(project.id);

      expect(controller.project, isNotNull);
      expect(controller.project!.tracks, hasLength(3));
      expect(
        controller.project!.tracks.map((track) => track.name),
        containsAll(['Instrumental', 'Vocals', 'My vocal']),
      );
      // The original vocal is muted so the backing is what plays.
      final originalVocal = controller.project!.tracks
          .firstWhere((track) => track.name == 'Vocals');
      expect(originalVocal.muted, isTrue);
      // The empty track is already armed, ready to record.
      final recordTrack = controller.project!.tracks
          .firstWhere((track) => track.name == 'My vocal');
      expect(recordTrack.recordArmed, isTrue);

      // Playback actually produces audio (acceptance criterion 3).
      controller.play();
      final rendered = output.pump(4);
      expect(rendered.last.peak(), greaterThan(0.01));
      controller.stop();

      // 4. Record an overdub against it.
      engine.latency = const LatencySettings(
        outputFrames: 512,
        inputFrames: 256,
      );
      controller.seek(24000);
      await controller.startRecording();
      output.pump(2);
      final anchor = 24000 + 2 * config.blockFrames;
      await input.emit(FakeAudioInput.block(0.5, frames: 48000));
      output.pump(1);
      final take = await controller.stopRecording();

      expect(take, isNotNull);
      expect(take!.timelineStart, anchor - 768);
      final armed = controller.project!.tracks
          .firstWhere((track) => track.id == recordTrack.id);
      expect(armed.takes, hasLength(1));
      expect(armed.clips, hasLength(1));
      expect(armed.clips.single.length, 48000);

      // 5. Add a second overdub track (acceptance criterion 4).
      final second = controller.addEmptyTrack(name: 'Guitar');
      expect(controller.project!.tracks, hasLength(4));
      expect(controller.project!.trackById(second.id), isNotNull);

      // 6. Adjust levels, then export (acceptance criterion 5).
      controller.edit((project) {
        final track = project.trackById(recordTrack.id)!;
        return project.withTrack(track.copyWith(gain: 0.7, pan: 0.2));
      });
      await controller.save();

      final destination = '${root.path}/final-mix.wav';
      final result = await exporter.exportMix(
        project: controller.project!,
        buffers: assets.buffers,
        settings: const ExportSettings(bitDepth: ExportBitDepth.pcm16),
        destinationPath: destination,
      );

      expect(await File(destination).exists(), isTrue);
      expect(result.sizeBytes, greaterThan(1000));
      final mix = await WavCodec.read(destination);
      expect(mix.channelCount, 2);
      expect(mix.peak(), greaterThan(0.01));
      expect(mix.peak(), lessThanOrEqualTo(1.0));

      // 7. Close and reopen: everything is still there.
      await controller.close();
      expect(controller.project, isNull);

      await controller.open(project.id);
      final reopened = controller.project!;

      expect(reopened.tracks, hasLength(4));
      final restoredTake = reopened.trackById(recordTrack.id)!;
      expect(restoredTake.gain, 0.7);
      expect(restoredTake.pan, 0.2);
      expect(restoredTake.takes, hasLength(1));
      expect(restoredTake.clips.single.timelineStart, take.timelineStart);
      expect(controller.missingAssets, isEmpty);
      // Every asset the project points at is loaded and playable again.
      for (final asset in reopened.assets) {
        expect(assets.isLoaded(asset.id), isTrue, reason: asset.id);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
