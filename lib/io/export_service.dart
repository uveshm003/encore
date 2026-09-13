import 'dart:io';

import '../core/audio_buffer.dart';
import '../core/dsp/resampler.dart';
import '../engine/mix_graph.dart';
import '../engine/offline_renderer.dart';
import '../project/models/project.dart';
import '../project/project_graph.dart';
import '../storage/app_paths.dart';
import 'audio_file_format.dart';
import 'codec/codec_exception.dart';
import 'codec/codec_registry.dart';
import 'codec/wav_codec.dart';

/// Sample format for uncompressed exports.
enum ExportBitDepth {
  pcm16('16-bit'),
  pcm24('24-bit'),
  float32('32-bit float');

  const ExportBitDepth(this.displayName);

  final String displayName;

  WavBitDepth get wav => switch (this) {
    ExportBitDepth.pcm16 => WavBitDepth.pcm16,
    ExportBitDepth.pcm24 => WavBitDepth.pcm24,
    ExportBitDepth.float32 => WavBitDepth.float32,
  };
}

/// What to write and how (MIX-02).
class ExportSettings {
  const ExportSettings({
    this.format = AudioFileFormat.wav,
    this.sampleRate = 48000,
    this.bitRate = 256000,
    this.bitDepth = ExportBitDepth.pcm16,
  });

  final AudioFileFormat format;
  final int sampleRate;

  /// Bits per second for compressed formats.
  final int bitRate;

  /// Sample format for uncompressed formats.
  final ExportBitDepth bitDepth;

  bool get isCompressed =>
      format != AudioFileFormat.wav && format != AudioFileFormat.aiff;

  /// Bit rates offered for compressed formats.
  static const List<int> bitRateChoices = [
    128000,
    192000,
    256000,
    320000,
  ];

  static const List<int> sampleRateChoices = [44100, 48000];

  ExportSettings copyWith({
    AudioFileFormat? format,
    int? sampleRate,
    int? bitRate,
    ExportBitDepth? bitDepth,
  }) {
    return ExportSettings(
      format: format ?? this.format,
      sampleRate: sampleRate ?? this.sampleRate,
      bitRate: bitRate ?? this.bitRate,
      bitDepth: bitDepth ?? this.bitDepth,
    );
  }

  /// The extension a file written with these settings should carry.
  String get extension => format.extensions.first;
}

/// One written file.
class ExportResult {
  const ExportResult({
    required this.path,
    required this.format,
    required this.sizeBytes,
    required this.duration,
  });

  final String path;
  final AudioFileFormat format;
  final int sizeBytes;
  final Duration duration;

  String get fileName => path.split(Platform.pathSeparator).last;
}

/// Renders and writes finished audio (MIX-01, MIX-02, MIX-03).
///
/// The mix is produced by the same graph the engine plays, through the same
/// master limiter (MIX-04), then handed to whichever codec backend can write
/// the chosen format. Everything happens on-device: nothing is uploaded and no
/// service is contacted (NFR-OFF-01, NFR-OFF-02).
class ExportService {
  const ExportService({
    required this.codecs,
    required this.paths,
    this.renderer = const OfflineRenderer(),
    this.resampler = const Resampler(),
  });

  final CodecRegistry codecs;
  final AppPaths paths;
  final OfflineRenderer renderer;
  final Resampler resampler;

  /// Formats that can actually be written on this device.
  ///
  /// MP3 in particular depends on an encoder being available (see
  /// `FfmpegTranscoder`), so the export screen offers what is really there
  /// rather than failing at the end of a long render.
  List<AudioFileFormat> availableFormats() {
    const preferred = [
      AudioFileFormat.wav,
      AudioFileFormat.mp3,
      AudioFileFormat.m4a,
      AudioFileFormat.aac,
      AudioFileFormat.flac,
      AudioFileFormat.aiff,
    ];
    return preferred.where(codecs.canEncode).toList();
  }

  /// Renders the whole project to a single file.
  Future<ExportResult> exportMix({
    required Project project,
    required Map<String, AudioBuffer> buffers,
    required ExportSettings settings,
    required String destinationPath,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final graph = MixGraph(
      sampleRate: project.sampleRate,
      channelCount: project.channelCount,
    )..tracks = ProjectGraph.build(project, buffers);

    final end = graph.endFrame;
    if (end <= 0) {
      throw const CodecException(
        CodecErrorKind.unknown,
        'There is nothing to export yet — add some audio first.',
      );
    }

    // Rendering is the long part; encoding is comparatively quick, so the
    // progress bar gives it the last tenth.
    final mixed = await renderer.renderMix(
      graph,
      startFrame: 0,
      endFrame: end,
      masterGain: project.mix.masterGain,
      limiterEnabled: project.mix.limiterEnabled,
      ceilingLinear: dbToAmplitude(project.mix.limiterCeilingDb),
      onProgress: (progress) => onProgress?.call(progress * 0.9),
      isCancelled: isCancelled,
    );

    return _write(
      buffer: mixed,
      settings: settings,
      destinationPath: destinationPath,
      onProgress: (progress) => onProgress?.call(0.9 + progress * 0.1),
    );
  }

  /// Renders each track to its own file (MIX-03).
  Future<List<ExportResult>> exportStems({
    required Project project,
    required Map<String, AudioBuffer> buffers,
    required ExportSettings settings,
    required String destinationDirectory,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final graph = MixGraph(
      sampleRate: project.sampleRate,
      channelCount: project.channelCount,
    )..tracks = ProjectGraph.build(project, buffers);
    final end = graph.endFrame;
    if (end <= 0) {
      throw const CodecException(
        CodecErrorKind.unknown,
        'There is nothing to export yet — add some audio first.',
      );
    }

    await Directory(destinationDirectory).create(recursive: true);
    final results = <ExportResult>[];
    final tracks = project.tracks.where((track) => track.clips.isNotEmpty);
    final total = tracks.length;
    var index = 0;

    for (final track in tracks) {
      if (isCancelled?.call() ?? false) throw const RenderCancelled();
      final rendered = await renderer.renderTrack(
        graph,
        ProjectGraph.buildTrack(project, track, buffers),
        startFrame: 0,
        endFrame: end,
        onProgress: (progress) =>
            onProgress?.call((index + progress) / total),
        isCancelled: isCancelled,
      );
      final name = _safeFileName(track.name);
      results.add(await _write(
        buffer: rendered,
        settings: settings,
        destinationPath:
            '$destinationDirectory${Platform.pathSeparator}$name.${settings.extension}',
      ));
      index++;
      onProgress?.call(index / total);
    }
    return results;
  }

  /// Default location and name for an export.
  Future<String> suggestedPath(Project project, ExportSettings settings) async {
    await paths.exports.create(recursive: true);
    final name = _safeFileName(project.name);
    return '${paths.exports.path}${Platform.pathSeparator}$name.${settings.extension}';
  }

  Future<ExportResult> _write({
    required AudioBuffer buffer,
    required ExportSettings settings,
    required String destinationPath,
    void Function(double progress)? onProgress,
  }) async {
    var output = buffer;
    if (settings.sampleRate != buffer.sampleRate) {
      output = resampler.resample(buffer, settings.sampleRate);
    }
    onProgress?.call(0.3);

    if (settings.format == AudioFileFormat.wav) {
      await WavCodec.write(destinationPath, output, depth: settings.bitDepth.wav);
    } else {
      // Everything else goes through a float WAV, which is the interchange
      // format every codec backend understands.
      final temporary =
          '${paths.temp.path}${Platform.pathSeparator}export-${DateTime.now().microsecondsSinceEpoch}.wav';
      await WavCodec.write(temporary, output, depth: WavBitDepth.float32);
      try {
        await codecs.encodeFromWav(
          source: temporary,
          destination: destinationPath,
          format: settings.format,
          bitRate: settings.bitRate,
          sampleRate: settings.sampleRate,
        );
      } finally {
        final scratch = File(temporary);
        if (await scratch.exists()) await scratch.delete();
      }
    }
    onProgress?.call(1.0);

    final file = File(destinationPath);
    return ExportResult(
      path: destinationPath,
      format: settings.format,
      sizeBytes: await file.exists() ? await file.length() : 0,
      duration: output.duration,
    );
  }

  static String _safeFileName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? 'Untitled' : cleaned;
  }
}
