import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../engine/engine_config.dart';
import '../storage/app_paths.dart';
import 'models/audio_asset.dart';
import 'models/project.dart';

/// Raised when a project cannot be read or written, with a message for the
/// user rather than a stack trace.
class ProjectException implements Exception {
  const ProjectException(this.message, {this.details});

  final String message;
  final String? details;

  @override
  String toString() => message;
}

/// Reads and writes projects on local storage (PROJ-01, PROJ-02, PROJ-04).
///
/// A project is a folder: `project.json` plus an `assets` directory holding
/// the audio it owns. Assets that live inside the folder are stored as
/// relative paths, which is what lets a project be copied or backed up whole
/// (PROJ-05); assets shared with other projects — library decodes and cached
/// stems — are referenced absolutely and are not duplicated.
class ProjectRepository {
  ProjectRepository({required this.paths, Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppPaths paths;
  final Uuid _uuid;

  static const String _assetsFolder = 'assets';

  /// Creates and saves an empty project.
  Future<Project> create({
    required String name,
    EngineConfig config = const EngineConfig(),
    String? sourceMediaId,
    String? sourceTitle,
  }) async {
    final now = DateTime.now();
    final project = Project(
      id: _uuid.v4(),
      name: name,
      sampleRate: config.sampleRate,
      channelCount: config.channelCount,
      createdAt: now,
      modifiedAt: now,
      sourceMediaId: sourceMediaId,
      sourceTitle: sourceTitle,
    );
    await paths.projectAssets(project.id).create(recursive: true);
    await save(project);
    return project;
  }

  /// Writes the project, stamping the modification time.
  ///
  /// The file is written beside the real one and renamed into place, so an
  /// interrupted save leaves the previous version intact rather than a
  /// truncated file (NFR-RES-03).
  Future<Project> save(Project project) async {
    final stamped = project.copyWith(modifiedAt: DateTime.now());
    final file = paths.projectFile(stamped.id);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_serialise(stamped)),
        flush: true,
      );
      await temporary.rename(file.path);
    } on FileSystemException catch (error) {
      throw ProjectException(
        'The project could not be saved. Check there is space available.',
        details: '$error',
      );
    }
    return stamped;
  }

  Future<bool> exists(String id) => paths.projectFile(id).exists();

  /// Loads a project, resolving relative asset paths against its folder.
  Future<Project> load(String id) async {
    final file = paths.projectFile(id);
    if (!await file.exists()) {
      throw const ProjectException('That project could not be found.');
    }
    Map<String, Object?> json;
    try {
      json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    } on Object catch (error) {
      throw ProjectException(
        'The project file is damaged and could not be opened.',
        details: '$error',
      );
    }
    final version = (json['schemaVersion'] as num?)?.toInt() ?? 1;
    if (version > Project.schemaVersion) {
      throw const ProjectException(
        'This project was made with a newer version of Encore.',
      );
    }
    final project = Project.fromJson(json);
    return project.copyWith(
      assets: [
        for (final asset in project.assets) _resolveAsset(project.id, asset),
      ],
    );
  }

  /// Every saved project, most recently modified first (LIB-01).
  Future<List<ProjectSummary>> list() async {
    final root = paths.projects;
    if (!await root.exists()) return const [];
    final summaries = <ProjectSummary>[];
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final id = entry.path.split(Platform.pathSeparator).last;
      try {
        summaries.add(ProjectSummary.of(await load(id)));
      } on ProjectException {
        // A damaged project is skipped rather than blocking the whole list.
      }
    }
    summaries.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return summaries;
  }

  Future<void> rename(String id, String name) async {
    final project = await load(id);
    await save(project.copyWith(name: name));
  }

  /// Copies a project, including the audio it owns (PROJ-04).
  Future<Project> duplicate(String id, {String? name}) async {
    final source = await load(id);
    final copyId = _uuid.v4();
    final destination = paths.projectDirectory(copyId);
    await destination.create(recursive: true);

    final sourceAssets = paths.projectAssets(id);
    if (await sourceAssets.exists()) {
      await _copyDirectory(sourceAssets, paths.projectAssets(copyId));
    }

    final now = DateTime.now();
    final copy = source.copyWith(
      id: copyId,
      name: name ?? '${source.name} copy',
      createdAt: now,
      modifiedAt: now,
      // Assets the source owned were just copied into the new folder, so the
      // duplicate has to point at its own files; anything shared (library
      // audio, cached stems) keeps its absolute path and is not duplicated.
      assets: [
        for (final asset in source.assets) _repoint(id, copyId, asset),
      ],
    );
    return save(copy);
  }

  /// Deletes the project and everything it owns. Library audio and cached
  /// stems are shared and are left alone.
  Future<void> delete(String id) async {
    final directory = paths.projectDirectory(id);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  /// Copies every externally referenced asset into the project folder so it
  /// can be moved or backed up on its own (PROJ-05).
  Future<Project> makeSelfContained(Project project) async {
    final assetsDirectory = paths.projectAssets(project.id);
    await assetsDirectory.create(recursive: true);
    final updated = <AudioAsset>[];
    for (final asset in project.assets) {
      if (_isInsideProject(project.id, asset.path)) {
        updated.add(asset);
        continue;
      }
      final source = File(asset.path);
      if (!await source.exists()) {
        updated.add(asset);
        continue;
      }
      final fileName = '${asset.id}.wav';
      await source.copy('${assetsDirectory.path}/$fileName');
      updated.add(asset.copyWith(path: '${assetsDirectory.path}/$fileName'));
    }
    return save(project.copyWith(assets: updated));
  }

  /// Where a new project-owned asset should be written.
  String assetPathFor(String projectId, String assetId, {String extension = 'wav'}) =>
      '${paths.projectAssets(projectId).path}/$assetId.$extension';

  /// Bytes used by one project (NFR-RES-01).
  Future<int> sizeOf(String id) =>
      AppPaths.directorySize(paths.projectDirectory(id));

  Map<String, Object?> _serialise(Project project) {
    final json = project.toJson();
    // Store project-owned assets relatively so the folder stays portable.
    json['assets'] = [
      for (final asset in project.assets)
        asset
            .copyWith(path: _relativise(project.id, asset.path))
            .toJson(),
    ];
    return json;
  }

  String _relativise(String projectId, String path) {
    final prefix = '${paths.projectDirectory(projectId).path}${Platform.pathSeparator}';
    return path.startsWith(prefix) ? path.substring(prefix.length) : path;
  }

  /// Rewrites an asset path that lived inside [fromProjectId] so it points at
  /// the same file inside [toProjectId].
  AudioAsset _repoint(String fromProjectId, String toProjectId, AudioAsset asset) {
    final resolved = _resolveAsset(fromProjectId, asset);
    if (!_isInsideProject(fromProjectId, resolved.path)) return resolved;
    final prefix = paths.projectDirectory(fromProjectId).path;
    return resolved.copyWith(
      path: paths.projectDirectory(toProjectId).path +
          resolved.path.substring(prefix.length),
    );
  }

  AudioAsset _resolveAsset(String projectId, AudioAsset asset) {
    if (_isAbsolute(asset.path)) return asset;
    return asset.copyWith(
      path: '${paths.projectDirectory(projectId).path}'
          '${Platform.pathSeparator}${asset.path}',
    );
  }

  bool _isInsideProject(String projectId, String path) =>
      path.startsWith(paths.projectDirectory(projectId).path);

  static bool _isAbsolute(String path) =>
      path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  static Future<void> _copyDirectory(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(recursive: true, followLinks: false)) {
      final relative = entity.path.substring(from.path.length + 1);
      if (entity is Directory) {
        await Directory('${to.path}${Platform.pathSeparator}$relative')
            .create(recursive: true);
      } else if (entity is File) {
        final destination = File('${to.path}${Platform.pathSeparator}$relative');
        await destination.parent.create(recursive: true);
        await entity.copy(destination.path);
      }
    }
  }

  /// A folder name for [_assetsFolder], exposed for tests.
  static String get assetsFolderName => _assetsFolder;
}
