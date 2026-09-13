/// One recorded pass on a track (REC-05).
///
/// Takes are kept rather than overwritten so the performer can record several
/// attempts and pick the keeper afterwards. A take owns an asset; the track's
/// active take is the one whose clips are on the timeline.
class Take {
  const Take({
    required this.id,
    required this.assetId,
    required this.name,
    required this.recordedAt,
    required this.timelineStart,
    required this.length,
  });

  final String id;
  final String assetId;
  final String name;
  final DateTime recordedAt;

  /// Where on the timeline the take was captured, already latency-compensated.
  final int timelineStart;
  final int length;

  Take copyWith({
    String? id,
    String? assetId,
    String? name,
    DateTime? recordedAt,
    int? timelineStart,
    int? length,
  }) {
    return Take(
      id: id ?? this.id,
      assetId: assetId ?? this.assetId,
      name: name ?? this.name,
      recordedAt: recordedAt ?? this.recordedAt,
      timelineStart: timelineStart ?? this.timelineStart,
      length: length ?? this.length,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'assetId': assetId,
    'name': name,
    'recordedAt': recordedAt.toIso8601String(),
    'timelineStart': timelineStart,
    'length': length,
  };

  static Take fromJson(Map<String, Object?> json) {
    return Take(
      id: json['id'] as String,
      assetId: json['assetId'] as String,
      name: json['name'] as String,
      recordedAt:
          DateTime.tryParse(json['recordedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      timelineStart: (json['timelineStart'] as num).toInt(),
      length: (json['length'] as num).toInt(),
    );
  }
}
