import '../../core/audio_buffer.dart';

/// Where an asset's audio came from, which decides what the UI calls it and
/// whether deleting the project should delete the file.
enum AssetOrigin {
  /// Decoded from a file the user imported.
  imported,

  /// Produced by stem separation and living in the shared stem cache.
  separated,

  /// Captured by the recorder into the project folder.
  recorded,

  /// Rendered by the app (a bounce or a frozen edit).
  rendered,
}

/// An immutable on-disk float WAV that clips point into.
///
/// Assets are never modified once written. Every edit — trim, split, fade,
/// gain — is expressed as a clip that references a range of an asset, which is
/// what makes editing non-destructive and reversible (EDIT-03).
class AudioAsset {
  const AudioAsset({
    required this.id,
    required this.path,
    required this.origin,
    required this.sampleRate,
    required this.channelCount,
    required this.frameCount,
    this.label,
  });

  final String id;

  /// Absolute path, or a path relative to the project folder for assets the
  /// project owns (see `ProjectRepository`, which resolves these on load).
  final String path;
  final AssetOrigin origin;
  final int sampleRate;
  final int channelCount;
  final int frameCount;

  /// Optional human-readable name, e.g. "Instrumental" or "Take 2".
  final String? label;

  Duration get duration => framesToDuration(frameCount, sampleRate);

  AudioAsset copyWith({
    String? id,
    String? path,
    AssetOrigin? origin,
    int? sampleRate,
    int? channelCount,
    int? frameCount,
    String? label,
  }) {
    return AudioAsset(
      id: id ?? this.id,
      path: path ?? this.path,
      origin: origin ?? this.origin,
      sampleRate: sampleRate ?? this.sampleRate,
      channelCount: channelCount ?? this.channelCount,
      frameCount: frameCount ?? this.frameCount,
      label: label ?? this.label,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'path': path,
    'origin': origin.name,
    'sampleRate': sampleRate,
    'channelCount': channelCount,
    'frameCount': frameCount,
    if (label != null) 'label': label,
  };

  static AudioAsset fromJson(Map<String, Object?> json) {
    return AudioAsset(
      id: json['id'] as String,
      path: json['path'] as String,
      origin: AssetOrigin.values.firstWhere(
        (value) => value.name == json['origin'],
        orElse: () => AssetOrigin.imported,
      ),
      sampleRate: (json['sampleRate'] as num).toInt(),
      channelCount: (json['channelCount'] as num).toInt(),
      frameCount: (json['frameCount'] as num).toInt(),
      label: json['label'] as String?,
    );
  }
}
