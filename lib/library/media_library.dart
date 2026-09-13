import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/audio_buffer.dart';
import '../core/waveform.dart';
import '../engine/engine_config.dart';
import '../io/audio_file_format.dart';
import '../io/codec/codec_exception.dart';
import '../io/codec/codec_registry.dart';
import '../io/codec/wav_codec.dart';
import '../storage/app_paths.dart';
import '../storage/file_key.dart';
import 'media_item.dart';

/// Stages an import moves through, so the UI can say what is happening rather
/// than showing an unexplained spinner.
enum ImportStage { reading, decoding, analysing, complete }

/// Progress of a single import.
class ImportProgress {
  const ImportProgress({
    required this.stage,
    required this.fraction,
    required this.fileName,
  });

  final ImportStage stage;

  /// 0..1 within the whole import, or -1 when the stage cannot report a rate.
  final double fraction;
  final String fileName;

  String get description => switch (stage) {
    ImportStage.reading => 'Reading $fileName',
    ImportStage.decoding => 'Decoding $fileName',
    ImportStage.analysing => 'Analysing $fileName',
    ImportStage.complete => 'Imported $fileName',
  };
}

/// The imported-song library (LIB-01, IMP-01…06).
///
/// Importing decodes the source once into a canonical float WAV at the engine's
/// rate and keeps a waveform envelope beside it. Re-importing a file that has
/// already been decoded — recognised by content, not by path — returns the
/// existing entry instead of doing the work again.
class MediaLibrary extends ChangeNotifier {
  MediaLibrary({
    required this.paths,
    required this.codecs,
    this.config = const EngineConfig(),
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final AppPaths paths;
  final CodecRegistry codecs;
  final EngineConfig config;
  final Uuid _uuid;

  final List<MediaItem> _items = [];
  bool _loaded = false;

  /// Newest first.
  List<MediaItem> get items => List.unmodifiable(_items);

  bool get isLoaded => _loaded;

  MediaItem? itemById(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  String audioPathFor(MediaItem item) =>
      '${paths.libraryItem(item.id).path}/audio.wav';

  String peaksPathFor(MediaItem item) =>
      '${paths.libraryItem(item.id).path}/peaks.bin';

  /// Reads the index from disk. A damaged index is rebuilt rather than fatal.
  Future<void> load() async {
    if (_loaded) return;
    _items.clear();
    final file = paths.libraryIndex;
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        final entries = (decoded as Map<String, Object?>)['items'];
        if (entries is List) {
          for (final entry in entries) {
            _items.add(MediaItem.fromJson(entry as Map<String, Object?>));
          }
        }
      } on Object {
        // A corrupt index would otherwise lock the user out of the app; the
        // audio files themselves are still on disk and can be re-imported.
        _items.clear();
      }
    }
    // Drop entries whose decoded audio has gone missing so the list never
    // offers something that cannot be opened.
    _items.removeWhere((item) => !File(audioPathFor(item)).existsSync());
    _sort();
    _loaded = true;
    notifyListeners();
  }

  /// Imports one file (IMP-01, IMP-02, IMP-05).
  ///
  /// Throws [CodecException] with a message suitable to show the user when the
  /// file cannot be read (IMP-04).
  Future<MediaItem> import(
    String sourcePath, {
    void Function(ImportProgress progress)? onProgress,
  }) async {
    await load();
    final fileName = sourcePath.split(Platform.pathSeparator).last;
    void report(ImportStage stage, double fraction) =>
        onProgress?.call(ImportProgress(
          stage: stage,
          fraction: fraction,
          fileName: fileName,
        ));

    report(ImportStage.reading, 0.0);
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw CodecException(
        CodecErrorKind.notFound,
        'That file could not be found.',
        path: sourcePath,
      );
    }

    final sourceInfo = await codecs.probe(sourcePath);
    final sourceKey = await FileKey.forFile(sourcePath);

    final existing = _items.where((item) => item.sourceKey == sourceKey);
    if (existing.isNotEmpty) {
      report(ImportStage.complete, 1.0);
      return existing.first;
    }

    final id = _uuid.v4();
    final directory = paths.libraryItem(id);
    await directory.create(recursive: true);
    final destination = '${directory.path}/audio.wav';

    report(ImportStage.decoding, 0.1);
    try {
      final decoded = await codecs.decodeToWav(
        source: sourcePath,
        destination: destination,
        sampleRate: config.sampleRate,
        channelCount: config.channelCount,
      );

      report(ImportStage.analysing, 0.75);
      await _writePeaks(destination, '${directory.path}/peaks.bin');

      final item = MediaItem(
        id: id,
        title: AudioFileFormat.titleOf(sourcePath),
        sourcePath: sourcePath,
        sourceKey: sourceKey,
        sourceFormat: sourceInfo.format,
        sourceSampleRate: sourceInfo.sampleRate,
        sourceChannelCount: sourceInfo.channelCount,
        sampleRate: decoded.sampleRate,
        channelCount: decoded.channelCount,
        frameCount: decoded.frameCount,
        importedAt: DateTime.now(),
      );
      _items.add(item);
      _sort();
      await _saveIndex();
      report(ImportStage.complete, 1.0);
      notifyListeners();
      return item;
    } on Object {
      // Never leave a half-written entry behind for the next launch to find.
      await _deleteQuietly(directory);
      rethrow;
    }
  }

  /// Imports several files, collecting per-file failures rather than aborting
  /// the whole batch on the first bad file (IMP-06).
  Future<BatchImportResult> importAll(
    List<String> sourcePaths, {
    void Function(ImportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final imported = <MediaItem>[];
    final failures = <String, CodecException>{};
    for (final path in sourcePaths) {
      if (isCancelled?.call() ?? false) break;
      try {
        imported.add(await import(path, onProgress: onProgress));
      } on CodecException catch (error) {
        failures[path] = error;
      }
    }
    return BatchImportResult(imported: imported, failures: failures);
  }

  Future<void> rename(String id, String title) async {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) return;
    _items[index] = _items[index].copyWith(title: title);
    await _saveIndex();
    notifyListeners();
  }

  /// Removes the item and its decoded audio. The user's original file is never
  /// touched.
  Future<void> delete(String id) async {
    _items.removeWhere((item) => item.id == id);
    await _deleteQuietly(paths.libraryItem(id));
    await _saveIndex();
    notifyListeners();
  }

  /// Loads a decoded track into memory.
  Future<AudioBuffer> loadAudio(MediaItem item) =>
      WavCodec.read(audioPathFor(item));

  /// Reads the cached envelope, recomputing it if the cache is missing.
  Future<WaveformPeaks> loadPeaks(MediaItem item) async {
    final file = File(peaksPathFor(item));
    if (await file.exists()) {
      final decoded = WaveformPeaks.decode(await file.readAsBytes());
      if (decoded != null) return decoded;
    }
    return _writePeaks(audioPathFor(item), peaksPathFor(item));
  }

  /// Bytes used by decoded library audio (NFR-RES-01).
  Future<int> storageSize() => AppPaths.directorySize(paths.library);

  Future<WaveformPeaks> _writePeaks(String wavPath, String peaksPath) async {
    final info = await WavCodec.readInfo(wavPath);
    final builder = WaveformPeaksBuilder(sampleRate: info.sampleRate);
    await for (final block in WavCodec.readBlocks(wavPath)) {
      builder.add(block);
    }
    final peaks = builder.build();
    final file = File(peaksPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(peaks.encode(), flush: true);
    return peaks;
  }

  Future<void> _saveIndex() async {
    final file = paths.libraryIndex;
    await file.parent.create(recursive: true);
    final payload = jsonEncode({
      'items': [for (final item in _items) item.toJson()],
    });
    // Write to a sibling first so an interrupted save cannot truncate the
    // existing index (NFR-RES-03).
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    await temporary.rename(file.path);
  }

  void _sort() {
    _items.sort((a, b) => b.importedAt.compareTo(a.importedAt));
  }

  static Future<void> _deleteQuietly(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException {
      // Best effort: a locked file is not worth failing the operation over.
    }
  }
}

/// Outcome of a batch import.
class BatchImportResult {
  const BatchImportResult({required this.imported, required this.failures});

  final List<MediaItem> imported;

  /// Source path to the reason it could not be imported.
  final Map<String, CodecException> failures;

  bool get hasFailures => failures.isNotEmpty;
}
