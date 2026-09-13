import 'dart:io';

import 'package:encore/separation/stem_cache.dart';
import 'package:encore/separation/stem_kind.dart';
import 'package:encore/storage/app_paths.dart';
import 'package:encore/storage/file_key.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late AppPaths paths;
  late StemCache cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('encore-stems-');
    paths = AppPaths(root);
    await paths.ensureDirectories();
    cache = StemCache(paths);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> writeStems(String key, String model, Set<StemKind> stems) async {
    final directory = cache.directoryFor(key, model);
    await directory.create(recursive: true);
    for (final stem in stems) {
      await File('${directory.path}/${stem.fileName}')
          .writeAsString('audio for ${stem.name}');
    }
    await cache.writeManifest(
      sourceKey: key,
      modelId: model,
      stemFileNames: {for (final stem in stems) stem: stem.fileName},
      sampleRate: 48000,
      channelCount: 2,
      frameCount: 96000,
      title: 'A song',
    );
  }

  group('StemCache', () {
    test('a miss before anything is written', () async {
      expect(
        await cache.lookup('key', 'model', StemKind.twoStem),
        isNull,
      );
    });

    test('finds what was written', () async {
      await writeStems('key', 'model', StemKind.twoStem);

      final found = await cache.lookup('key', 'model', StemKind.twoStem);

      expect(found, isNotNull);
      expect(found!.sampleRate, 48000);
      expect(found.frameCount, 96000);
      expect(found.paths.keys.toSet(), StemKind.twoStem);
      expect(await File(found.paths[StemKind.vocals]!).exists(), isTrue);
    });

    test('a different model is a different entry', () async {
      await writeStems('key', 'fast', StemKind.twoStem);

      expect(await cache.lookup('key', 'fast', StemKind.twoStem), isNotNull);
      expect(await cache.lookup('key', 'detailed', StemKind.twoStem), isNull);
    });

    test('a two-stem entry does not satisfy a four-stem request', () async {
      await writeStems('key', 'model', StemKind.twoStem);

      expect(
        await cache.lookup('key', 'model', StemKind.fourStem),
        isNull,
      );
    });

    test('a manifest pointing at a missing file is discarded', () async {
      await writeStems('key', 'model', StemKind.twoStem);
      final directory = cache.directoryFor('key', 'model');
      await File('${directory.path}/${StemKind.vocals.fileName}').delete();

      expect(await cache.lookup('key', 'model', StemKind.twoStem), isNull);
      // The broken entry heals itself rather than failing again next time.
      expect(await directory.exists(), isFalse);
    });

    test('lists entries with their size', () async {
      await writeStems('one', 'model', StemKind.twoStem);
      await writeStems('two', 'model', StemKind.twoStem);

      final entries = await cache.entries();

      expect(entries, hasLength(2));
      expect(entries.first.sizeBytes, greaterThan(0));
      expect(entries.first.title, 'A song');
      expect(entries.map((entry) => entry.sourceKey), containsAll(['one', 'two']));
    });

    test('clear empties the cache and leaves it usable', () async {
      await writeStems('key', 'model', StemKind.twoStem);
      expect(await cache.sizeBytes(), greaterThan(0));

      await cache.clear();

      expect(await cache.sizeBytes(), 0);
      expect(await paths.stemCache.exists(), isTrue);
      expect(await cache.lookup('key', 'model', StemKind.twoStem), isNull);
    });

    test('remove drops one source without touching another', () async {
      await writeStems('one', 'model', StemKind.twoStem);
      await writeStems('two', 'model', StemKind.twoStem);

      await cache.remove('one');

      expect(await cache.lookup('one', 'model', StemKind.twoStem), isNull);
      expect(await cache.lookup('two', 'model', StemKind.twoStem), isNotNull);
    });
  });

  group('FileKey', () {
    test('the same contents give the same key from a different path', () async {
      final first = File('${root.path}/a.wav')..writeAsBytesSync(
        List.generate(5000, (i) => i % 251),
      );
      final second = File('${root.path}/b.wav')..writeAsBytesSync(
        List.generate(5000, (i) => i % 251),
      );

      expect(
        await FileKey.forFile(first.path),
        await FileKey.forFile(second.path),
      );
    });

    test('different contents give different keys', () async {
      final first = File('${root.path}/x.wav')..writeAsBytesSync(
        List.generate(5000, (i) => i % 251),
      );
      final second = File('${root.path}/y.wav')..writeAsBytesSync(
        List.generate(5000, (i) => (i + 1) % 251),
      );

      expect(
        await FileKey.forFile(first.path),
        isNot(await FileKey.forFile(second.path)),
      );
    });

    test('a different length gives a different key', () async {
      final first = File('${root.path}/short.wav')
        ..writeAsBytesSync(List.filled(1000, 9));
      final second = File('${root.path}/long.wav')
        ..writeAsBytesSync(List.filled(1001, 9));

      expect(
        await FileKey.forFile(first.path),
        isNot(await FileKey.forFile(second.path)),
      );
    });

    test('is 32 hex characters', () async {
      final file = File('${root.path}/k.wav')
        ..writeAsBytesSync(List.filled(100, 1));

      final key = await FileKey.forFile(file.path);

      expect(key, hasLength(32));
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(key), isTrue);
    });
  });
}
