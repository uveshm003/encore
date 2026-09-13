import 'package:flutter/widgets.dart';

import '../engine/audio_engine.dart';
import '../engine/engine_config.dart';
import '../engine/playback_engine.dart';
import '../io/codec/codec_registry.dart';
import '../io/export_service.dart';
import '../library/media_library.dart';
import '../project/asset_store.dart';
import '../project/project_controller.dart';
import '../project/project_repository.dart';
import '../separation/model_store.dart';
import '../separation/separation_service.dart';
import '../separation/stem_cache.dart';
import '../io/incoming_files.dart';
import '../separation/inference_backend.dart';
import '../separation/onnx_inference_backend.dart';
import '../storage/app_paths.dart';
import 'app_settings.dart';

/// Everything the app is made of, wired together once at start-up.
///
/// Constructed by [create] so the composition is in one readable place and so
/// tests can build the same object graph against temporary directories and
/// stub devices.
class AppServices {
  AppServices({
    required this.config,
    required this.paths,
    required this.settings,
    required this.codecs,
    required this.library,
    required this.stemCache,
    required this.modelStore,
    required this.separation,
    required this.projects,
    required this.assets,
    required this.engine,
    required this.controller,
    required this.exporter,
    required this.incoming,
  });

  /// Builds the full stack and starts the audio device.
  static Future<AppServices> create({
    EngineConfig config = const EngineConfig(),
    AppPaths? paths,
    AudioEngine? engine,
    CodecRegistry? codecs,
    InferenceBackend? inference,
    bool startEngine = true,
  }) async {
    final resolvedPaths = paths ?? await AppPaths.resolve();
    final settings = AppSettings(paths: resolvedPaths);
    await settings.load();

    // The registry is injectable for the same reason the engine is: probing
    // the platform's codecs needs a host to ask, which a widget test has not
    // got.
    final resolvedCodecs = codecs ?? CodecRegistry.defaults();
    await resolvedCodecs.initialise();

    final library = MediaLibrary(
      paths: resolvedPaths,
      codecs: resolvedCodecs,
      config: config,
    );
    await library.load();

    final stemCache = StemCache(resolvedPaths);
    final modelStore = ModelStore(resolvedPaths);
    final separation = SeparationService(
      paths: resolvedPaths,
      cache: stemCache,
      models: modelStore,
      // The runtime ships; the weights do not. A neural model is a file the
      // user installs, which is what keeps SEP-02 clear of the training-data
      // licensing question — see docs/licences.md.
      inference: inference ?? OnnxInferenceBackend(),
    );

    final projects = ProjectRepository(paths: resolvedPaths);
    final assets = AssetStore(repository: projects);
    final audioEngine = engine ?? PlaybackEngine(config: config);
    // The engine starts from an estimate derived from its own buffering. Only
    // replace it once there is something real to replace it with, otherwise a
    // first run would overwrite the estimate with an empty stored value and
    // record every take late by the full round trip (REC-04).
    final stored = settings.latency;
    if (stored.isCalibrated || stored.compensationFrames > 0) {
      audioEngine.latency = stored;
    } else {
      await settings.setLatency(audioEngine.latency);
    }
    if (startEngine) await audioEngine.start();

    final controller = ProjectController(
      repository: projects,
      assets: assets,
      engine: audioEngine,
    );

    return AppServices(
      config: config,
      paths: resolvedPaths,
      settings: settings,
      codecs: resolvedCodecs,
      library: library,
      stemCache: stemCache,
      modelStore: modelStore,
      separation: separation,
      projects: projects,
      assets: assets,
      engine: audioEngine,
      controller: controller,
      exporter: ExportService(codecs: resolvedCodecs, paths: resolvedPaths),
      incoming: IncomingFiles(),
    );
  }

  final EngineConfig config;
  final AppPaths paths;
  final AppSettings settings;
  final CodecRegistry codecs;
  final MediaLibrary library;
  final StemCache stemCache;
  final ModelStore modelStore;
  final SeparationService separation;
  final ProjectRepository projects;
  final AssetStore assets;
  final AudioEngine engine;
  final ProjectController controller;
  final ExportService exporter;

  /// Songs handed over by the OS share sheet or "open with" (IMP-05).
  final IncomingFiles incoming;

  Future<void> dispose() async {
    separation.cancelAll();
    await incoming.dispose();
    await controller.close();
    await engine.shutdown();
  }
}

/// Makes [AppServices] available to the widget tree.
class ServicesScope extends InheritedWidget {
  const ServicesScope({
    required this.services,
    required super.child,
    super.key,
  });

  final AppServices services;

  static AppServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ServicesScope>();
    assert(scope != null, 'No ServicesScope found in the widget tree');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(ServicesScope oldWidget) =>
      !identical(services, oldWidget.services);
}
