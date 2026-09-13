import 'dart:io';
import 'dart:typed_data';

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/io/codec/wav_codec.dart';
import 'package:encore/separation/inference_backend.dart';
import 'package:encore/separation/model_store.dart';
import 'package:encore/separation/separation_model.dart';
import 'package:encore/separation/separation_service.dart';
import 'package:encore/separation/stem_cache.dart';
import 'package:encore/separation/stem_kind.dart';
import 'package:encore/storage/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';

/// A backend that behaves like a runtime without being one.
///
/// This is the whole point of the [InferenceBackend] seam: the neural path —
/// availability, model loading, windowing, stem writing, the cache manifest —
/// is exercised end to end with no ONNX Runtime, no weights file and no
/// device (SEP-02).
class FakeBackend implements InferenceBackend {
  FakeBackend({this.available = true});

  final bool available;
  NeuralModelSpec? loadedWith;
  String? loadedPath;
  bool closed = false;

  @override
  String get name => 'Fake';

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<InferenceSession> load(String modelPath, NeuralModelSpec spec) async {
    loadedPath = modelPath;
    loadedWith = spec;
    return _FakeSession(spec, onClose: () => closed = true);
  }
}

class _FakeSession implements InferenceSession {
  _FakeSession(this.spec, {required this.onClose});

  final NeuralModelSpec spec;
  final void Function() onClose;

  @override
  int get sampleRate => spec.sampleRate;

  @override
  int get windowFrames => spec.windowFrames;

  @override
  int get overlapFrames => spec.overlapFrames;

  @override
  Future<List<List<Float32List>>> run(List<Float32List> input) async {
    // Splits evenly into four, the way a four-stem model would.
    return [
      for (var stem = 0; stem < 4; stem++)
        [
          for (final channel in input)
            Float32List.fromList([for (final sample in channel) sample * 0.25]),
        ],
    ];
  }

  @override
  Future<void> close() async => onClose();
}

void main() {
  late Directory root;
  late AppPaths paths;
  late StemCache cache;
  late ModelStore store;
  late String sourceWav;

  /// A neural model small enough to run quickly in a test.
  const testModel = SeparationModel(
    id: 'fake-neural',
    name: 'Fake neural',
    summary: 'Test model.',
    engine: SeparationEngine.neural,
    tier: SeparationTier.balanced,
    supportedStems: {
      StemKind.vocals,
      StemKind.instrumental,
      StemKind.drums,
      StemKind.bass,
      StemKind.other,
    },
    assetFileName: 'fake.onnx',
    spec: NeuralModelSpec(
      sampleRate: 48000,
      windowFrames: 2048,
      overlapFrames: 256,
    ),
    outputOrder: [
      StemKind.drums,
      StemKind.bass,
      StemKind.other,
      StemKind.vocals,
    ],
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('encore-neural-');
    paths = AppPaths(root);
    await paths.ensureDirectories();
    cache = StemCache(paths);
    store = ModelStore(paths);

    // The "weights": the backend is fake, so only the file's existence matters.
    await File('${paths.models.path}/fake.onnx').writeAsBytes([0, 1, 2, 3]);

    final audio = AudioBuffer.silence(
      channelCount: 2,
      frameCount: 9600,
      sampleRate: 48000,
    );
    for (var i = 0; i < 9600; i++) {
      final value = (i % 480) / 480 - 0.5;
      audio.channels[0][i] = value;
      audio.channels[1][i] = value;
    }
    sourceWav = '${root.path}/source.wav';
    await WavCodec.write(sourceWav, audio);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  SeparationService serviceWith(InferenceBackend backend) => SeparationService(
    paths: paths,
    cache: cache,
    models: store,
    inference: backend,
  );

  test('a neural model runs end to end and caches its stems', () async {
    final backend = FakeBackend();
    final service = serviceWith(backend);

    final job = await service.separate(
      sourceWavPath: sourceWav,
      sourceKey: 'key-1',
      model: testModel,
      stems: StemKind.fourStem,
      title: 'Test song',
    );
    final stems = await job.result;

    expect(backend.loadedPath, endsWith('fake.onnx'));
    expect(backend.loadedWith?.sampleRate, 48000);
    expect(stems.paths.keys, containsAll(StemKind.fourStem));
    for (final path in stems.paths.values) {
      expect(await File(path).exists(), isTrue, reason: '$path should exist');
      // The timeline reads the envelope from beside the audio.
      expect(await File('$path.peaks').exists(), isTrue);
    }
    expect(backend.closed, isTrue, reason: 'the session must be released');
  });

  test('a second request is served from the cache', () async {
    final backend = FakeBackend();
    final service = serviceWith(backend);

    Future<void> run() async {
      final job = await service.separate(
        sourceWavPath: sourceWav,
        sourceKey: 'key-2',
        model: testModel,
        stems: StemKind.fourStem,
        title: 'Test song',
      );
      await job.result;
    }

    await run();
    final second = FakeBackend();
    final cachedService = serviceWith(second);
    final job = await cachedService.separate(
      sourceWavPath: sourceWav,
      sourceKey: 'key-2',
      model: testModel,
      stems: StemKind.fourStem,
      title: 'Test song',
    );
    await job.result;

    // SEP-03: the model is never loaded a second time for the same source.
    expect(second.loadedPath, isNull);
  });

  test('no runtime means a clear reason, not a crash', () async {
    final service = serviceWith(FakeBackend(available: false));

    final availability = await service.availabilityOf(testModel);
    expect(availability.isAvailable, isFalse);
    expect(availability.reason, contains('inference runtime'));

    final job = await service.separate(
      sourceWavPath: sourceWav,
      sourceKey: 'key-3',
      model: testModel,
      stems: StemKind.fourStem,
      title: 'Test song',
    );
    await expectLater(job.result, throwsA(isA<SeparationFailure>()));
  });

  test('a missing model file fails without leaving a cache entry', () async {
    await File('${paths.models.path}/fake.onnx').delete();
    final service = serviceWith(FakeBackend());

    final job = await service.separate(
      sourceWavPath: sourceWav,
      sourceKey: 'key-4',
      model: testModel,
      stems: StemKind.fourStem,
      title: 'Test song',
    );
    await expectLater(job.result, throwsA(isA<SeparationFailure>()));

    final cached = await cache.lookup('key-4', testModel.id, StemKind.fourStem);
    expect(cached, isNull);
  });

  test('progress climbs to completion', () async {
    final service = serviceWith(FakeBackend());
    final job = await service.separate(
      sourceWavPath: sourceWav,
      sourceKey: 'key-5',
      model: testModel,
      stems: StemKind.fourStem,
      title: 'Test song',
    );
    final seen = <double>[];
    job.updates.listen((progress) => seen.add(progress.fraction));
    await job.result;

    expect(seen, isNotEmpty);
    expect(seen.last, 1);
  });
}
