import '../core/audio_buffer.dart';
import '../io/audio_file_format.dart';

/// A song the user imported, after it has been decoded once (LIB-01).
///
/// The original file is left exactly where the user keeps it — the app copies
/// nothing but its own canonical decode — and the source's sample rate and
/// channel count are retained as metadata (IMP-03) even though the working
/// copy is normalised to the engine's format.
class MediaItem {
  const MediaItem({
    required this.id,
    required this.title,
    required this.sourcePath,
    required this.sourceKey,
    required this.sourceFormat,
    required this.sourceSampleRate,
    required this.sourceChannelCount,
    required this.sampleRate,
    required this.channelCount,
    required this.frameCount,
    required this.importedAt,
  });

  final String id;
  final String title;

  /// Where the user's original file lives; may since have moved or been
  /// deleted, which is why the decode is kept separately.
  final String sourcePath;

  /// Content hash of the source, used to key the stem cache (§8).
  final String sourceKey;
  final AudioFileFormat sourceFormat;
  final int sourceSampleRate;
  final int sourceChannelCount;

  /// Format of the canonical decode.
  final int sampleRate;
  final int channelCount;
  final int frameCount;
  final DateTime importedAt;

  Duration get duration => framesToDuration(frameCount, sampleRate);

  /// True when the decode had to change rate or channel count, which the
  /// details panel surfaces so nothing about the conversion is hidden.
  bool get wasConverted =>
      sourceSampleRate != sampleRate || sourceChannelCount != channelCount;

  MediaItem copyWith({String? title}) {
    return MediaItem(
      id: id,
      title: title ?? this.title,
      sourcePath: sourcePath,
      sourceKey: sourceKey,
      sourceFormat: sourceFormat,
      sourceSampleRate: sourceSampleRate,
      sourceChannelCount: sourceChannelCount,
      sampleRate: sampleRate,
      channelCount: channelCount,
      frameCount: frameCount,
      importedAt: importedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'sourcePath': sourcePath,
    'sourceKey': sourceKey,
    'sourceFormat': sourceFormat.name,
    'sourceSampleRate': sourceSampleRate,
    'sourceChannelCount': sourceChannelCount,
    'sampleRate': sampleRate,
    'channelCount': channelCount,
    'frameCount': frameCount,
    'importedAt': importedAt.toIso8601String(),
  };

  static MediaItem fromJson(Map<String, Object?> json) {
    return MediaItem(
      id: json['id'] as String,
      title: json['title'] as String,
      sourcePath: json['sourcePath'] as String? ?? '',
      sourceKey: json['sourceKey'] as String? ?? '',
      sourceFormat: AudioFileFormat.values.firstWhere(
        (value) => value.name == json['sourceFormat'],
        orElse: () => AudioFileFormat.unknown,
      ),
      sourceSampleRate: (json['sourceSampleRate'] as num?)?.toInt() ?? 0,
      sourceChannelCount: (json['sourceChannelCount'] as num?)?.toInt() ?? 0,
      sampleRate: (json['sampleRate'] as num).toInt(),
      channelCount: (json['channelCount'] as num).toInt(),
      frameCount: (json['frameCount'] as num).toInt(),
      importedAt:
          DateTime.tryParse(json['importedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
