import 'dart:math' as math;

import 'clip.dart';
import 'take.dart';

/// What a track holds, which drives its default name, colour and icon.
enum TrackKind {
  instrumental('Instrumental'),
  vocals('Vocals'),
  drums('Drums'),
  bass('Bass'),
  other('Other'),
  recording('Recording'),
  reference('Reference');

  const TrackKind(this.displayName);

  final String displayName;

  /// Stems that separation produces, in the order they are shown.
  static List<TrackKind> get stemKinds => const [
    TrackKind.vocals,
    TrackKind.drums,
    TrackKind.bass,
    TrackKind.other,
  ];
}

/// A lane on the timeline: an ordered set of clips plus its mixer state.
class Track {
  const Track({
    required this.id,
    required this.name,
    required this.kind,
    this.clips = const [],
    this.takes = const [],
    this.activeTakeId,
    this.gain = 1.0,
    this.pan = 0.0,
    this.muted = false,
    this.soloed = false,
    this.recordArmed = false,
    this.monitorEnabled = false,
  });

  final String id;
  final String name;
  final TrackKind kind;
  final List<Clip> clips;

  /// Alternate recorded passes; only [activeTakeId] is on the timeline.
  final List<Take> takes;
  final String? activeTakeId;

  /// Linear gain (PLAY-03, MIX-01).
  final double gain;

  /// -1 hard left, 0 centre, +1 hard right (MIX-01).
  final double pan;
  final bool muted;
  final bool soloed;

  /// Whether a recording pass writes into this track (REC-01, REC-03).
  final bool recordArmed;

  /// Whether live input is folded into the monitor mix (REC-02).
  final bool monitorEnabled;

  bool get isEmpty => clips.isEmpty;

  /// One past the last frame of the last clip.
  int get endFrame =>
      clips.fold(0, (longest, clip) => math.max(longest, clip.timelineEnd));

  Take? get activeTake {
    final id = activeTakeId;
    if (id == null) return null;
    for (final take in takes) {
      if (take.id == id) return take;
    }
    return null;
  }

  Track copyWith({
    String? id,
    String? name,
    TrackKind? kind,
    List<Clip>? clips,
    List<Take>? takes,
    String? activeTakeId,
    bool clearActiveTake = false,
    double? gain,
    double? pan,
    bool? muted,
    bool? soloed,
    bool? recordArmed,
    bool? monitorEnabled,
  }) {
    return Track(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      clips: clips ?? this.clips,
      takes: takes ?? this.takes,
      activeTakeId: clearActiveTake ? null : (activeTakeId ?? this.activeTakeId),
      gain: gain ?? this.gain,
      pan: pan ?? this.pan,
      muted: muted ?? this.muted,
      soloed: soloed ?? this.soloed,
      recordArmed: recordArmed ?? this.recordArmed,
      monitorEnabled: monitorEnabled ?? this.monitorEnabled,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'clips': [for (final clip in clips) clip.toJson()],
    'takes': [for (final take in takes) take.toJson()],
    if (activeTakeId != null) 'activeTakeId': activeTakeId,
    'gain': gain,
    'pan': pan,
    'muted': muted,
    'soloed': soloed,
    'recordArmed': recordArmed,
    'monitorEnabled': monitorEnabled,
  };

  static Track fromJson(Map<String, Object?> json) {
    return Track(
      id: json['id'] as String,
      name: json['name'] as String,
      kind: TrackKind.values.firstWhere(
        (value) => value.name == json['kind'],
        orElse: () => TrackKind.other,
      ),
      clips: [
        for (final clip in (json['clips'] as List<Object?>? ?? const []))
          Clip.fromJson(clip as Map<String, Object?>),
      ],
      takes: [
        for (final take in (json['takes'] as List<Object?>? ?? const []))
          Take.fromJson(take as Map<String, Object?>),
      ],
      activeTakeId: json['activeTakeId'] as String?,
      gain: (json['gain'] as num?)?.toDouble() ?? 1.0,
      pan: (json['pan'] as num?)?.toDouble() ?? 0.0,
      muted: json['muted'] as bool? ?? false,
      soloed: json['soloed'] as bool? ?? false,
      recordArmed: json['recordArmed'] as bool? ?? false,
      monitorEnabled: json['monitorEnabled'] as bool? ?? false,
    );
  }
}
