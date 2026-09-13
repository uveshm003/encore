import 'dart:convert';
import 'dart:io';

import '../audio_file_format.dart';
import 'codec_exception.dart';
import 'transcoder.dart';

/// Optional backend that shells out to an FFmpeg build on the host.
///
/// FFmpeg is what covers the formats Apple's frameworks will not read (Ogg
/// Vorbis, Opus, WMA) and it is the only way to *write* MP3. It is optional by
/// design: the requirement to bundle FFmpeg carries a licence review
/// (NFR-LEG-01), so until that lands the app discovers an installed binary and
/// simply reports MP3 export as unavailable when there isn't one.
///
/// Set `ENCORE_FFMPEG` / `ENCORE_FFPROBE` to point at a specific build.
class FfmpegTranscoder implements Transcoder {
  FfmpegTranscoder({List<String>? searchPaths})
    : _searchPaths = searchPaths ?? _defaultSearchPaths;

  static const List<String> _defaultSearchPaths = [
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '/usr/bin',
    '/opt/local/bin',
  ];

  final List<String> _searchPaths;

  String? _ffmpegPath;
  String? _ffprobePath;
  bool _resolved = false;

  @override
  String get name => 'FFmpeg';

  @override
  int get priority => 50;

  /// Where the binary was found, once [isAvailable] has run.
  String? get resolvedPath => _ffmpegPath;

  @override
  Future<bool> isAvailable() async {
    await _resolve();
    return _ffmpegPath != null;
  }

  @override
  Future<Set<AudioFileFormat>> decodableFormats() async {
    if (!await isAvailable()) return const {};
    // FFmpeg reads everything the app cares about.
    return AudioFileFormat.importable.toSet();
  }

  @override
  Future<Set<AudioFileFormat>> encodableFormats() async {
    if (!await isAvailable()) return const {};
    return const {
      AudioFileFormat.mp3,
      AudioFileFormat.wav,
      AudioFileFormat.flac,
      AudioFileFormat.m4a,
      AudioFileFormat.aac,
      AudioFileFormat.ogg,
      AudioFileFormat.opus,
    };
  }

  @override
  Future<AudioFileInfo> probe(String path) async {
    final probe = _ffprobePath;
    if (probe == null) {
      throw const CodecException(
        CodecErrorKind.noBackend,
        'ffprobe is not installed.',
      );
    }
    final result = await Process.run(probe, [
      '-v', 'error',
      '-select_streams', 'a:0',
      '-show_entries', 'stream=sample_rate,channels,duration_ts,time_base',
      '-show_entries', 'format=duration',
      '-of', 'json',
      path,
    ]);
    if (result.exitCode != 0) {
      throw CodecException(
        CodecErrorKind.corrupt,
        'This file could not be read.',
        path: path,
        details: result.stderr.toString(),
      );
    }
    final json = jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
    final streams = json['streams'] as List<dynamic>?;
    if (streams == null || streams.isEmpty) {
      throw CodecException(
        CodecErrorKind.unsupportedFormat,
        'This file contains no audio.',
        path: path,
      );
    }
    final stream = streams.first as Map<String, dynamic>;
    final sampleRate = int.tryParse('${stream['sample_rate']}') ?? 0;
    final channels = (stream['channels'] as num?)?.toInt() ?? 0;
    final format = json['format'] as Map<String, dynamic>?;
    final seconds = double.tryParse('${format?['duration']}') ?? 0.0;
    return audioFileInfo(
      path: path,
      sampleRate: sampleRate,
      channelCount: channels,
      frameCount: (seconds * sampleRate).round(),
    );
  }

  @override
  Future<AudioFileInfo> decodeToWav({
    required String source,
    required String destination,
    int? sampleRate,
    int? channelCount,
  }) async {
    await File(destination).parent.create(recursive: true);
    await _run([
      '-y',
      '-v', 'error',
      '-i', source,
      '-vn',
      if (sampleRate != null) ...['-ar', '$sampleRate'],
      if (channelCount != null) ...['-ac', '$channelCount'],
      '-c:a', 'pcm_f32le',
      '-f', 'wav',
      destination,
    ], source);
    return probeWav(destination);
  }

  /// Reads back what was actually written, so callers get true frame counts
  /// rather than the estimate from the source container.
  Future<AudioFileInfo> probeWav(String path) async {
    final info = await probe(path);
    return info.copyWith(format: AudioFileFormat.wav);
  }

  @override
  Future<void> encodeFromWav({
    required String source,
    required String destination,
    required AudioFileFormat format,
    required int bitRate,
    int? sampleRate,
  }) async {
    final codec = switch (format) {
      AudioFileFormat.mp3 => 'libmp3lame',
      AudioFileFormat.m4a || AudioFileFormat.aac => 'aac',
      AudioFileFormat.flac => 'flac',
      AudioFileFormat.ogg => 'libvorbis',
      AudioFileFormat.opus => 'libopus',
      AudioFileFormat.wav => 'pcm_s16le',
      _ => null,
    };
    if (codec == null) {
      throw CodecException(
        CodecErrorKind.unsupportedFormat,
        'FFmpeg cannot write ${format.displayName} here.',
        path: destination,
      );
    }
    await File(destination).parent.create(recursive: true);
    final lossless = codec == 'flac' || codec.startsWith('pcm_');
    await _run([
      '-y',
      '-v', 'error',
      '-i', source,
      if (sampleRate != null) ...['-ar', '$sampleRate'],
      '-c:a', codec,
      if (!lossless) ...['-b:a', '${bitRate ~/ 1000}k'],
      destination,
    ], destination);
  }

  Future<void> _run(List<String> arguments, String path) async {
    final ffmpeg = _ffmpegPath;
    if (ffmpeg == null) {
      throw const CodecException(
        CodecErrorKind.noBackend,
        'FFmpeg is not installed.',
      );
    }
    final result = await Process.run(ffmpeg, arguments);
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString();
      throw CodecException(
        stderr.contains('No such file') 
            ? CodecErrorKind.notFound
            : CodecErrorKind.corrupt,
        'FFmpeg could not process this file.',
        path: path,
        details: stderr,
      );
    }
  }

  Future<void> _resolve() async {
    if (_resolved) return;
    _resolved = true;
    _ffmpegPath = await _locate('ffmpeg', 'ENCORE_FFMPEG');
    _ffprobePath = await _locate('ffprobe', 'ENCORE_FFPROBE');
    // ffprobe is only used for metadata; ffmpeg alone is still useful.
    if (_ffmpegPath == null) _ffprobePath = null;
  }

  Future<String?> _locate(String binary, String environmentVariable) async {
    final override = Platform.environment[environmentVariable];
    if (override != null && override.isNotEmpty) {
      return await File(override).exists() ? override : null;
    }
    for (final directory in _searchPaths) {
      final candidate = '$directory/$binary';
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }
}
