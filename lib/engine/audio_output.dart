import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../core/audio_buffer.dart';
import 'engine_config.dart';

/// Fills [destination] with the next block of audio. Called from the output's
/// feed loop; must return promptly.
typedef RenderCallback = void Function(AudioBuffer destination);

/// The device the engine writes to.
///
/// Abstracted so the mixing graph can be tested without any audio hardware,
/// and so the pull loop can be re-pointed at a native engine without the rest
/// of the app noticing (§6.2).
abstract class AudioOutput {
  Future<void> open(EngineConfig config, RenderCallback onRender);

  Future<void> close();

  bool get isOpen;

  /// Frames handed to the device so far. Used to work out how far behind the
  /// audible playhead is from the render position.
  int get framesRendered;
}

/// Output backed by `flutter_pcm_sound`, which queues 16-bit PCM to the
/// platform's own audio path (CoreAudio on macOS and iOS, AAudio on Android).
///
/// The plugin pulls: it calls back whenever its queue drops below a threshold
/// and the engine renders another block. Rendering therefore happens ahead of
/// playback on the Dart isolate and never inside the device's real-time
/// callback, which is what constraint C-03 requires.
class PcmSoundOutput implements AudioOutput {
  PcmSoundOutput();

  EngineConfig _config = const EngineConfig();
  RenderCallback? _onRender;
  AudioBuffer? _scratch;
  bool _open = false;
  int _framesRendered = 0;
  DateTime? _lastFeed;
  Timer? _watchdog;

  @override
  bool get isOpen => _open;

  @override
  int get framesRendered => _framesRendered;

  @override
  Future<void> open(EngineConfig config, RenderCallback onRender) async {
    if (_open) await close();
    _config = config;
    _onRender = onRender;
    _scratch = AudioBuffer.silence(
      channelCount: config.channelCount,
      frameCount: config.blockFrames,
      sampleRate: config.sampleRate,
    );
    _framesRendered = 0;

    await FlutterPcmSound.setLogLevel(LogLevel.error);
    await FlutterPcmSound.setup(
      sampleRate: config.sampleRate,
      channelCount: config.channelCount,
      iosAudioCategory: IosAudioCategory.playAndRecord,
    );
    await FlutterPcmSound.setFeedThreshold(config.outputBufferFrames);
    FlutterPcmSound.setFeedCallback(_onFeed);
    _open = true;

    // Prime the queue directly rather than through the plugin's own start
    // helper: that helper is gated on a static latch which stays consumed
    // after the first run, so an engine that is closed and reopened within one
    // session would never receive its first callback and would stay silent.
    for (var i = 0; i < config.bufferedBlocks; i++) {
      _feedBlock();
    }
    _watchdog = Timer.periodic(_watchdogInterval, (_) => _checkForStall());
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _watchdog?.cancel();
    _watchdog = null;
    FlutterPcmSound.setFeedCallback(null);
    _onRender = null;
    _scratch = null;
    _lastFeed = null;
    await FlutterPcmSound.release();
  }

  /// How often the stall check runs.
  static const Duration _watchdogInterval = Duration(milliseconds: 250);

  /// The output device stops itself when its queue empties, and it only asks
  /// for more audio from inside its own render callback — so once it has
  /// stopped, nothing is left to restart it. This notices that the feed loop
  /// has gone quiet and primes it again (NFR-PERF-04).
  void _checkForStall() {
    if (!_open) return;
    final last = _lastFeed;
    final silentFor = last == null
        ? _watchdogInterval
        : DateTime.now().difference(last);
    // Two block durations of no activity is well past normal: at the default
    // settings a healthy loop feeds every 20-40 ms.
    if (silentFor < _config.blockDuration * 4) return;
    _feedBlock();
  }

  void _onFeed(int remainingFrames) {
    if (!_open) return;
    final target = _config.outputBufferFrames;
    // Top the queue back up to the target depth. One extra block of headroom
    // absorbs a late callback without a dropout (NFR-PERF-04).
    var blocks = ((target - remainingFrames) / _config.blockFrames).ceil();
    if (blocks < 1) blocks = 1;
    if (blocks > _config.bufferedBlocks + 1) blocks = _config.bufferedBlocks + 1;
    for (var i = 0; i < blocks; i++) {
      _feedBlock();
    }
  }

  void _feedBlock() {
    final scratch = _scratch;
    final render = _onRender;
    if (scratch == null || render == null) return;
    for (final channel in scratch.channels) {
      channel.fillRange(0, channel.length, 0);
    }
    render(scratch);
    _framesRendered += scratch.frameCount;
    _lastFeed = DateTime.now();
    FlutterPcmSound.feed(_toPcm(scratch));
  }

  /// Interleaves straight into an [Int16List] and hands over its byte view;
  /// building the array element by element would be needless work on every
  /// block.
  static PcmArrayInt16 _toPcm(AudioBuffer buffer) {
    final samples = Int16List(buffer.frameCount * buffer.channelCount);
    var index = 0;
    for (var frame = 0; frame < buffer.frameCount; frame++) {
      for (var ch = 0; ch < buffer.channelCount; ch++) {
        samples[index++] = floatToInt16(buffer.channels[ch][frame]);
      }
    }
    return PcmArrayInt16(bytes: ByteData.sublistView(samples));
  }
}

/// An output that renders on demand instead of in real time.
///
/// Used by tests and by the offline renderer, so exactly the same graph code
/// produces the live mix and the exported file.
class NullAudioOutput implements AudioOutput {
  EngineConfig _config = const EngineConfig();
  RenderCallback? _onRender;
  bool _open = false;
  int _framesRendered = 0;

  @override
  bool get isOpen => _open;

  @override
  int get framesRendered => _framesRendered;

  @override
  Future<void> open(EngineConfig config, RenderCallback onRender) async {
    _config = config;
    _onRender = onRender;
    _open = true;
    _framesRendered = 0;
  }

  @override
  Future<void> close() async {
    _open = false;
    _onRender = null;
  }

  /// Pulls [blocks] blocks, returning what would have been played.
  List<AudioBuffer> pump(int blocks) {
    final rendered = <AudioBuffer>[];
    for (var i = 0; i < blocks; i++) {
      final block = AudioBuffer.silence(
        channelCount: _config.channelCount,
        frameCount: _config.blockFrames,
        sampleRate: _config.sampleRate,
      );
      _onRender?.call(block);
      _framesRendered += block.frameCount;
      rendered.add(block);
    }
    return rendered;
  }
}
