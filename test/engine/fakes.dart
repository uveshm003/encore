import 'dart:async';

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/engine/audio_input.dart';

/// A capture device the test drives by hand.
///
/// Blocks are delivered exactly when [emit] is called, so a test can place a
/// capture block at a known transport position and assert on the alignment
/// that results.
class FakeAudioInput implements AudioInput {
  FakeAudioInput({this.permitted = true});

  bool permitted;
  StreamController<AudioBuffer>? _controller;
  bool _capturing = false;
  int startCount = 0;
  int stopCount = 0;
  String? lastDeviceId;

  @override
  bool get isCapturing => _capturing;

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<bool> requestPermission() async => permitted;

  @override
  Future<List<AudioInputDevice>> listDevices() async => const [
    AudioInputDevice(id: 'built-in', label: 'Built-in Microphone'),
  ];

  @override
  Future<Stream<AudioBuffer>> start({
    required int sampleRate,
    required int channelCount,
    String? deviceId,
  }) async {
    if (!permitted) {
      throw const AudioInputException(
        'Permission denied',
        isPermissionDenied: true,
      );
    }
    startCount++;
    lastDeviceId = deviceId;
    _capturing = true;
    final controller = StreamController<AudioBuffer>();
    _controller = controller;
    return controller.stream;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _capturing = false;
    await _controller?.close();
    _controller = null;
  }

  /// Delivers one block of captured audio synchronously.
  Future<void> emit(AudioBuffer block) async {
    _controller?.add(block);
    // Let the engine's listener run before the test continues.
    await Future<void>.delayed(Duration.zero);
  }

  /// A block of constant-valued mono audio.
  static AudioBuffer block(
    double value, {
    int frames = 512,
    int sampleRate = 48000,
  }) {
    final buffer = AudioBuffer.silence(
      channelCount: 1,
      frameCount: frames,
      sampleRate: sampleRate,
    );
    buffer.channels[0].fillRange(0, frames, value);
    return buffer;
  }
}
