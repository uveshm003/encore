import 'package:flutter/foundation.dart';

import '../core/audio_buffer.dart';
import '../core/dsp/level_meter.dart';
import 'engine_config.dart';
import 'latency.dart';
import 'mix_graph.dart';

/// Everything the UI needs to know about where the transport is.
class TransportState {
  const TransportState({
    this.isPlaying = false,
    this.isRecording = false,
    this.positionFrames = 0,
    this.loopEnabled = false,
    this.loopStart = 0,
    this.loopEnd = 0,
    this.countInRemainingFrames = 0,
    this.endFrame = 0,
  });

  final bool isPlaying;
  final bool isRecording;

  /// Where the audio being heard right now sits on the timeline. This trails
  /// the position being rendered by the output buffer depth, so the playhead
  /// lines up with what the user is actually hearing.
  final int positionFrames;

  final bool loopEnabled;
  final int loopStart;
  final int loopEnd;

  /// Frames of count-in still to play before the take begins (PLAY-06).
  final int countInRemainingFrames;

  /// One past the last frame that has audio.
  final int endFrame;

  bool get isCountingIn => countInRemainingFrames > 0;

  Duration position(int sampleRate) =>
      framesToDuration(positionFrames, sampleRate);

  TransportState copyWith({
    bool? isPlaying,
    bool? isRecording,
    int? positionFrames,
    bool? loopEnabled,
    int? loopStart,
    int? loopEnd,
    int? countInRemainingFrames,
    int? endFrame,
  }) {
    return TransportState(
      isPlaying: isPlaying ?? this.isPlaying,
      isRecording: isRecording ?? this.isRecording,
      positionFrames: positionFrames ?? this.positionFrames,
      loopEnabled: loopEnabled ?? this.loopEnabled,
      loopStart: loopStart ?? this.loopStart,
      loopEnd: loopEnd ?? this.loopEnd,
      countInRemainingFrames:
          countInRemainingFrames ?? this.countInRemainingFrames,
      endFrame: endFrame ?? this.endFrame,
    );
  }
}

/// A finished recording pass, already placed in time.
class RecordedTake {
  const RecordedTake({
    required this.audio,
    required this.timelineStart,
    required this.compensationFrames,
  });

  final AudioBuffer audio;

  /// Where the take belongs on the timeline, after latency compensation.
  final int timelineStart;

  /// How far the take was moved earlier to line it up (REC-04).
  final int compensationFrames;

  Duration get duration => audio.duration;
}

/// The real-time side of the app.
///
/// Deliberately an interface: §6.2 leaves the engine technology open, and the
/// rest of the app is written against this contract so a native engine can
/// replace the Dart one without touching the UI, the project model or the
/// separation pipeline.
abstract class AudioEngine implements Listenable {
  EngineConfig get config;

  ValueListenable<TransportState> get transport;

  /// Master bus level, for the output meter.
  ValueListenable<LevelReading> get outputLevel;

  /// Live input level, including clip detection (REC-07).
  ValueListenable<LevelReading> get inputLevel;

  LatencySettings get latency;

  set latency(LatencySettings value);

  /// Opens the output device.
  Future<void> start();

  /// Closes devices and releases buffers.
  Future<void> shutdown();

  /// Replaces the graph being played (PLAY-02, PLAY-03).
  void setGraph(List<GraphTrack> tracks);

  void setMaster({double? gain, bool? limiterEnabled, double? ceilingDb});

  void setMetronome({bool? enabled, double? tempoBpm, int? beatsPerBar});

  void setLoop({required bool enabled, int? start, int? end});

  void play();

  void pause();

  void stop();

  void seek(int frame);

  /// Begins a recording pass, optionally after a count-in (REC-01, REC-03).
  Future<void> startRecording({
    int countInBars = 0,
    int channelCount = 1,
    String? deviceId,
    bool monitor = false,
  });

  /// Ends the pass and returns the captured audio, or null if nothing was
  /// captured.
  Future<RecordedTake?> stopRecording();

  /// Measures the true round-trip delay of this device (REC-04).
  Future<LatencyMeasurement> calibrateLatency({String? deviceId});
}
