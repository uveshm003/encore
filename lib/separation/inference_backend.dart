import 'dart:typed_data';

/// One loaded neural model, ready to run.
abstract class InferenceSession {
  /// Runs the model over a block of audio.
  ///
  /// [input] is planar float PCM — one array per channel — and the result is
  /// one planar buffer per output stem, in the order the model declares.
  Future<List<List<Float32List>>> run(List<Float32List> input);

  /// Frames the model expects per call. Audio is chunked to this size and the
  /// results overlap-added.
  int get windowFrames;

  /// Frames neighbouring windows share, to avoid seams.
  int get overlapFrames;

  /// Sample rate the model was trained at; audio is converted to it first.
  int get sampleRate;

  Future<void> close();
}

/// The shape a neural model expects, as the catalogue records it.
///
/// An ONNX graph does not say what sample rate it was trained at, nor how much
/// its windows should overlap — those are facts about the model that only its
/// publisher knows. They travel with the catalogue entry rather than being
/// guessed from the file.
class NeuralModelSpec {
  const NeuralModelSpec({
    required this.sampleRate,
    required this.windowFrames,
    required this.overlapFrames,
    this.channelCount = 2,
  });

  /// Rate the model was trained at; audio is converted to it first.
  final int sampleRate;

  /// Frames per call. A backend may narrow this if the graph declares a fixed
  /// input length, which is the one part the file does describe.
  final int windowFrames;

  /// Frames neighbouring windows share, to avoid seams.
  final int overlapFrames;

  final int channelCount;
}

/// An on-device inference runtime (ONNX Runtime, per §6.1).
///
/// This is the seam the neural separator is written against. Keeping it
/// abstract means the separation pipeline, the model catalogue, the cache and
/// the progress/cancel plumbing are all exercised by the built-in spectral
/// engine, and adding a runtime is a matter of supplying one implementation
/// rather than reworking the feature.
abstract class InferenceBackend {
  String get name;

  /// Whether the runtime is compiled into this build and usable here.
  Future<bool> isAvailable();

  /// Loads weights from [modelPath], shaped by [spec].
  Future<InferenceSession> load(String modelPath, NeuralModelSpec spec);
}

/// The backend used when no inference runtime is present in the build.
///
/// It reports itself unavailable, which is what makes the neural models show
/// as "unavailable" in the UI instead of failing at the moment the user asks
/// for a separation.
class UnavailableInferenceBackend implements InferenceBackend {
  const UnavailableInferenceBackend();

  @override
  String get name => 'None';

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<InferenceSession> load(String modelPath, NeuralModelSpec spec) async {
    throw const InferenceUnavailable(
      'No on-device inference runtime is included in this build.',
    );
  }
}

/// Raised when a neural model is requested but cannot be run.
class InferenceUnavailable implements Exception {
  const InferenceUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
