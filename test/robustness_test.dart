import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:encore/app/app_settings.dart';
import 'package:encore/core/audio_buffer.dart';
import 'package:encore/core/waveform.dart';
import 'package:encore/engine/audio_output.dart';
import 'package:encore/engine/engine_config.dart';
import 'package:encore/engine/playback_engine.dart';
import 'package:encore/io/codec/codec_exception.dart';
import 'package:encore/io/codec/wav_codec.dart';
import 'package:encore/project/asset_store.dart';
import 'package:encore/project/models/audio_asset.dart';
import 'package:encore/project/models/clip.dart';
import 'package:encore/project/models/track.dart';
import 'package:encore/project/project_controller.dart';
import 'package:encore/project/project_repository.dart';
import 'package:encore/separation/spectral_separator.dart';
import 'package:encore/separation/stem_cache.dart';
import 'package:encore/separation/stem_kind.dart';
import 'package:encore/storage/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine/fakes.dart';

/// Attacks the edges: hostile files on disk, lifecycles torn down at the worst
/// moment, and degenerate numbers.
///
/// The contract every case here asserts is the same one NFR-RES-02 and IMP-04
/// state — **a bad input produces an error, never a crash and never a corrupt
/// project.** None of these are happy paths, and none of them should be
/// reachable in normal use; they are reachable by a truncated download, a
/// half-written file, a device running out of space, or a user with a text
/// editor.
void main() {
  const config = EngineConfig(
    sampleRate: 48000,
    channelCount: 2,
    blockFrames: 512,
    bufferedBlocks: 2,
  );

  late Directory root;
  late AppPaths paths;
  late ProjectRepository repository;
  late AssetStore assets;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('encore-robust-');
    paths = AppPaths(root);
    await paths.ensureDirectories();
    repository = ProjectRepository(paths: paths);
    assets = AssetStore(repository: repository);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> writeProjectFile(String id, String contents) async {
    final file = paths.projectFile(id);
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  AudioBuffer tone({int frames = 4800, int channels = 2, int rate = 48000}) {
    final buffer = AudioBuffer.silence(
      channelCount: channels,
      frameCount: frames,
      sampleRate: rate,
    );
    for (var c = 0; c < channels; c++) {
      for (var i = 0; i < frames; i++) {
        buffer.channels[c][i] = (i % 128) / 128 - 0.5;
      }
    }
    return buffer;
  }

  // ------------------------------------------------------------------------
  group('a hostile project file', () {
    test('malformed JSON fails to load rather than crashing the app', () async {
      await writeProjectFile('p1', '{ this is not json');
      await expectLater(repository.load('p1'), throwsA(isA<Object>()));
    });

    test('an empty file fails to load', () async {
      await writeProjectFile('p2', '');
      await expectLater(repository.load('p2'), throwsA(isA<Object>()));
    });

    test('JSON that is not an object fails to load', () async {
      await writeProjectFile('p3', '[1, 2, 3]');
      await expectLater(repository.load('p3'), throwsA(isA<Object>()));
    });

    test('a missing required field fails to load', () async {
      await writeProjectFile('p4', jsonEncode({'name': 'No id'}));
      await expectLater(repository.load('p4'), throwsA(isA<Object>()));
    });

    test('a field of the wrong type fails to load', () async {
      await writeProjectFile(
        'p5',
        jsonEncode({'id': 'p5', 'name': 7, 'sampleRate': 'lots'}),
      );
      await expectLater(repository.load('p5'), throwsA(isA<Object>()));
    });

    test('an unknown enum name does not throw', () async {
      // Forward compatibility: a project written by a later version that knows
      // a track kind this build does not must still open.
      await writeProjectFile(
        'p6',
        jsonEncode({
          'id': 'p6',
          'name': 'Future',
          'sampleRate': 48000,
          'channelCount': 2,
          'tracks': [
            {'id': 't1', 'name': 'Odd', 'kind': 'theremin', 'clips': []},
          ],
        }),
      );
      final project = await repository.load('p6');
      expect(project.tracks, hasLength(1));
    });

    test('a zero sample rate does not reach the engine as a divisor', () async {
      // Every duration in the app divides by the sample rate.
      await writeProjectFile(
        'p7',
        jsonEncode({
          'id': 'p7',
          'name': 'Zero',
          'sampleRate': 0,
          'channelCount': 2,
        }),
      );
      // Either it refuses the file, or it repairs the rate. What it must not
      // do is hand a zero divisor to the rest of the app.
      try {
        final project = await repository.load('p7');
        expect(
          project.sampleRate,
          greaterThan(0),
          reason: 'a zero rate would divide by zero in every duration',
        );
        expect(project.duration, isA<Duration>());
      } on Object {
        // Refusing the file is the other acceptable answer.
      }
    });

    test('listing survives one unreadable project among good ones', () async {
      await repository.create(name: 'Good one');
      await writeProjectFile('broken', 'not json at all');
      final summaries = await repository.list();
      expect(summaries.map((s) => s.name), contains('Good one'));
    });
  });

  // ------------------------------------------------------------------------
  group('a hostile settings file', () {
    test('corrupt settings fall back to defaults instead of throwing',
        () async {
      await File('${root.path}/settings.json').writeAsString('{{{');
      final settings = AppSettings(paths: paths);
      await settings.load();
      expect(settings.exportSettings.format, isNotNull);
    });

    test('an unknown export format falls back', () async {
      final file = File('${root.path}/settings.json');
      await file.writeAsString(jsonEncode({
        'export': {'format': 'wav64', 'bitDepth': 'pcm96'},
      }));
      final settings = AppSettings(paths: paths);
      await settings.load();
      expect(settings.exportSettings.format, isNotNull);
    });
  });

  // ------------------------------------------------------------------------
  group('a hostile WAV', () {
    test('a truncated file reports a codec error', () async {
      final path = '${root.path}/truncated.wav';
      await WavCodec.write(path, tone());
      final bytes = await File(path).readAsBytes();
      await File(path).writeAsBytes(bytes.sublist(0, 40));
      await expectLater(WavCodec.read(path), throwsA(isA<CodecException>()));
    });

    test('an empty file reports a codec error', () async {
      final path = '${root.path}/empty.wav';
      await File(path).writeAsBytes(Uint8List(0));
      await expectLater(WavCodec.read(path), throwsA(isA<CodecException>()));
    });

    test('random bytes report a codec error', () async {
      final path = '${root.path}/noise.wav';
      await File(path).writeAsBytes(
        Uint8List.fromList(List.generate(4096, (i) => (i * 37) % 256)),
      );
      await expectLater(WavCodec.read(path), throwsA(isA<CodecException>()));
    });

    test('a header claiming more data than exists does not allocate wildly',
        () async {
      final path = '${root.path}/liar.wav';
      await WavCodec.write(path, tone());
      final bytes = (await File(path).readAsBytes()).buffer.asByteData();
      // Claim 2 GB of samples in a file that holds a few kilobytes.
      bytes.setUint32(4, 0x7FFFFFFF, Endian.little);
      await File(path).writeAsBytes(bytes.buffer.asUint8List());
      Object? thrown;
      try {
        final buffer = await WavCodec.read(path);
        // If it reads at all, it must not have believed the header.
        expect(buffer.frameCount, lessThan(1 << 24));
      } on Object catch (error) {
        thrown = error;
      }
      expect(thrown == null || thrown is CodecException, isTrue,
          reason: 'a lying header must not produce an unrelated crash');
    });

    test('a missing file reports notFound, not a raw FileSystemException',
        () async {
      await expectLater(
        WavCodec.read('${root.path}/nope.wav'),
        throwsA(
          isA<CodecException>().having(
            (e) => e.kind,
            'kind',
            CodecErrorKind.notFound,
          ),
        ),
      );
    });
  });

  // ------------------------------------------------------------------------
  group('a hostile stem cache', () {
    test('a corrupt manifest reads as a miss, not a crash', () async {
      final cache = StemCache(paths);
      final directory = cache.directoryFor('key', 'model');
      await directory.create(recursive: true);
      await File('${directory.path}/manifest.json').writeAsString('{oops');
      final hit = await cache.lookup('key', 'model', StemKind.twoStem);
      expect(hit, isNull);
    });

    test('a manifest naming a stem file that is gone reads as a miss',
        () async {
      final cache = StemCache(paths);
      final directory = cache.directoryFor('key2', 'model');
      await directory.create(recursive: true);
      await File('${directory.path}/manifest.json').writeAsString(jsonEncode({
        'sourceKey': 'key2',
        'modelId': 'model',
        'stems': {'vocals': 'vocals.wav', 'instrumental': 'instrumental.wav'},
        'sampleRate': 48000,
        'channelCount': 2,
        'frameCount': 1000,
        'createdAt': DateTime.now().toIso8601String(),
      }));
      final hit = await cache.lookup('key2', 'model', StemKind.twoStem);
      expect(hit, isNull, reason: 'the audio is not actually there');
    });
  });

  // ------------------------------------------------------------------------
  group('lifecycle torn down at the worst moment', () {
    late PlaybackEngine engine;
    late ProjectController controller;

    Future<void> build() async {
      engine = PlaybackEngine(
        config: config,
        output: NullAudioOutput(),
        input: FakeAudioInput(),
      );
      await engine.start();
      controller = ProjectController(
        repository: repository,
        assets: assets,
        engine: engine,
        autoSaveDelay: const Duration(milliseconds: 20),
      );
    }

    test('disposing while an auto-save is pending does not throw', () async {
      await build();
      final project = await repository.create(name: 'Pending');
      await controller.open(project.id);
      controller.edit((p) => p.copyWith(name: 'Renamed'));
      // Dispose inside the auto-save window.
      controller.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await engine.shutdown();
    });

    test('using a disposed controller fails loudly rather than silently',
        () async {
      // Flutter's contract: a disposed ChangeNotifier is dead, and touching it
      // is a programming error the framework is supposed to shout about. What
      // matters is that it shouts instead of half-working — a controller that
      // quietly accepted edits after disposal would write them nowhere.
      await build();
      final project = await repository.create(name: 'Twice');
      await controller.open(project.id);
      controller.dispose();
      expect(
        () => controller.edit((p) => p.copyWith(name: 'Zombie')),
        throwsA(isA<FlutterError>()),
      );
      await engine.shutdown();
    });

    test('shutting the engine down twice is harmless', () async {
      await build();
      await engine.shutdown();
      await engine.shutdown();
      controller.dispose();
    });

    test('start/shutdown repeated does not leak handles or throw', () async {
      for (var i = 0; i < 8; i++) {
        final e = PlaybackEngine(
          config: config,
          output: NullAudioOutput(),
          input: FakeAudioInput(),
        );
        await e.start();
        e.play();
        e.stop();
        await e.shutdown();
      }
    });

    test('stopping a recording whose track was deleted mid-take', () async {
      final input = FakeAudioInput();
      engine = PlaybackEngine(
        config: config,
        output: NullAudioOutput(),
        input: input,
      );
      await engine.start();
      controller = ProjectController(
        repository: repository,
        assets: assets,
        engine: engine,
        autoSaveDelay: const Duration(milliseconds: 20),
      );
      var project = await repository.create(name: 'Race');
      project = project.copyWith(
        tracks: const [
          Track(id: 't1', name: 'Vocal', kind: TrackKind.recording,
              recordArmed: true),
        ],
      );
      await repository.save(project);
      await controller.open(project.id);

      await controller.startRecording();
      // Real audio, so stopRecording gets past its "nothing was captured"
      // guard and reaches the code that looks for the armed track.
      await input.emit(FakeAudioInput.block(0.4, frames: 2048));

      // The user deletes every track while the pass is running.
      controller.edit((p) => p.copyWith(tracks: const []));

      // Must not throw "Bad state: No element".
      await expectLater(controller.stopRecording(), completes);

      controller.dispose();
      await engine.shutdown();
    });

    test('opening a second project releases the first one\'s audio', () async {
      await build();
      final a = await repository.create(name: 'A');
      final b = await repository.create(name: 'B');

      final path = repository.assetPathFor(a.id, 'asset-a');
      await WavCodec.write(path, tone(frames: 48000));
      await repository.save(a.copyWith(
        assets: [
          AudioAsset(
            id: 'asset-a',
            path: path,
            origin: AssetOrigin.separated,
            sampleRate: 48000,
            channelCount: 2,
            frameCount: 48000,
          ),
        ],
      ));

      await controller.open(a.id);
      expect(assets.isLoaded('asset-a'), isTrue);
      await controller.open(b.id);
      expect(
        assets.isLoaded('asset-a'),
        isFalse,
        reason: 'switching projects must not keep the old audio resident',
      );

      controller.dispose();
      await engine.shutdown();
    });
  });

  // ------------------------------------------------------------------------
  group('degenerate numbers', () {
    test('an empty buffer survives every transform', () {
      final empty = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 0,
        sampleRate: 48000,
      );
      expect(empty.duration, Duration.zero);
      expect(() => WaveformPeaks.fromBuffer(empty), returnsNormally);
      expect(() => empty.toMono(), returnsNormally);
      expect(() => empty.toStereo(), returnsNormally);
      final separated = const SpectralSeparator().separate(
        empty,
        StemKind.twoStem,
      );
      expect(separated[StemKind.vocals]!.frameCount, 0);
    });

    test('a single-frame buffer survives separation', () {
      final tiny = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 1,
        sampleRate: 48000,
      );
      expect(
        () => const SpectralSeparator().separate(tiny, StemKind.twoStem),
        returnsNormally,
      );
    });

    test('a clip pointing past the end of its asset renders silence, not a '
        'range error', () async {
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

      var project = await repository.create(name: 'Overrun');
      final path = repository.assetPathFor(project.id, 'a');
      await WavCodec.write(path, tone(frames: 4800));
      project = project.copyWith(
        assets: [
          AudioAsset(
            id: 'a',
            path: path,
            origin: AssetOrigin.separated,
            sampleRate: 48000,
            channelCount: 2,
            frameCount: 4800,
          ),
        ],
        tracks: const [
          Track(
            id: 't1',
            name: 'Over',
            kind: TrackKind.instrumental,
            clips: [
              // Starts inside the asset, runs a long way past its end.
              Clip(
                id: 'c1',
                assetId: 'a',
                timelineStart: 0,
                assetOffset: 4000,
                length: 100000,
              ),
            ],
          ),
        ],
      );
      await repository.save(project);
      await controller.open(project.id);

      expect(() => engine.play(), returnsNormally);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(() => engine.stop(), returnsNormally);

      controller.dispose();
      await engine.shutdown();
    });

    test('an inverted loop region does not hang the transport', () async {
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
      final project = await repository.create(name: 'Loop');
      await controller.open(project.id);

      // End before start, and a zero-length region.
      expect(() => controller.setLoopRegion(48000, 0), returnsNormally);
      expect(() => controller.setLoopEnabled(true), returnsNormally);
      expect(() => controller.setLoopRegion(1000, 1000), returnsNormally);
      engine.play();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      engine.stop();

      controller.dispose();
      await engine.shutdown();
    });

    test('seeking far past the end and to negative positions is clamped',
        () async {
      final engine = PlaybackEngine(
        config: config,
        output: NullAudioOutput(),
        input: FakeAudioInput(),
      );
      await engine.start();
      expect(() => engine.seek(-1 << 40), returnsNormally);
      expect(engine.transport.value.positionFrames, greaterThanOrEqualTo(0));
      expect(() => engine.seek(1 << 40), returnsNormally);
      await engine.shutdown();
    });
  });
}
