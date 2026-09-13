import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/audio_buffer.dart';
import '../core/dsp/level_meter.dart';
import '../core/dsp/limiter.dart';
import '../core/dsp/resampler.dart';
import 'audio_engine.dart';
import 'audio_input.dart';
import 'audio_output.dart';
import 'engine_config.dart';
import 'latency.dart';
import 'metronome.dart';
import 'mix_graph.dart';

/// The default engine: a pull-driven mixing graph written in Dart.
///
/// Every output block is produced by walking the same graph at one timeline
/// position, so tracks are sample-locked to each other and to the transport
/// (PLAY-02). Playback, the metronome, monitoring and the master limiter all
/// meet in [_render], which is the only place audio is produced.
///
/// Rendering happens on the Dart isolate, ahead of the device, in response to
/// the output asking for more — never inside the platform's real-time callback
/// (C-03).
class PlaybackEngine extends ChangeNotifier implements AudioEngine {
  PlaybackEngine({
    this.config = const EngineConfig(),
    AudioOutput? output,
    AudioInput? input,
    Resampler? resampler,
  }) : _output = output ?? PcmSoundOutput(),
       _input = input ?? RecordAudioInput(),
       _resampler = resampler ?? const Resampler(),
       _metronome = Metronome(sampleRate: config.sampleRate) {
    _latency = LatencySettings.estimate(
      outputBufferFrames: config.outputBufferFrames,
      sampleRate: config.sampleRate,
    );
    _limiter = _buildLimiter();
    _graph = MixGraph(
      sampleRate: config.sampleRate,
      channelCount: config.channelCount,
    );
  }

  @override
  final EngineConfig config;

  final AudioOutput _output;
  final AudioInput _input;
  final Resampler _resampler;
  final Metronome _metronome;

  late final MixGraph _graph;
  late Limiter _limiter;

  final _transport = ValueNotifier<TransportState>(const TransportState());
  final _outputLevel = ValueNotifier<LevelReading>(LevelReading.silent);
  final _inputLevel = ValueNotifier<LevelReading>(LevelReading.silent);
  final _outputMeter = LevelMeter();
  final _inputMeter = LevelMeter();

  LatencySettings _latency = const LatencySettings();

  bool _playing = false;
  int _renderPosition = 0;
  bool _loopEnabled = false;
  int _loopStart = 0;
  int _loopEnd = 0;

  double _masterGain = 1.0;
  bool _limiterEnabled = true;
  double _ceilingDb = -0.3;

  // Recording state.
  StreamSubscription<AudioBuffer>? _captureSubscription;
  final List<AudioBuffer> _captureBlocks = [];
  int? _captureAnchorFrame;
  int _captureSampleRate = 0;
  bool _recording = false;
  int _recordStartFrame = 0;
  int _countInFrames = 0;
  bool _monitorEnabled = false;
  final List<AudioBuffer> _monitorQueue = [];

  // Calibration state.
  Float32List? _probe;
  int _probeCursor = 0;
  int? _probeRenderPosition;

  @override
  ValueListenable<TransportState> get transport => _transport;

  @override
  ValueListenable<LevelReading> get outputLevel => _outputLevel;

  @override
  ValueListenable<LevelReading> get inputLevel => _inputLevel;

  @override
  LatencySettings get latency => _latency;

  @override
  set latency(LatencySettings value) {
    _latency = value;
    notifyListeners();
  }

  @override
  Future<void> start() async {
    if (_output.isOpen) return;
    await _output.open(config, _render);
    _publishTransport();
  }

  @override
  Future<void> shutdown() async {
    await _stopCapture();
    await _output.close();
    _playing = false;
    _publishTransport();
  }

  @override
  void setGraph(List<GraphTrack> tracks) {
    _graph.tracks = tracks;
    _publishTransport();
  }

  @override
  void setMaster({double? gain, bool? limiterEnabled, double? ceilingDb}) {
    if (gain != null) _masterGain = gain;
    if (limiterEnabled != null) _limiterEnabled = limiterEnabled;
    if (ceilingDb != null && ceilingDb != _ceilingDb) {
      _ceilingDb = ceilingDb;
      _limiter = _buildLimiter();
    }
  }

  @override
  void setMetronome({bool? enabled, double? tempoBpm, int? beatsPerBar}) {
    if (enabled != null) _metronome.enabled = enabled;
    if (tempoBpm != null) _metronome.tempoBpm = tempoBpm;
    if (beatsPerBar != null) _metronome.beatsPerBar = beatsPerBar;
  }

  @override
  void setLoop({required bool enabled, int? start, int? end}) {
    _loopEnabled = enabled;
    if (start != null) _loopStart = math.max(0, start);
    if (end != null) _loopEnd = math.max(0, end);
    _publishTransport();
  }

  @override
  void play() {
    if (_playing) return;
    _playing = true;
    _limiter.reset();
    _publishTransport();
  }

  @override
  void pause() {
    if (!_playing) return;
    _playing = false;
    _publishTransport();
  }

  @override
  void stop() {
    _playing = false;
    _renderPosition = _loopEnabled && _loopEnd > _loopStart ? _loopStart : 0;
    _limiter.reset();
    _monitorQueue.clear();
    _publishTransport();
  }

  @override
  void seek(int frame) {
    _renderPosition = math.max(0, frame);
    _limiter.reset();
    _publishTransport();
  }

  @override
  Future<void> startRecording({
    int countInBars = 0,
    int channelCount = 1,
    String? deviceId,
    bool monitor = false,
  }) async {
    if (_recording) return;
    await start();

    _recordStartFrame = _renderPosition;
    _countInFrames = countInBars > 0
        ? _metronome.countInFrames(countInBars)
        : 0;
    // A count-in is just the transport running before the take's start point,
    // which keeps the click, the backing and the recording on one timeline.
    if (_countInFrames > 0) {
      _renderPosition = _recordStartFrame - _countInFrames;
    }

    _captureBlocks.clear();
    _captureAnchorFrame = null;
    _captureSampleRate = config.sampleRate;
    _monitorEnabled = monitor;
    _monitorQueue.clear();
    _inputMeter.reset();

    final stream = await _input.start(
      sampleRate: config.sampleRate,
      channelCount: channelCount,
      deviceId: deviceId,
    );
    _captureSubscription = stream.listen(
      _onCapture,
      onError: (Object error) {
        _recording = false;
        _publishTransport();
      },
    );

    _recording = true;
    _playing = true;
    _limiter.reset();
    _publishTransport();
  }

  @override
  Future<RecordedTake?> stopRecording() async {
    if (!_recording) return null;
    _recording = false;
    _playing = false;
    await _stopCapture();
    _publishTransport();

    if (_captureBlocks.isEmpty) return null;
    final captured = _concatenate(_captureBlocks, _captureSampleRate);
    _captureBlocks.clear();

    final aligned = captured.sampleRate == config.sampleRate
        ? captured
        : _resampler.resample(captured, config.sampleRate);

    final anchor = _captureAnchorFrame ?? _recordStartFrame;
    final compensation = _latency.compensationFrames;
    var start = anchor - compensation;

    // Trim anything captured before the take's start point — that is the
    // count-in, and it should not appear on the timeline.
    var audio = aligned;
    if (start < _recordStartFrame) {
      final trim = _recordStartFrame - start;
      if (trim >= audio.frameCount) return null;
      audio = audio.slice(trim, audio.frameCount - trim);
      start = _recordStartFrame;
    }

    return RecordedTake(
      audio: audio,
      timelineStart: math.max(0, start),
      compensationFrames: compensation,
    );
  }

  @override
  Future<LatencyMeasurement> calibrateLatency({String? deviceId}) async {
    await start();
    final calibrator = LatencyCalibrator(sampleRate: config.sampleRate);
    final probe = calibrator.buildProbe();

    final wasPlaying = _playing;
    _playing = false;
    _captureBlocks.clear();
    _captureAnchorFrame = null;
    _captureSampleRate = config.sampleRate;

    final stream = await _input.start(
      sampleRate: config.sampleRate,
      channelCount: 1,
      deviceId: deviceId,
    );
    final subscription = stream.listen(_onCapture);
    try {
      // Let the capture path settle and give the anchor a chance to be set
      // before the probe is emitted.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      _probe = probe;
      _probeCursor = 0;
      _probeRenderPosition = null;
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    } finally {
      _probe = null;
      await subscription.cancel();
      await _input.stop();
      _playing = wasPlaying;
    }

    final anchor = _captureAnchorFrame;
    final emittedAt = _probeRenderPosition;
    if (_captureBlocks.isEmpty || anchor == null || emittedAt == null) {
      return LatencyMeasurement(
        roundTripFrames: 0,
        confidence: 0,
        sampleRate: config.sampleRate,
      );
    }
    final recorded = _concatenate(_captureBlocks, _captureSampleRate).toMono();
    _captureBlocks.clear();

    return calibrator.measure(
      probe: probe,
      recorded: recorded.channels[0],
      // The recording began before the probe was emitted; that head start is
      // not part of the round trip.
      recordingStartFrame: anchor - emittedAt,
    );
  }

  /// Applies a measurement to the current settings.
  LatencySettings applyMeasurement(LatencyMeasurement measurement) {
    if (!measurement.isReliable) return _latency;
    // The round trip is what matters for alignment; the split between the two
    // directions is bookkeeping, so the known output queue is attributed to
    // output and the remainder to input.
    final outputFrames = math.min(
      config.outputBufferFrames,
      measurement.roundTripFrames,
    );
    return _latency.copyWith(
      outputFrames: outputFrames,
      inputFrames: measurement.roundTripFrames - outputFrames,
      manualOffsetFrames: 0,
      isCalibrated: true,
    );
  }

  // ---------------------------------------------------------------- rendering

  void _render(AudioBuffer destination) {
    final frames = destination.frameCount;

    if (_playing) {
      var offset = 0;
      while (offset < frames) {
        var chunk = frames - offset;
        final looping = _loopEnabled && _loopEnd > _loopStart;
        if (looping &&
            _renderPosition >= _loopStart &&
            _renderPosition < _loopEnd) {
          chunk = math.min(chunk, _loopEnd - _renderPosition);
        }
        _graph.render(
          _renderPosition,
          destination,
          destinationOffset: offset,
          frames: chunk,
        );
        _metronome.render(
          _renderPosition,
          destination,
          destinationOffset: offset,
          frames: chunk,
        );
        _renderPosition += chunk;
        offset += chunk;
        if (looping && _renderPosition >= _loopEnd) {
          _renderPosition = _loopStart;
        }
      }
      // Stop at the end of the material unless looping or recording, so
      // playback does not run on into silence forever.
      final end = _graph.endFrame;
      if (!_loopEnabled && !_recording && end > 0 && _renderPosition >= end) {
        _playing = false;
      }
    }

    _mixProbe(destination);
    if (_monitorEnabled) _mixMonitor(destination);

    if (_masterGain != 1.0) destination.applyGain(_masterGain);
    if (_limiterEnabled) _limiter.process(destination.channels);

    _outputLevel.value = _outputMeter.update(destination);
    _publishTransport();
  }

  /// Mixes the calibration sweep into the output and remembers exactly which
  /// render position it started at.
  void _mixProbe(AudioBuffer destination) {
    final probe = _probe;
    if (probe == null || _probeCursor >= probe.length) return;
    _probeRenderPosition ??= _renderPosition;
    final frames = math.min(
      destination.frameCount,
      probe.length - _probeCursor,
    );
    for (var i = 0; i < frames; i++) {
      final value = probe[_probeCursor + i];
      for (final channel in destination.channels) {
        channel[i] += value;
      }
    }
    _probeCursor += frames;
  }

  /// Folds live input into the output so the performer can hear themselves.
  ///
  /// This path runs through the capture stream and the output queue, so it
  /// carries the full round-trip delay: it is a fallback, and the interface
  /// says so. Hardware monitoring on an interface, or the device's own direct
  /// monitoring, is the low-latency answer (REC-02).
  void _mixMonitor(AudioBuffer destination) {
    var written = 0;
    while (written < destination.frameCount && _monitorQueue.isNotEmpty) {
      final block = _monitorQueue.first;
      final frames = math.min(destination.frameCount - written, block.frameCount);
      for (var ch = 0; ch < destination.channelCount; ch++) {
        final source = block.channels[ch % block.channelCount];
        final target = destination.channels[ch];
        for (var i = 0; i < frames; i++) {
          target[written + i] += source[i];
        }
      }
      if (frames >= block.frameCount) {
        _monitorQueue.removeAt(0);
      } else {
        _monitorQueue[0] = block.slice(frames, block.frameCount - frames);
      }
      written += frames;
    }
  }

  void _onCapture(AudioBuffer block) {
    _captureAnchorFrame ??= _renderPosition;
    _captureBlocks.add(block);
    _inputLevel.value = _inputMeter.update(block);
    if (_monitorEnabled) {
      // Bound the monitor queue: if rendering falls behind, dropping old
      // frames keeps monitoring live rather than letting the delay grow.
      if (_monitorQueue.length > config.bufferedBlocks + 2) {
        _monitorQueue.removeAt(0);
      }
      _monitorQueue.add(block);
    }
  }

  Future<void> _stopCapture() async {
    await _captureSubscription?.cancel();
    _captureSubscription = null;
    _monitorEnabled = false;
    _monitorQueue.clear();
    if (_input.isCapturing) await _input.stop();
  }

  Limiter _buildLimiter() {
    return Limiter(
      sampleRate: config.sampleRate,
      channelCount: config.channelCount,
      thresholdLinear: dbToAmplitude(_ceilingDb),
    );
  }

  void _publishTransport() {
    // The playhead shown is the audio being heard, which trails what has been
    // rendered by the depth of the output queue.
    final audible = _renderPosition - config.outputBufferFrames;
    final countInRemaining = _recording && _countInFrames > 0
        ? math.max(0, _recordStartFrame - audible)
        : 0;
    _transport.value = TransportState(
      isPlaying: _playing,
      isRecording: _recording,
      positionFrames: math.max(0, audible),
      loopEnabled: _loopEnabled,
      loopStart: _loopStart,
      loopEnd: _loopEnd,
      countInRemainingFrames: countInRemaining,
      endFrame: _graph.endFrame,
    );
  }

  static AudioBuffer _concatenate(List<AudioBuffer> blocks, int sampleRate) {
    if (blocks.isEmpty) {
      return AudioBuffer.silence(
        channelCount: 1,
        frameCount: 0,
        sampleRate: sampleRate,
      );
    }
    final channelCount = blocks.first.channelCount;
    var frames = 0;
    for (final block in blocks) {
      frames += block.frameCount;
    }
    final result = AudioBuffer.silence(
      channelCount: channelCount,
      frameCount: frames,
      sampleRate: blocks.first.sampleRate,
    );
    var offset = 0;
    for (final block in blocks) {
      for (var ch = 0; ch < channelCount; ch++) {
        result.channels[ch].setRange(
          offset,
          offset + block.frameCount,
          block.channels[ch % block.channelCount],
        );
      }
      offset += block.frameCount;
    }
    return result;
  }

  @override
  void dispose() {
    unawaited(shutdown());
    _transport.dispose();
    _outputLevel.dispose();
    _inputLevel.dispose();
    super.dispose();
  }
}
