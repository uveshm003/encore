import 'dart:math' as math;

import '../../core/audio_buffer.dart';
import 'audio_asset.dart';
import 'mix_settings.dart';
import 'track.dart';
import 'transport_settings.dart';

/// A saved session: tracks, the assets they play, edits and mix state
/// (PROJ-01, PROJ-02).
///
/// The whole model is immutable. Edits produce a new [Project] through
/// [copyWith], which is what makes snapshot undo/redo trivially correct
/// (EDIT-04) and makes saving a matter of serialising one object.
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.sampleRate,
    required this.createdAt,
    required this.modifiedAt,
    this.channelCount = 2,
    this.assets = const [],
    this.tracks = const [],
    this.mix = const MixSettings(),
    this.transport = const TransportSettings(),
    this.sourceMediaId,
    this.sourceTitle,
  });

  /// Bumped whenever the on-disk shape changes; `ProjectRepository` refuses to
  /// open anything newer than it understands rather than losing data.
  static const int schemaVersion = 1;

  final String id;
  final String name;

  /// Every asset and every clip in a project shares this rate, so timeline
  /// frames are directly comparable across tracks.
  final int sampleRate;
  final int channelCount;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final List<AudioAsset> assets;
  final List<Track> tracks;
  final MixSettings mix;
  final TransportSettings transport;

  /// The library item this project was created from, if any.
  final String? sourceMediaId;
  final String? sourceTitle;

  /// Length of the longest track, in frames.
  int get durationFrames =>
      tracks.fold(0, (longest, track) => math.max(longest, track.endFrame));

  Duration get duration => framesToDuration(durationFrames, sampleRate);

  bool get hasSolo => tracks.any((track) => track.soloed);

  /// Whether [track] should be heard, taking solo-overrides-mute into account
  /// the way every mixer does (PLAY-03).
  bool isAudible(Track track) {
    if (hasSolo) return track.soloed;
    return !track.muted;
  }

  AudioAsset? assetById(String id) {
    for (final asset in assets) {
      if (asset.id == id) return asset;
    }
    return null;
  }

  Track? trackById(String id) {
    for (final track in tracks) {
      if (track.id == id) return track;
    }
    return null;
  }

  /// Assets no track references any more — safe to delete from disk when the
  /// project is compacted.
  List<AudioAsset> get orphanedAssets {
    final referenced = <String>{};
    for (final track in tracks) {
      for (final clip in track.clips) {
        referenced.add(clip.assetId);
      }
      for (final take in track.takes) {
        referenced.add(take.assetId);
      }
    }
    return assets.where((asset) => !referenced.contains(asset.id)).toList();
  }

  Project copyWith({
    String? id,
    String? name,
    int? sampleRate,
    int? channelCount,
    DateTime? createdAt,
    DateTime? modifiedAt,
    List<AudioAsset>? assets,
    List<Track>? tracks,
    MixSettings? mix,
    TransportSettings? transport,
    String? sourceMediaId,
    String? sourceTitle,
  }) {
    return Project(
      id: id ?? this.id,
      name: name ?? this.name,
      sampleRate: sampleRate ?? this.sampleRate,
      channelCount: channelCount ?? this.channelCount,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      assets: assets ?? this.assets,
      tracks: tracks ?? this.tracks,
      mix: mix ?? this.mix,
      transport: transport ?? this.transport,
      sourceMediaId: sourceMediaId ?? this.sourceMediaId,
      sourceTitle: sourceTitle ?? this.sourceTitle,
    );
  }

  /// Replaces the track with the same id, leaving order untouched.
  Project withTrack(Track track) {
    final updated = [
      for (final existing in tracks)
        if (existing.id == track.id) track else existing,
    ];
    return copyWith(tracks: updated);
  }

  Project withAsset(AudioAsset asset) {
    final existing = assetById(asset.id);
    if (existing == null) {
      return copyWith(assets: [...assets, asset]);
    }
    return copyWith(
      assets: [
        for (final candidate in assets)
          if (candidate.id == asset.id) asset else candidate,
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'name': name,
    'sampleRate': sampleRate,
    'channelCount': channelCount,
    'createdAt': createdAt.toIso8601String(),
    'modifiedAt': modifiedAt.toIso8601String(),
    'assets': [for (final asset in assets) asset.toJson()],
    'tracks': [for (final track in tracks) track.toJson()],
    'mix': mix.toJson(),
    'transport': transport.toJson(),
    if (sourceMediaId != null) 'sourceMediaId': sourceMediaId,
    if (sourceTitle != null) 'sourceTitle': sourceTitle,
  };

  static Project fromJson(Map<String, Object?> json) {
    return Project(
      id: json['id'] as String,
      name: json['name'] as String,
      sampleRate: (json['sampleRate'] as num).toInt(),
      channelCount: (json['channelCount'] as num?)?.toInt() ?? 2,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      modifiedAt:
          DateTime.tryParse(json['modifiedAt'] as String? ?? '') ??
          DateTime.now(),
      assets: [
        for (final asset in (json['assets'] as List<Object?>? ?? const []))
          AudioAsset.fromJson(asset as Map<String, Object?>),
      ],
      tracks: [
        for (final track in (json['tracks'] as List<Object?>? ?? const []))
          Track.fromJson(track as Map<String, Object?>),
      ],
      mix: MixSettings.fromJson(
        (json['mix'] as Map<String, Object?>?) ?? const {},
      ),
      transport: TransportSettings.fromJson(
        (json['transport'] as Map<String, Object?>?) ?? const {},
      ),
      sourceMediaId: json['sourceMediaId'] as String?,
      sourceTitle: json['sourceTitle'] as String?,
    );
  }
}

/// The cheap-to-load view the project browser lists (LIB-01, PROJ-04).
class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.name,
    required this.modifiedAt,
    required this.duration,
    required this.trackCount,
    this.sourceTitle,
  });

  final String id;
  final String name;
  final DateTime modifiedAt;
  final Duration duration;
  final int trackCount;
  final String? sourceTitle;

  static ProjectSummary of(Project project) => ProjectSummary(
    id: project.id,
    name: project.name,
    modifiedAt: project.modifiedAt,
    duration: project.duration,
    trackCount: project.tracks.length,
    sourceTitle: project.sourceTitle,
  );
}
