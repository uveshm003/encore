import 'dart:convert';
import 'dart:io';

import '../storage/app_paths.dart';
import 'stem_kind.dart';

/// A separation result that is already on disk.
class CachedStems {
  const CachedStems({
    required this.sourceKey,
    required this.modelId,
    required this.paths,
    required this.sampleRate,
    required this.channelCount,
    required this.frameCount,
    required this.createdAt,
  });

  final String sourceKey;
  final String modelId;

  /// Absolute path to each stem's WAV file.
  final Map<StemKind, String> paths;
  final int sampleRate;
  final int channelCount;
  final int frameCount;
  final DateTime createdAt;

  bool covers(Set<StemKind> stems) => paths.keys.toSet().containsAll(stems);
}

/// One cached separation, as shown in the storage screen.
class StemCacheEntry {
  const StemCacheEntry({
    required this.sourceKey,
    required this.modelId,
    required this.stems,
    required this.sizeBytes,
    required this.createdAt,
    this.title,
  });

  final String sourceKey;
  final String modelId;
  final Set<StemKind> stems;
  final int sizeBytes;
  final DateTime createdAt;

  /// Title of the library item this came from, when it is still present.
  final String? title;
}

/// Disk cache for separated stems (SEP-03, §8).
///
/// Entries are keyed by the *content* of the source file and by the model that
/// produced them, so importing the same song twice — even from a different
/// folder — reuses the existing separation, while switching quality tier
/// correctly produces a new one. Everything here is reproducible, so the whole
/// tree can be deleted to reclaim space (NFR-RES-01).
class StemCache {
  const StemCache(this.paths);

  final AppPaths paths;

  static const String _manifestName = 'manifest.json';

  Directory directoryFor(String sourceKey, String modelId) =>
      paths.stemCacheEntry(sourceKey, modelId);

  /// Returns the cached result when it exists and covers [required].
  ///
  /// A manifest that references a missing file is treated as a miss and
  /// removed, so a half-deleted cache heals itself instead of failing later.
  Future<CachedStems?> lookup(
    String sourceKey,
    String modelId,
    Set<StemKind> required,
  ) async {
    final directory = directoryFor(sourceKey, modelId);
    final manifest = File('${directory.path}/$_manifestName');
    if (!await manifest.exists()) return null;
    try {
      final json = jsonDecode(await manifest.readAsString())
          as Map<String, Object?>;
      final stems = <StemKind, String>{};
      final entries = (json['stems'] as Map<String, Object?>? ?? const {});
      for (final entry in entries.entries) {
        final kind = _kindFromName(entry.key);
        if (kind == null) continue;
        final path = '${directory.path}/${entry.value}';
        if (!await File(path).exists()) {
          await _deleteQuietly(directory);
          return null;
        }
        stems[kind] = path;
      }
      final cached = CachedStems(
        sourceKey: sourceKey,
        modelId: modelId,
        paths: stems,
        sampleRate: (json['sampleRate'] as num?)?.toInt() ?? 0,
        channelCount: (json['channelCount'] as num?)?.toInt() ?? 0,
        frameCount: (json['frameCount'] as num?)?.toInt() ?? 0,
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
      );
      return cached.covers(required) ? cached : null;
    } on Object {
      await _deleteQuietly(directory);
      return null;
    }
  }

  /// Records a completed separation.
  Future<CachedStems> writeManifest({
    required String sourceKey,
    required String modelId,
    required Map<StemKind, String> stemFileNames,
    required int sampleRate,
    required int channelCount,
    required int frameCount,
    String? title,
  }) async {
    final directory = directoryFor(sourceKey, modelId);
    await directory.create(recursive: true);
    final createdAt = DateTime.now();
    final manifest = File('${directory.path}/$_manifestName');
    await manifest.writeAsString(
      jsonEncode({
        'sourceKey': sourceKey,
        'modelId': modelId,
        'sampleRate': sampleRate,
        'channelCount': channelCount,
        'frameCount': frameCount,
        'createdAt': createdAt.toIso8601String(),
        'title': ?title,
        'stems': {
          for (final entry in stemFileNames.entries)
            entry.key.name: entry.value,
        },
      }),
      flush: true,
    );
    return CachedStems(
      sourceKey: sourceKey,
      modelId: modelId,
      paths: {
        for (final entry in stemFileNames.entries)
          entry.key: '${directory.path}/${entry.value}',
      },
      sampleRate: sampleRate,
      channelCount: channelCount,
      frameCount: frameCount,
      createdAt: createdAt,
    );
  }

  /// Every cached separation, newest first.
  Future<List<StemCacheEntry>> entries() async {
    final root = paths.stemCache;
    if (!await root.exists()) return const [];
    final entries = <StemCacheEntry>[];
    await for (final sourceDirectory in root.list(followLinks: false)) {
      if (sourceDirectory is! Directory) continue;
      await for (final modelDirectory in sourceDirectory.list(followLinks: false)) {
        if (modelDirectory is! Directory) continue;
        final manifest = File('${modelDirectory.path}/$_manifestName');
        if (!await manifest.exists()) continue;
        try {
          final json = jsonDecode(await manifest.readAsString())
              as Map<String, Object?>;
          final stems = <StemKind>{};
          for (final key
              in (json['stems'] as Map<String, Object?>? ?? const {}).keys) {
            final kind = _kindFromName(key);
            if (kind != null) stems.add(kind);
          }
          entries.add(StemCacheEntry(
            sourceKey: json['sourceKey'] as String? ?? '',
            modelId: json['modelId'] as String? ?? '',
            stems: stems,
            sizeBytes: await AppPaths.directorySize(modelDirectory),
            createdAt:
                DateTime.tryParse(json['createdAt'] as String? ?? '') ??
                DateTime.now(),
            title: json['title'] as String?,
          ));
        } on Object {
          // Skip an unreadable entry rather than failing the whole listing.
        }
      }
    }
    entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return entries;
  }

  Future<int> sizeBytes() => AppPaths.directorySize(paths.stemCache);

  /// Removes one model's results for a source, or every model's when
  /// [modelId] is omitted.
  Future<void> remove(String sourceKey, {String? modelId}) async {
    final directory = modelId == null
        ? Directory('${paths.stemCache.path}/$sourceKey')
        : directoryFor(sourceKey, modelId);
    await _deleteQuietly(directory);
  }

  /// Empties the cache. Separation will simply run again when needed.
  Future<void> clear() async {
    await _deleteQuietly(paths.stemCache);
    await paths.stemCache.create(recursive: true);
  }

  static StemKind? _kindFromName(String name) {
    for (final kind in StemKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }

  static Future<void> _deleteQuietly(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // Leaving a stale directory behind is better than surfacing an error
      // the user cannot act on; it will be overwritten next time.
    }
  }
}
