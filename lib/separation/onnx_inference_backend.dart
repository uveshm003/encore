import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'inference_backend.dart';

/// ONNX Runtime as the app's inference runtime (SEP-02, §6.1).
///
/// This is the class the architecture was waiting for: everything else on the
/// neural path — the catalogue, the model store, the segmented separator, the
/// progress and cancellation plumbing — was already built and tested against
/// [InferenceBackend], so bringing a runtime in is this file and nothing else.
///
/// What it deliberately does not do is ship weights. Encore distributes the
/// runtime; the user installs a model file. That is what keeps the offline
/// guarantee (nothing is ever downloaded by the app) and it is what keeps the
/// licensing clean — see `docs/licences.md`, where the training-data question
/// around published separation checkpoints is why bundling them is not on the
/// table.
class OnnxInferenceBackend implements InferenceBackend {
  OnnxInferenceBackend({OnnxRuntime? runtime})
    : _runtime = runtime ?? OnnxRuntime();

  final OnnxRuntime _runtime;

  @override
  String get name => 'ONNX Runtime';

  @override
  Future<bool> isAvailable() async {
    try {
      // Asking the plugin for its version is the cheapest way to find out
      // whether the native library actually loaded on this platform — which
      // is not the same question as whether the package is in pubspec.yaml.
      final version = await _runtime.getPlatformVersion();
      return version != null && version.isNotEmpty;
    } on Object {
      return false;
    }
  }

  @override
  Future<InferenceSession> load(String modelPath, NeuralModelSpec spec) async {
    if (!await File(modelPath).exists()) {
      throw InferenceUnavailable('The model file is missing: $modelPath');
    }
    try {
      final session = await _runtime.createSession(
        modelPath,
        options: OrtSessionOptions(
          // Hardware acceleration where the platform has it, falling back to
          // the CPU rather than failing — a slow separation is a far better
          // outcome than none (NFR-PERF-03).
          providers: _providers(),
        ),
      );
      final windowFrames = await _windowFramesFor(session, spec);
      return _OnnxSession(
        session: session,
        sampleRate: spec.sampleRate,
        windowFrames: windowFrames,
        overlapFrames: spec.overlapFrames.clamp(0, windowFrames ~/ 2),
        channelCount: spec.channelCount,
      );
    } on InferenceUnavailable {
      rethrow;
    } on Object catch (error) {
      throw InferenceUnavailable('The model could not be loaded: $error');
    }
  }

  static List<OrtProvider> _providers() {
    if (Platform.isMacOS || Platform.isIOS) {
      return const [OrtProvider.CORE_ML, OrtProvider.CPU];
    }
    if (Platform.isAndroid) {
      return const [OrtProvider.NNAPI, OrtProvider.XNNPACK, OrtProvider.CPU];
    }
    return const [OrtProvider.CPU];
  }

  /// Prefers the length the graph itself declares over the catalogue's guess.
  ///
  /// An export with a fixed input length will reject any other size, so where
  /// the model says what it wants, it wins. A dynamic axis comes back as -1 or
  /// null, and then the catalogue's value stands.
  static Future<int> _windowFramesFor(
    OrtSession session,
    NeuralModelSpec spec,
  ) async {
    try {
      final inputs = await session.getInputInfo();
      if (inputs.isEmpty) return spec.windowFrames;
      final shape = inputs.first['shape'];
      if (shape is! List || shape.isEmpty) return spec.windowFrames;
      final last = shape.last;
      final frames = last is num ? last.toInt() : int.tryParse('$last');
      if (frames != null && frames > 0) return frames;
    } on Object {
      // Metadata is a convenience, not a requirement.
    }
    return spec.windowFrames;
  }
}

/// One loaded ONNX model.
class _OnnxSession implements InferenceSession {
  _OnnxSession({
    required this.session,
    required this.sampleRate,
    required this.windowFrames,
    required this.overlapFrames,
    required this.channelCount,
  });

  final OrtSession session;

  @override
  final int sampleRate;

  @override
  final int windowFrames;

  @override
  final int overlapFrames;

  final int channelCount;

  @override
  Future<List<List<Float32List>>> run(List<Float32List> input) async {
    final frames = input.isEmpty ? 0 : input.first.length;
    final channels = input.length;

    // Separation models take one batch of planar audio: [1, channels, frames].
    final flat = Float32List(channels * frames);
    for (var channel = 0; channel < channels; channel++) {
      flat.setRange(channel * frames, (channel + 1) * frames, input[channel]);
    }

    final tensor = await OrtValue.fromList(flat, [1, channels, frames]);
    try {
      final outputs = await session.run({session.inputNames.first: tensor});
      return _readStems(outputs, channels: channels, frames: frames);
    } finally {
      await tensor.dispose();
    }
  }

  /// Reshapes the runtime's flat output back into one planar buffer per stem.
  ///
  /// Two export conventions are in the wild and both are handled: a single
  /// output holding every stem — [1, stems, channels, frames] — and one output
  /// per stem. The stem count is derived from the data rather than assumed, so
  /// a two-stem and a four-stem model both work.
  Future<List<List<Float32List>>> _readStems(
    Map<String, OrtValue> outputs, {
    required int channels,
    required int frames,
  }) async {
    if (outputs.isEmpty || frames == 0) return const [];

    // Keep the model's declared output order; a map does not promise one.
    final names = session.outputNames.where(outputs.containsKey).toList();
    final ordered = names.isEmpty ? outputs.keys.toList() : names;

    final stems = <List<Float32List>>[];
    for (final name in ordered) {
      final value = outputs[name]!;
      final flat = await value.asFlattenedList();
      final samples = Float32List(flat.length);
      for (var i = 0; i < flat.length; i++) {
        final sample = flat[i];
        samples[i] = sample is num ? sample.toDouble() : 0;
      }
      await value.dispose();

      final perStem = channels * frames;
      if (perStem == 0) continue;
      final stemCount = samples.length ~/ perStem;
      for (var stem = 0; stem < stemCount; stem++) {
        stems.add([
          for (var channel = 0; channel < channels; channel++)
            Float32List.sublistView(
              samples,
              stem * perStem + channel * frames,
              stem * perStem + (channel + 1) * frames,
            ),
        ]);
      }
    }
    return stems;
  }

  @override
  Future<void> close() => session.close();
}
