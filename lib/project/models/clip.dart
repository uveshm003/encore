import 'dart:math' as math;

/// A window onto an [AudioAsset] placed at a position on the timeline.
///
/// Trimming moves [assetOffset]/[length], splitting produces two clips over the
/// same asset, and fades are stored as frame counts — none of which touch the
/// underlying audio (EDIT-01, EDIT-02, EDIT-03).
class Clip {
  const Clip({
    required this.id,
    required this.assetId,
    required this.timelineStart,
    required this.assetOffset,
    required this.length,
    this.gain = 1.0,
    this.fadeInFrames = 0,
    this.fadeOutFrames = 0,
  });

  final String id;
  final String assetId;

  /// First frame of this clip on the project timeline.
  final int timelineStart;

  /// First frame of the source asset this clip plays.
  final int assetOffset;

  /// Length in frames.
  final int length;

  /// Clip-level gain, multiplied with the track gain.
  final double gain;
  final int fadeInFrames;
  final int fadeOutFrames;

  /// One past the last frame on the timeline.
  int get timelineEnd => timelineStart + length;

  bool get isEmpty => length <= 0;

  /// Whether this clip has audio anywhere in `[start, end)`.
  bool intersects(int start, int end) =>
      timelineStart < end && timelineEnd > start;

  /// The fade envelope at [frame] frames into the clip.
  ///
  /// Fades are linear, and are clamped so that overlapping fade in/out regions
  /// on a very short clip still produce a smooth, monotonic envelope.
  double envelopeAt(int frame) {
    if (length <= 0) return 0.0;
    var envelope = 1.0;
    final fadeIn = math.min(fadeInFrames, length);
    final fadeOut = math.min(fadeOutFrames, length);
    if (fadeIn > 0 && frame < fadeIn) {
      envelope *= (frame + 0.5) / fadeIn;
    }
    if (fadeOut > 0) {
      final remaining = length - frame;
      if (remaining <= fadeOut) {
        envelope *= (remaining - 0.5) / fadeOut;
      }
    }
    return envelope.clamp(0.0, 1.0);
  }

  Clip copyWith({
    String? id,
    String? assetId,
    int? timelineStart,
    int? assetOffset,
    int? length,
    double? gain,
    int? fadeInFrames,
    int? fadeOutFrames,
  }) {
    return Clip(
      id: id ?? this.id,
      assetId: assetId ?? this.assetId,
      timelineStart: timelineStart ?? this.timelineStart,
      assetOffset: assetOffset ?? this.assetOffset,
      length: length ?? this.length,
      gain: gain ?? this.gain,
      fadeInFrames: fadeInFrames ?? this.fadeInFrames,
      fadeOutFrames: fadeOutFrames ?? this.fadeOutFrames,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'assetId': assetId,
    'timelineStart': timelineStart,
    'assetOffset': assetOffset,
    'length': length,
    'gain': gain,
    'fadeInFrames': fadeInFrames,
    'fadeOutFrames': fadeOutFrames,
  };

  static Clip fromJson(Map<String, Object?> json) {
    return Clip(
      id: json['id'] as String,
      assetId: json['assetId'] as String,
      timelineStart: (json['timelineStart'] as num).toInt(),
      assetOffset: (json['assetOffset'] as num).toInt(),
      length: (json['length'] as num).toInt(),
      gain: (json['gain'] as num?)?.toDouble() ?? 1.0,
      fadeInFrames: (json['fadeInFrames'] as num?)?.toInt() ?? 0,
      fadeOutFrames: (json['fadeOutFrames'] as num?)?.toInt() ?? 0,
    );
  }
}
