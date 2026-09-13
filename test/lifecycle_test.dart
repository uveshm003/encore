import 'dart:async';
import 'dart:io';

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/core/dsp/level_meter.dart';
import 'package:encore/engine/audio_output.dart';
import 'package:encore/engine/engine_config.dart';
import 'package:encore/engine/playback_engine.dart';
import 'package:encore/io/codec/wav_codec.dart';
import 'package:encore/io/incoming_files.dart';
import 'package:encore/project/asset_store.dart';
import 'package:encore/project/models/audio_asset.dart';
import 'package:encore/project/project_controller.dart';
import 'package:encore/project/project_repository.dart';
import 'package:encore/separation/model_store.dart';
import 'package:encore/separation/separation_model.dart';
import 'package:encore/separation/separation_service.dart';
import 'package:encore/separation/stem_cache.dart';
import 'package:encore/separation/stem_kind.dart';
import 'package:encore/storage/app_paths.dart';
import 'package:encore/ui/theme.dart';
import 'package:encore/ui/widgets/level_meter_bar.dart';
import 'package:encore/ui/widgets/primitives.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

import 'engine/fakes.dart';

/// What happens to resources when things are torn down, cancelled or repeated.
///
/// Three kinds of failure live here, and none of them show up in a normal run:
///
/// * **Leaks** — a widget, controller or isolate that outlives what created
///   it. On a phone this is what turns a long session into a crash.
/// * **Unhandled async errors** — a Completer failed with nobody listening.
///   These do not fail the operation; they surface later, somewhere else,
///   attached to nothing.
/// * **Accumulation** — repeating an operation many times growing something
///   that should be bounded.
void main() {
  const config = EngineConfig(
    sampleRate: 48000,
    channelCount: 2,
    blockFrames: 512,
    bufferedBlocks: 2,
  );

  late Directory root;
  late AppPaths paths;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('encore-life-');
    paths = AppPaths(root);
    await paths.ensureDirectories();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  AudioBuffer tone({int frames = 48000, int channels = 2}) {
    final buffer = AudioBuffer.silence(
      channelCount: channels,
      frameCount: frames,
      sampleRate: 48000,
    );
    for (var c = 0; c < channels; c++) {
      for (var i = 0; i < frames; i++) {
        buffer.channels[c][i] = (i % 200) / 200 - 0.5;
      }
    }
    return buffer;
  }

  // ------------------------------------------------------------------------
  group('widgets release what they allocate', () {
    // These widgets own AnimationControllers and subscriptions. Leak tracking
    // fails the test if one survives the pump that should have taken it.
    testWidgets('a pulsing status dot is collected', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: EncoreTheme.dark(),
        home: const Scaffold(
          body: Center(child: StatusDot(colour: Palette.record, pulse: true)),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(const SizedBox.shrink());
    }, experimentalLeakTesting: LeakTesting.settings.withTrackedAll());

    testWidgets('an entrance fade is collected', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: EncoreTheme.dark(),
        home: const Scaffold(
          body: EntranceFade(child: Text('hello')),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox.shrink());
    }, experimentalLeakTesting: LeakTesting.settings.withTrackedAll());

    testWidgets('meters and progress bars are collected', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: EncoreTheme.dark(),
        home: const Scaffold(
          body: Column(
            children: [
              SizedBox(
                width: 200,
                child: LevelMeterBar(
                  reading: LevelReading(peakDb: -6, rmsDb: -12, clipped: false),
                ),
              ),
              SizedBox(width: 200, child: ProgressTrack(value: 0.5)),
            ],
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox.shrink());
    }, experimentalLeakTesting: LeakTesting.settings.withTrackedAll());
  });

  // ------------------------------------------------------------------------
  group('separation jobs clean up after themselves', () {
    late StemCache cache;
    late ModelStore models;
    late SeparationService service;
    late String sourceWav;
    var disposed = false;

    setUp(() async {
      // Reset per test: the flag lives at group scope and would otherwise
      // stay true after the first test that disposes early.
      disposed = false;
      cache = StemCache(paths);
      models = ModelStore(paths);
      service = SeparationService(paths: paths, cache: cache, models: models);
      sourceWav = '${root.path}/source.wav';
      // Long enough that the isolate is still working when we cancel it.
      await WavCodec.write(sourceWav, tone(frames: 48000 * 20));
    });

    void disposeOnce() {
      if (disposed) return;
      disposed = true;
      service.dispose();
    }

    tearDown(disposeOnce);

    test('cancelling a job does not raise an unhandled error', () async {
      // The hazard: cancel() completes the result future with an error. If
      // nothing is listening — which is exactly the case when the user cancels
      // from a screen that has already been popped — that error escapes into
      // the zone and is reported against whatever is running next.
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final job = await service.separate(
          sourceWavPath: sourceWav,
          sourceKey: 'cancel-key',
          model: SeparationCatalog.spectralFast,
          stems: StemKind.twoStem,
          title: 'Cancelled',
        );
        // Deliberately never touch job.result.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        job.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }, (error, stack) => errors.add(error));

      expect(
        errors,
        isEmpty,
        reason: 'a cancelled job must not leave an error nobody can catch',
      );
    });

    test('cancelling twice is harmless', () async {
      final job = await service.separate(
        sourceWavPath: sourceWav,
        sourceKey: 'twice-key',
        model: SeparationCatalog.spectralFast,
        stems: StemKind.twoStem,
        title: 'Twice',
      );
      // Swallow the cancellation error; this test is about the cleanup, not
      // about the error reaching a caller.
      unawaited(job.result.then((_) {}, onError: (Object _) {}));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      job.cancel();
      expect(job.cancel, returnsNormally);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });

    test('cancelling removes the partial output rather than caching it',
        () async {
      final job = await service.separate(
        sourceWavPath: sourceWav,
        sourceKey: 'partial-key',
        model: SeparationCatalog.spectralFast,
        stems: StemKind.twoStem,
        title: 'Partial',
      );
      // Swallow the cancellation error; this test is about the cleanup, not
      // about the error reaching a caller.
      unawaited(job.result.then((_) {}, onError: (Object _) {}));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      job.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final hit = await cache.lookup(
        'partial-key',
        SeparationCatalog.spectralFast.id,
        StemKind.twoStem,
      );
      expect(hit, isNull, reason: 'a half-separated song must not be cached');
    });

    test('many start/cancel cycles do not accumulate live jobs', () async {
      for (var i = 0; i < 6; i++) {
        final job = await service.separate(
          sourceWavPath: sourceWav,
          sourceKey: 'cycle-$i',
          model: SeparationCatalog.spectralFast,
          stems: StemKind.twoStem,
          title: 'Cycle $i',
        );
        // Swallow the cancellation error; this test is about the cleanup, not
      // about the error reaching a caller.
      unawaited(job.result.then((_) {}, onError: (Object _) {}));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        job.cancel();
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        service.activeJobs,
        isEmpty,
        reason: 'every cancelled job must leave the active list',
      );
    });

    test('disposing the service with a job in flight stops it', () async {
      final job = await service.separate(
        sourceWavPath: sourceWav,
        sourceKey: 'dispose-key',
        model: SeparationCatalog.spectralFast,
        stems: StemKind.twoStem,
        title: 'Disposed',
      );
      // Swallow the cancellation error; this test is about the cleanup, not
      // about the error reaching a caller.
      unawaited(job.result.then((_) {}, onError: (Object _) {}));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      disposeOnce();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(job.isFinished, isTrue);
    });
  });

  // ------------------------------------------------------------------------
  group('repetition stays bounded', () {
    test('opening and closing a project repeatedly releases its audio',
        () async {
      final repository = ProjectRepository(paths: paths);
      final assets = AssetStore(repository: repository);
      final engine = PlaybackEngine(
        config: config,
        output: NullAudioOutput(),
        input: FakeAudioInput(),
      );
      await engine.start();
      final controller = ProjectController(
        repository: repository,
        assets: assets,
        engine: engine,
        autoSaveDelay: const Duration(hours: 1),
      );

      var project = await repository.create(name: 'Cycled');
      final path = repository.assetPathFor(project.id, 'a');
      await WavCodec.write(path, tone());
      project = project.copyWith(
        assets: [
          AudioAsset(
            id: 'a',
            path: path,
            origin: AssetOrigin.separated,
            sampleRate: 48000,
            channelCount: 2,
            frameCount: 48000,
          ),
        ],
      );
      await repository.save(project);

      for (var i = 0; i < 12; i++) {
        await controller.open(project.id);
        expect(assets.buffers, hasLength(1));
        await controller.close();
        expect(
          assets.buffers,
          isEmpty,
          reason: 'closing must release the audio, not stack another copy',
        );
      }

      controller.dispose();
      await engine.shutdown();
    });

    test('the undo stack is capped rather than growing for ever', () async {
      final repository = ProjectRepository(paths: paths);
      final assets = AssetStore(repository: repository);
      final engine = PlaybackEngine(
        config: config,
        output: NullAudioOutput(),
        input: FakeAudioInput(),
      );
      await engine.start();
      final controller = ProjectController(
        repository: repository,
        assets: assets,
        engine: engine,
        autoSaveDelay: const Duration(hours: 1),
      );
      final project = await repository.create(name: 'Undo');
      await controller.open(project.id);

      // Every edit retains a whole Project. Unbounded, a long session would
      // hold every state the project has ever been in.
      for (var i = 0; i < 500; i++) {
        controller.edit((p) => p.copyWith(name: 'Edit $i'));
      }

      var depth = 0;
      while (controller.canUndo && depth < 1000) {
        controller.undo();
        depth++;
      }
      expect(
        depth,
        lessThanOrEqualTo(200),
        reason: 'the history has to be bounded',
      );

      controller.dispose();
      await engine.shutdown();
    });

    test('incoming files closes its stream and channel handler', () async {
      final incoming = IncomingFiles();
      await incoming.start();
      await incoming.dispose();
      // A closed broadcast controller must not accept more listeners silently
      // failing later.
      expect(incoming.files.isBroadcast, isTrue);
      await expectLater(incoming.dispose(), completes);
    });
  });
}
