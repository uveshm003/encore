import 'dart:io';

import '../storage/app_paths.dart';
import 'separation_model.dart';

/// Whether a model's weights are present.
class ModelInstallation {
  const ModelInstallation({
    required this.model,
    required this.isInstalled,
    required this.sizeBytes,
    this.path,
  });

  final SeparationModel model;
  final bool isInstalled;
  final int sizeBytes;
  final String? path;
}

/// Manages separation model files on disk.
///
/// Weights are installed once and then used entirely offline (NFR-OFF-03).
/// Installation is from a local file the user chooses, so the app has no
/// network dependency at all for any of its behaviour (C-02); a build that
/// ships a download step can add one without changing anything else here.
class ModelStore {
  const ModelStore(this.paths);

  final AppPaths paths;

  String? pathFor(SeparationModel model) {
    final fileName = model.assetFileName;
    if (fileName == null) return null;
    return '${paths.models.path}/$fileName';
  }

  Future<bool> isInstalled(SeparationModel model) async {
    final path = pathFor(model);
    if (path == null) return false;
    return File(path).exists();
  }

  Future<ModelInstallation> installationOf(SeparationModel model) async {
    final path = pathFor(model);
    if (path == null) {
      return ModelInstallation(
        model: model,
        isInstalled: true,
        sizeBytes: 0,
      );
    }
    final file = File(path);
    final exists = await file.exists();
    return ModelInstallation(
      model: model,
      isInstalled: exists,
      sizeBytes: exists ? await file.length() : 0,
      path: exists ? path : null,
    );
  }

  Future<List<ModelInstallation>> listAll() async {
    return [
      for (final model in SeparationCatalog.all) await installationOf(model),
    ];
  }

  /// Copies a model file the user selected into the models directory.
  Future<ModelInstallation> installFromFile(
    SeparationModel model,
    String sourcePath, {
    void Function(double fraction)? onProgress,
  }) async {
    final destination = pathFor(model);
    if (destination == null) {
      throw ArgumentError('${model.name} does not use a model file');
    }
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('Model file not found', sourcePath);
    }
    await paths.models.create(recursive: true);

    // Stream the copy and report progress: these files run to hundreds of
    // megabytes and a silent multi-second pause reads as a hang.
    final total = await source.length();
    final sink = File('$destination.part').openWrite();
    var written = 0;
    try {
      await for (final chunk in source.openRead()) {
        sink.add(chunk);
        written += chunk.length;
        if (total > 0) onProgress?.call(written / total);
      }
    } finally {
      await sink.close();
    }
    await File('$destination.part').rename(destination);
    return installationOf(model);
  }

  Future<void> remove(SeparationModel model) async {
    final path = pathFor(model);
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  /// Bytes used by installed models (NFR-RES-01).
  Future<int> sizeBytes() => AppPaths.directorySize(paths.models);
}
