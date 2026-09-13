/// Master bus state (MIX-01, MIX-04).
class MixSettings {
  const MixSettings({
    this.masterGain = 1.0,
    this.limiterEnabled = true,
    this.limiterCeilingDb = -0.3,
  });

  final double masterGain;

  /// The export limiter is on by default: an unattended bounce that clips is
  /// worse than one that is a fraction of a dB quieter.
  final bool limiterEnabled;

  /// Ceiling the limiter holds, in dBFS.
  final double limiterCeilingDb;

  MixSettings copyWith({
    double? masterGain,
    bool? limiterEnabled,
    double? limiterCeilingDb,
  }) {
    return MixSettings(
      masterGain: masterGain ?? this.masterGain,
      limiterEnabled: limiterEnabled ?? this.limiterEnabled,
      limiterCeilingDb: limiterCeilingDb ?? this.limiterCeilingDb,
    );
  }

  Map<String, Object?> toJson() => {
    'masterGain': masterGain,
    'limiterEnabled': limiterEnabled,
    'limiterCeilingDb': limiterCeilingDb,
  };

  static MixSettings fromJson(Map<String, Object?> json) {
    return MixSettings(
      masterGain: (json['masterGain'] as num?)?.toDouble() ?? 1.0,
      limiterEnabled: json['limiterEnabled'] as bool? ?? true,
      limiterCeilingDb:
          (json['limiterCeilingDb'] as num?)?.toDouble() ?? -0.3,
    );
  }
}
