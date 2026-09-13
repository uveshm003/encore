import '../../core/audio_buffer.dart';

/// Loop, metronome and count-in state (PLAY-04, PLAY-06).
class TransportSettings {
  const TransportSettings({
    this.loopEnabled = false,
    this.loopStart = 0,
    this.loopEnd = 0,
    this.tempoBpm = 120.0,
    this.beatsPerBar = 4,
    this.metronomeEnabled = false,
    this.countInBars = 1,
  });

  final bool loopEnabled;

  /// Loop region in frames at the project sample rate.
  final int loopStart;
  final int loopEnd;

  final double tempoBpm;
  final int beatsPerBar;
  final bool metronomeEnabled;

  /// Bars of clicks played before recording starts.
  final int countInBars;

  bool get hasLoopRegion => loopEnd > loopStart;

  int framesPerBeat(int sampleRate) =>
      (sampleRate * 60.0 / (tempoBpm <= 0 ? 120.0 : tempoBpm)).round();

  Duration loopDuration(int sampleRate) =>
      framesToDuration(loopEnd - loopStart, sampleRate);

  TransportSettings copyWith({
    bool? loopEnabled,
    int? loopStart,
    int? loopEnd,
    double? tempoBpm,
    int? beatsPerBar,
    bool? metronomeEnabled,
    int? countInBars,
  }) {
    return TransportSettings(
      loopEnabled: loopEnabled ?? this.loopEnabled,
      loopStart: loopStart ?? this.loopStart,
      loopEnd: loopEnd ?? this.loopEnd,
      tempoBpm: tempoBpm ?? this.tempoBpm,
      beatsPerBar: beatsPerBar ?? this.beatsPerBar,
      metronomeEnabled: metronomeEnabled ?? this.metronomeEnabled,
      countInBars: countInBars ?? this.countInBars,
    );
  }

  Map<String, Object?> toJson() => {
    'loopEnabled': loopEnabled,
    'loopStart': loopStart,
    'loopEnd': loopEnd,
    'tempoBpm': tempoBpm,
    'beatsPerBar': beatsPerBar,
    'metronomeEnabled': metronomeEnabled,
    'countInBars': countInBars,
  };

  static TransportSettings fromJson(Map<String, Object?> json) {
    return TransportSettings(
      loopEnabled: json['loopEnabled'] as bool? ?? false,
      loopStart: (json['loopStart'] as num?)?.toInt() ?? 0,
      loopEnd: (json['loopEnd'] as num?)?.toInt() ?? 0,
      tempoBpm: (json['tempoBpm'] as num?)?.toDouble() ?? 120.0,
      beatsPerBar: (json['beatsPerBar'] as num?)?.toInt() ?? 4,
      metronomeEnabled: json['metronomeEnabled'] as bool? ?? false,
      countInBars: (json['countInBars'] as num?)?.toInt() ?? 1,
    );
  }
}
