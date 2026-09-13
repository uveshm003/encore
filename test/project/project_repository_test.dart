import 'dart:io';

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/io/codec/wav_codec.dart';
import 'package:encore/project/asset_store.dart';
import 'package:encore/project/models/audio_asset.dart';
import 'package:encore/project/models/clip.dart';
import 'package:encore/project/models/mix_settings.dart';
import 'package:encore/project/models/track.dart';
import 'package:encore/project/project_repository.dart';
import 'package:encore/storage/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late AppPaths paths;
  late ProjectRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('encore-projects-');
    paths = AppPaths(root);
    await paths.ensureDirectories();
    repository = ProjectRepository(paths: paths);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('ProjectRepository', () {
    test('creates, saves and reopens a project', () async {
      final created = await repository.create(name: 'My song');

      final reopened = await repository.load(created.id);

      expect(reopened.id, created.id);
      expect(reopened.name, 'My song');
      expect(reopened.sampleRate, 48000);
      expect(reopened.tracks, isEmpty);
    });

    test('round-trips tracks, clips and mix settings', () async {
      var project = await repository.create(name: 'Full');
      project = project.copyWith(
        assets: [
          const AudioAsset(
            id: 'a1',
            path: '/somewhere/else/audio.wav',
            origin: AssetOrigin.separated,
            sampleRate: 48000,
            channelCount: 2,
            frameCount: 96000,
          ),
        ],
        tracks: [
          const Track(
            id: 't1',
            name: 'Instrumental',
            kind: TrackKind.instrumental,
            gain: 0.8,
            pan: -0.25,
            muted: true,
            clips: [
              Clip(
                id: 'c1',
                assetId: 'a1',
                timelineStart: 480,
                assetOffset: 240,
                length: 9600,
                fadeInFrames: 100,
              ),
            ],
          ),
        ],
        mix: const MixSettings(masterGain: 0.9, limiterCeilingDb: -1.5),
      );
      await repository.save(project);

      final reopened = await repository.load(project.id);
      final track = reopened.tracks.single;
      final clip = track.clips.single;

      expect(track.name, 'Instrumental');
      expect(track.gain, 0.8);
      expect(track.pan, -0.25);
      expect(track.muted, isTrue);
      expect(clip.timelineStart, 480);
      expect(clip.assetOffset, 240);
      expect(clip.fadeInFrames, 100);
      expect(reopened.mix.masterGain, 0.9);
      expect(reopened.mix.limiterCeilingDb, -1.5);
      // An asset outside the project folder keeps its absolute path.
      expect(reopened.assets.single.path, '/somewhere/else/audio.wav');
    });

    test('stores project-owned assets relatively so the folder can move',
        () async {
      final project = await repository.create(name: 'Portable');
      final assetPath = repository.assetPathFor(project.id, 'take1');
      await WavCodec.write(
        assetPath,
        AudioBuffer.silence(channelCount: 1, frameCount: 10, sampleRate: 48000),
      );

      await repository.save(project.copyWith(
        assets: [
          AudioAsset(
            id: 'take1',
            path: assetPath,
            origin: AssetOrigin.recorded,
            sampleRate: 48000,
            channelCount: 1,
            frameCount: 10,
          ),
        ],
      ));

      final raw = await paths.projectFile(project.id).readAsString();
      expect(raw, contains('assets/take1.wav'));
      expect(raw, isNot(contains(root.path)));

      // Loading resolves it back to something openable.
      final reopened = await repository.load(project.id);
      expect(await File(reopened.assets.single.path).exists(), isTrue);
    });

    test('lists projects newest first', () async {
      final first = await repository.create(name: 'One');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final second = await repository.create(name: 'Two');

      final listed = await repository.list();

      expect(listed.map((summary) => summary.id), [second.id, first.id]);
      expect(listed.first.name, 'Two');
    });

    test('duplicate copies the audio the project owns', () async {
      final project = await repository.create(name: 'Original');
      final assetPath = repository.assetPathFor(project.id, 'take1');
      await WavCodec.write(
        assetPath,
        AudioBuffer.silence(channelCount: 1, frameCount: 10, sampleRate: 48000),
      );
      await repository.save(project.copyWith(
        assets: [
          AudioAsset(
            id: 'take1',
            path: assetPath,
            origin: AssetOrigin.recorded,
            sampleRate: 48000,
            channelCount: 1,
            frameCount: 10,
          ),
        ],
      ));

      final copy = await repository.duplicate(project.id);

      expect(copy.id, isNot(project.id));
      expect(copy.name, 'Original copy');
      expect(await File(copy.assets.single.path).exists(), isTrue);
      expect(copy.assets.single.path, contains(copy.id));
      // The original is untouched.
      expect(await File(assetPath).exists(), isTrue);
    });

    test('delete removes the folder', () async {
      final project = await repository.create(name: 'Gone');

      await repository.delete(project.id);

      expect(await repository.exists(project.id), isFalse);
      expect(await paths.projectDirectory(project.id).exists(), isFalse);
    });

    test('reports a damaged project file rather than crashing', () async {
      final project = await repository.create(name: 'Broken');
      await paths.projectFile(project.id).writeAsString('{not json');

      await expectLater(
        repository.load(project.id),
        throwsA(isA<ProjectException>()),
      );
      // A damaged project is skipped in the listing instead of breaking it.
      expect(await repository.list(), isEmpty);
    });

    test('refuses a project written by a newer version', () async {
      final project = await repository.create(name: 'Future');
      final file = paths.projectFile(project.id);
      final raw = await file.readAsString();
      await file.writeAsString(raw.replaceFirst(
        '"schemaVersion": 1',
        '"schemaVersion": 99',
      ));

      await expectLater(
        repository.load(project.id),
        throwsA(isA<ProjectException>().having(
          (error) => error.message,
          'message',
          contains('newer version'),
        )),
      );
    });

    test('makeSelfContained pulls external audio into the project', () async {
      final external = '${root.path}/outside.wav';
      await WavCodec.write(
        external,
        AudioBuffer.silence(channelCount: 1, frameCount: 20, sampleRate: 48000),
      );
      var project = await repository.create(name: 'Bundle');
      project = project.copyWith(
        assets: [
          AudioAsset(
            id: 'ext',
            path: external,
            origin: AssetOrigin.separated,
            sampleRate: 48000,
            channelCount: 1,
            frameCount: 20,
          ),
        ],
      );

      final bundled = await repository.makeSelfContained(project);

      expect(bundled.assets.single.path, contains(project.id));
      expect(await File(bundled.assets.single.path).exists(), isTrue);
    });
  });

  group('AssetStore', () {
    test('loads audio once and caches the envelope beside it', () async {
      final store = AssetStore(repository: repository);
      final project = await repository.create(name: 'Assets');
      final path = repository.assetPathFor(project.id, 'a');
      final audio = AudioBuffer.silence(
        channelCount: 1,
        frameCount: 4800,
        sampleRate: 48000,
      );
      audio.channels[0][100] = 0.9;
      await WavCodec.write(path, audio);

      final asset = await store.reference(
        path: path,
        origin: AssetOrigin.imported,
      );
      final first = await store.load(asset);
      final second = await store.load(asset);

      expect(identical(first, second), isTrue);
      expect(first.frameCount, 4800);

      final peaks = await store.peaks(asset);
      expect(peaks.bucketCount, greaterThan(0));
      expect(await File('$path.peaks').exists(), isTrue);
    });

    test('writes a recording into the project folder', () async {
      final store = AssetStore(repository: repository);
      final project = await repository.create(name: 'Recorded');
      final audio = AudioBuffer.silence(
        channelCount: 1,
        frameCount: 2400,
        sampleRate: 48000,
      );

      final asset = await store.writeRecording(
        projectId: project.id,
        audio: audio,
        label: 'Take 1',
      );

      expect(asset.origin, AssetOrigin.recorded);
      expect(asset.frameCount, 2400);
      expect(await File(asset.path).exists(), isTrue);
      expect(store.isLoaded(asset.id), isTrue);
    });

    test('skips assets whose files have gone missing', () async {
      final store = AssetStore(repository: repository);

      final missing = await store.loadAll(const [
        AudioAsset(
          id: 'gone',
          path: '/nowhere/at/all.wav',
          origin: AssetOrigin.imported,
          sampleRate: 48000,
          channelCount: 2,
          frameCount: 100,
        ),
      ]);

      expect(missing.map((asset) => asset.id), ['gone']);
    });
  });
}
