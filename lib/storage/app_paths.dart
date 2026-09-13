import 'dart:io';

import 'package:encore_media/encore_media.dart';
import 'package:path_provider/path_provider.dart';

/// Where everything lives on disk (§8 Data & storage).
///
/// All of it is local: imported audio, cached stems, projects and exports.
/// Nothing is uploaded anywhere (NFR-OFF-02), and the cache is deliberately
/// kept in its own subtree so it can be measured and cleared without touching
/// user projects (NFR-RES-01).
class AppPaths {
  AppPaths(this.root);

  /// Resolves the app's storage root and creates the subtree if needed.
  static Future<AppPaths> resolve({Directory? overrideRoot}) async {
    final base = overrideRoot ?? await getApplicationSupportDirectory();
    final paths = AppPaths(base);
    await paths.ensureDirectories();
    return paths;
  }

  final Directory root;

  /// Canonical decodes of imported songs.
  Directory get library => Directory('${root.path}/library');

  /// One folder per project, holding `project.json` and its owned assets.
  Directory get projects => Directory('${root.path}/projects');

  /// Everything here is reproducible and safe to delete.
  Directory get cache => Directory('${root.path}/cache');

  /// Separated stems, keyed by source file (SEP-03).
  Directory get stemCache => Directory('${cache.path}/stems');

  /// Scratch space for in-progress renders and decodes.
  Directory get temp => Directory('${cache.path}/temp');

  /// Default destination for exported mixes.
  Directory get exports => Directory('${root.path}/exports');

  /// Installed separation model weights (NFR-OFF-03: fetched at most once,
  /// then used entirely offline).
  Directory get models => Directory('${root.path}/models');

  File get libraryIndex => File('${library.path}/index.json');

  Directory libraryItem(String mediaId) => Directory('${library.path}/$mediaId');

  Directory projectDirectory(String projectId) =>
      Directory('${projects.path}/$projectId');

  File projectFile(String projectId) =>
      File('${projectDirectory(projectId).path}/project.json');

  /// Where a project keeps the audio it owns (recordings, bounces).
  Directory projectAssets(String projectId) =>
      Directory('${projectDirectory(projectId).path}/assets');

  Directory stemCacheEntry(String sourceKey, String modelId) =>
      Directory('${stemCache.path}/$sourceKey/$modelId');

  Future<void> ensureDirectories() async {
    for (final directory in [
      library,
      projects,
      cache,
      stemCache,
      temp,
      exports,
      models,
    ]) {
      await directory.create(recursive: true);
    }
  }

  /// Total size in bytes of a directory subtree, or 0 if it does not exist.
  static Future<int> directorySize(Directory directory) async {
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // A file removed mid-scan just does not count towards the total.
        }
      }
    }
    return total;
  }

  /// Free space on the volume holding [root], or null when it cannot be read.
  ///
  /// Used to warn before a long separation or export rather than failing
  /// halfway through (NFR-RES-02).
  ///
  /// This goes through the native plugin rather than running `df`. `df` is a
  /// subprocess, which the macOS app sandbox is entitled to refuse, and it does
  /// not exist to be relied on at all on Android — which is the platform where
  /// storage is tightest and the warning matters most.
  ///
  /// Null means "the platform would not say", which is not the same as zero.
  /// Callers must let the work proceed on null.
  Future<int?> freeSpaceBytes() => freeSpaceBytesAt(root.path);

  /// As [freeSpaceBytes], for a volume other than the app's own.
  ///
  /// Exports go wherever the user points the folder picker, which is often a
  /// different disk from the one holding the library — so checking the app's
  /// root before an export would answer about the wrong volume.
  Future<int?> freeSpaceBytesAt(String path) => _media.freeSpaceBytes(path);

  final EncoreMedia _media = EncoreMedia();
}
