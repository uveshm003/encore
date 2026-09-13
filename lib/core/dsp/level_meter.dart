import 'dart:math' as math;

import '../audio_buffer.dart';

/// A single level reading, in dBFS.
class LevelReading {
  const LevelReading({
    required this.peakDb,
    required this.rmsDb,
    required this.clipped,
  });

  static const LevelReading silent =
      LevelReading(peakDb: -120.0, rmsDb: -120.0, clipped: false);

  final double peakDb;
  final double rmsDb;

  /// True while a clip has been detected and has not yet been cleared
  /// (REC-07: the warning has to stay visible long enough to be noticed).
  final bool clipped;
}

/// Peak/RMS meter with a ballistic release and a latched clip indicator.
class LevelMeter {
  LevelMeter({
    this.releasePerSecondDb = 20.0,
    this.clipThreshold = 0.999,
    this.clipHold = const Duration(seconds: 2),
  });

  /// How fast the displayed peak falls back once the signal drops.
  final double releasePerSecondDb;
  final double clipThreshold;
  final Duration clipHold;

  double _peakDb = -120.0;
  double _rmsDb = -120.0;
  DateTime? _lastClip;
  DateTime? _lastUpdate;

  /// Feeds a block and returns the updated reading.
  LevelReading update(AudioBuffer block, {DateTime? now}) {
    final timestamp = now ?? DateTime.now();
    final elapsed = _lastUpdate == null
        ? 0.0
        : timestamp.difference(_lastUpdate!).inMicroseconds / 1000000.0;
    _lastUpdate = timestamp;

    final peak = block.peak();
    final rms = block.rms();
    if (peak >= clipThreshold) _lastClip = timestamp;

    final decay = elapsed * releasePerSecondDb;
    _peakDb = math.max(amplitudeToDb(peak), _peakDb - decay);
    _rmsDb = math.max(amplitudeToDb(rms), _rmsDb - decay);
    return reading(now: timestamp);
  }

  /// The current reading without feeding new audio.
  LevelReading reading({DateTime? now}) {
    final timestamp = now ?? DateTime.now();
    final clipped =
        _lastClip != null && timestamp.difference(_lastClip!) < clipHold;
    return LevelReading(peakDb: _peakDb, rmsDb: _rmsDb, clipped: clipped);
  }

  void reset() {
    _peakDb = -120.0;
    _rmsDb = -120.0;
    _lastClip = null;
    _lastUpdate = null;
  }

  /// Clears a latched clip indicator (the user acknowledging the warning).
  void clearClip() => _lastClip = null;
}
