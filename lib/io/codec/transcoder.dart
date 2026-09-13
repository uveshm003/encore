import '../../core/audio_buffer.dart';
import '../audio_file_format.dart';

/// What a backend could work out about a media file.
class AudioFileInfo {
  const AudioFileInfo({
    required this.path,
    required this.format,
    required this.sampleRate,
    required this.channelCount,
    required this.frameCount,
    required this.duration,
  });

  final String path;
  final AudioFileFormat format;
  final int sampleRate;
  final int channelCount;
  final int frameCount;
  final Duration duration;

  String get title => AudioFileFormat.titleOf(path);

  AudioFileInfo copyWith({
    String? path,
    AudioFileFormat? format,
    int? sampleRate,
    int? channelCount,
    int? frameCount,
    Duration? duration,
  }) {
    return AudioFileInfo(
      path: path ?? this.path,
      format: format ?? this.format,
      sampleRate: sampleRate ?? this.sampleRate,
      channelCount: channelCount ?? this.channelCount,
      frameCount: frameCount ?? this.frameCount,
      duration: duration ?? this.duration,
    );
  }
}

/// Converts between compressed media files and canonical float32 WAV.
///
/// Every backend speaks the same two-step protocol — *anything to WAV* and
/// *WAV to anything* — so the rest of the app only ever deals with WAV and with
/// [AudioBuffer]. Backends are ranked by [priority] and probed at runtime, so
/// the app works with whatever the host actually provides (IMP-02).
abstract class Transcoder {
  /// Short identifier used in logs and in the settings screen.
  String get name;

  /// Higher wins when several backends can handle the same format.
  int get priority;

  /// Whether this backend can run at all on this machine.
  Future<bool> isAvailable();

  Future<Set<AudioFileFormat>> decodableFormats();

  Future<Set<AudioFileFormat>> encodableFormats();

  /// Reads metadata without decoding the audio.
  Future<AudioFileInfo> probe(String path);

  /// Writes [source] to [destination] as 32-bit float WAV, optionally
  /// resampling and remixing on the way.
  Future<AudioFileInfo> decodeToWav({
    required String source,
    required String destination,
    int? sampleRate,
    int? channelCount,
  });

  /// Encodes a float WAV at [source] into [format].
  Future<void> encodeFromWav({
    required String source,
    required String destination,
    required AudioFileFormat format,
    required int bitRate,
    int? sampleRate,
  });
}

/// Convenience for backends that build an [AudioFileInfo] from raw numbers.
AudioFileInfo audioFileInfo({
  required String path,
  required int sampleRate,
  required int channelCount,
  required int frameCount,
  AudioFileFormat? format,
}) {
  return AudioFileInfo(
    path: path,
    format: format ?? AudioFileFormat.fromPath(path),
    sampleRate: sampleRate,
    channelCount: channelCount,
    frameCount: frameCount,
    duration: sampleRate > 0
        ? framesToDuration(frameCount, sampleRate)
        : Duration.zero,
  );
}
