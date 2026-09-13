import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../core/audio_buffer.dart';

/// A capture device the user can pick (REC-06).
class AudioInputDevice {
  const AudioInputDevice({required this.id, required this.label});

  final String id;
  final String label;
}

/// Raised when capture cannot start, with a message worth showing.
class AudioInputException implements Exception {
  const AudioInputException(this.message, {this.isPermissionDenied = false});

  final String message;
  final bool isPermissionDenied;

  @override
  String toString() => message;
}

/// Live audio coming in from a microphone or interface.
///
/// Abstracted for the same reason as [AudioOutput]: recording behaviour has to
/// be testable without hardware, and the implementation is expected to be
/// replaced by the native engine's own capture path.
abstract class AudioInput {
  Future<bool> hasPermission();

  Future<bool> requestPermission();

  Future<List<AudioInputDevice>> listDevices();

  /// Starts capture and returns a stream of blocks at [sampleRate].
  Future<Stream<AudioBuffer>> start({
    required int sampleRate,
    required int channelCount,
    String? deviceId,
  });

  Future<void> stop();

  bool get isCapturing;
}

/// Capture backed by the `record` plugin, configured for raw 16-bit PCM.
///
/// Raw PCM rather than an encoded stream is deliberate: recorded takes have to
/// be sample-aligned to the timeline, and a codec's own framing and priming
/// delay would make that alignment guesswork.
class RecordAudioInput implements AudioInput {
  RecordAudioInput({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  StreamSubscription<Uint8List>? _subscription;
  StreamController<AudioBuffer>? _controller;
  bool _capturing = false;

  @override
  bool get isCapturing => _capturing;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<bool> requestPermission() => _recorder.hasPermission();

  @override
  Future<List<AudioInputDevice>> listDevices() async {
    try {
      final devices = await _recorder.listInputDevices();
      return [
        for (final device in devices)
          AudioInputDevice(id: device.id, label: device.label),
      ];
    } on Object {
      // Device enumeration is a convenience; the default device still works.
      return const [];
    }
  }

  @override
  Future<Stream<AudioBuffer>> start({
    required int sampleRate,
    required int channelCount,
    String? deviceId,
  }) async {
    if (_capturing) await stop();
    if (!await _recorder.hasPermission()) {
      throw const AudioInputException(
        'Encore needs permission to use the microphone before it can record.',
        isPermissionDenied: true,
      );
    }

    InputDevice? device;
    if (deviceId != null) {
      final devices = await _recorder.listInputDevices();
      for (final candidate in devices) {
        if (candidate.id == deviceId) {
          device = candidate;
          break;
        }
      }
    }

    final Stream<Uint8List> raw;
    try {
      raw = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: channelCount,
          device: device,
          // Processing that changes level or timing would break alignment and
          // colour the take, so none of it is asked for.
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
        ),
      );
    } on Object catch (error) {
      throw AudioInputException('Could not start recording: $error');
    }

    final controller = StreamController<AudioBuffer>.broadcast();
    _controller = controller;
    _capturing = true;
    _subscription = raw.listen(
      (bytes) {
        if (bytes.isEmpty) return;
        controller.add(_toBuffer(bytes, sampleRate, channelCount));
      },
      onError: controller.addError,
      onDone: () {
        _capturing = false;
        if (!controller.isClosed) controller.close();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> stop() async {
    if (!_capturing && _subscription == null) return;
    _capturing = false;
    try {
      await _recorder.stop();
    } on Object {
      // Stopping an already-stopped recorder is not an error worth raising.
    }
    await _subscription?.cancel();
    _subscription = null;
    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }

  /// Interprets the platform's bytes as host-endian signed 16-bit PCM.
  static AudioBuffer _toBuffer(
    Uint8List bytes,
    int sampleRate,
    int channelCount,
  ) {
    // An odd trailing byte would be a partial sample; drop it rather than
    // letting it shift every following frame by half a sample.
    final usable = bytes.length - (bytes.length % (2 * channelCount));
    // A typed view needs a two-byte-aligned offset, which a buffer handed over
    // by the platform is not obliged to have; copy in that case.
    final samples = bytes.offsetInBytes.isEven
        ? Int16List.view(bytes.buffer, bytes.offsetInBytes, usable ~/ 2)
        : Int16List.sublistView(Uint8List.fromList(bytes.sublist(0, usable)));
    return AudioBuffer.fromInterleavedInt16(
      samples,
      channelCount: channelCount,
      sampleRate: sampleRate,
    );
  }
}
