import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../io/codec/wav_codec.dart';
import '../storage/app_paths.dart';
import 'inference_backend.dart';
import 'model_store.dart';
import 'neural_separator.dart';
import 'separation_isolate.dart';
import 'separation_model.dart';
import 'spectral_separator.dart';
import 'stem_cache.dart';
import 'stem_kind.dart';

/// Where a separation job has got to.
enum SeparationState { queued, running, completed, cancelled, failed }

/// A progress update for one job.
class SeparationProgress {
  const SeparationProgress({
    required this.state,
    required this.fraction,
    required this.message,
  });

  final SeparationState state;

  /// 0..1.
  final double fraction;

  /// What is happening right now, in plain language.
  final String message;

  bool get isFinished =>
      state == SeparationState.completed ||
      state == SeparationState.cancelled ||
      state == SeparationState.failed;
}

/// Raised when a job is cancelled by the user.
class SeparationCancelledException implements Exception {
  const SeparationCancelledException();

  @override
  String toString() => 'Separation was cancelled.';
}

/// Raised when a separation cannot be run or did not finish.
class SeparationFailure implements Exception {
  const SeparationFailure(this.message, {this.details});

  final String message;
  final String? details;

  @override
  String toString() => message;
}

/// A running separation the UI can watch and cancel (SEP-04).
class SeparationJob {
  SeparationJob._({
    required this.id,
    required this.title,
    required this.model,
    required this.stems,
  }) {
    // Mark the result as observed straight away.
    //
    // A job can fail or be cancelled with nobody awaiting [result] — which is
    // the *normal* case when the user cancels from a screen that has already
    // been popped, or when a caller starts a separation and only watches
    // [updates]. Without this, `completeError` would hand the error to the
    // zone as an unhandled async error: it does not stop the cancellation, it
    // just surfaces later attached to whatever happens to be running, which in
    // a release build is reported as a crash the user did not cause.
    //
    // `ignore()` adds a second, silent subscription. Real callers still get
    // the error; it simply is not unhandled any more.
    _result.future.ignore();
  }

  final String id;
  final String title;
  final SeparationModel model;
  final Set<StemKind> stems;

  final _updates = StreamController<SeparationProgress>.broadcast();
  final _result = Completer<CachedStems>();

  Isolate? _isolate;
  ReceivePort? _port;
  Directory? _workingDirectory;
  bool _cancelled = false;

  SeparationProgress _latest = const SeparationProgress(
    state: SeparationState.queued,
    fraction: 0,
    message: 'Waiting to start',
  );

  /// The most recent update, for a UI that attaches after the job started.
  SeparationProgress get progress => _latest;

  Stream<SeparationProgress> get updates => _updates.stream;

  /// Completes with the cached stems, or throws
  /// [SeparationCancelledException] / [SeparationFailure].
  Future<CachedStems> get result => _result.future;

  bool get isFinished => _latest.isFinished;

  /// Whether the user has asked for this job to stop.
  ///
  /// The isolate path checks this by being killed; the neural path, which runs
  /// on this isolate, has to poll it between windows instead.
  bool get isCancelled => _cancelled;

  /// Stops the job. The isolate is killed outright rather than asked to stop,
  /// so cancelling is immediate even in the middle of a long transform.
  void cancel() {
    if (_result.isCompleted || _cancelled) return;
    _cancelled = true;
    _isolate?.kill(priority: Isolate.immediate);
    _port?.close();
    unawaited(_discardPartialOutput());
    _emit(const SeparationProgress(
      state: SeparationState.cancelled,
      fraction: 0,
      message: 'Cancelled',
    ));
    _result.completeError(const SeparationCancelledException());
    _close();
  }

  void _emit(SeparationProgress progress) {
    _latest = progress;
    if (!_updates.isClosed) _updates.add(progress);
  }

  void _close() {
    _port?.close();
    _port = null;
    _isolate = null;
    if (!_updates.isClosed) _updates.close();
  }

  Future<void> _discardPartialOutput() async {
    final directory = _workingDirectory;
    if (directory == null) return;
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // A leftover directory is harmless: the manifest is written last, so it
      // will read as a cache miss and be overwritten.
    }
  }
}

/// Runs and caches stem separation (SEP-01…SEP-07).
///
/// Separation is explicitly an offline batch step, never part of playback
/// (C-01): a job decodes to WAV, runs in its own isolate, writes stems to the
/// cache, and everything downstream — playback, recording, mixing — reads those
/// files. Asking for a separation that has already been done returns the cached
/// result without doing any work (SEP-03).
class SeparationService extends ChangeNotifier {
  SeparationService({
    required this.paths,
    required this.cache,
    required this.models,
    this.inference = const UnavailableInferenceBackend(),
  });

  final AppPaths paths;
  final StemCache cache;
  final ModelStore models;
  final InferenceBackend inference;

  final List<SeparationJob> _jobs = [];
  var _nextJobId = 0;

  /// Jobs that have not finished, newest last.
  List<SeparationJob> get activeJobs =>
      List.unmodifiable(_jobs.where((job) => !job.isFinished));

  SeparationJob? get currentJob =>
      activeJobs.isEmpty ? null : activeJobs.first;

  /// Whether [model] can run right now, and why not when it cannot.
  Future<ModelAvailability> availabilityOf(SeparationModel model) async {
    if (model.engine == SeparationEngine.spectral) {
      return const ModelAvailability(isAvailable: true);
    }
    if (!await inference.isAvailable()) {
      return const ModelAvailability(
        isAvailable: false,
        reason: 'This build has no on-device inference runtime, so neural '
            'models cannot run. The built-in separation works offline and '
            'needs no download.',
      );
    }
    if (!await models.isInstalled(model)) {
      return const ModelAvailability(
        isAvailable: false,
        reason: 'The model file is not installed yet.',
      );
    }
    return const ModelAvailability(isAvailable: true);
  }

  /// A previously computed result, if one covers [stems].
  Future<CachedStems?> cached({
    required String sourceKey,
    required SeparationModel model,
    required Set<StemKind> stems,
  }) {
    return cache.lookup(sourceKey, model.id, stems);
  }

  /// Starts a separation, or returns a job that is already complete when the
  /// result is cached.
  Future<SeparationJob> separate({
    required String sourceWavPath,
    required String sourceKey,
    required SeparationModel model,
    required Set<StemKind> stems,
    required String title,
  }) async {
    final job = SeparationJob._(
      id: 'job-${_nextJobId++}',
      title: title,
      model: model,
      stems: stems,
    );
    _jobs.add(job);
    notifyListeners();

    final existing = await cache.lookup(sourceKey, model.id, stems);
    if (existing != null) {
      job._emit(const SeparationProgress(
        state: SeparationState.completed,
        fraction: 1,
        message: 'Already separated',
      ));
      job._result.complete(existing);
      job._close();
      notifyListeners();
      return job;
    }

    final availability = await availabilityOf(model);
    if (!availability.isAvailable) {
      _fail(job, SeparationFailure(availability.reason ?? 'Unavailable.'));
      return job;
    }

    if (model.engine == SeparationEngine.neural) {
      unawaited(_runNeural(
        job: job,
        sourceWavPath: sourceWavPath,
        sourceKey: sourceKey,
        model: model,
        stems: stems,
        title: title,
      ));
      return job;
    }

    unawaited(_runSpectral(
      job: job,
      sourceWavPath: sourceWavPath,
      sourceKey: sourceKey,
      model: model,
      stems: stems,
      title: title,
    ));
    return job;
  }

  /// Runs a neural model (SEP-02).
  ///
  /// Unlike the spectral path this does not spawn an isolate, and cannot: the
  /// runtime is reached over a platform channel, and those only work on the
  /// root isolate. It is not the problem it looks like — the inference itself
  /// happens in native code on its own thread, and the Dart side is awaiting a
  /// channel call throughout, so the UI keeps running. Cancellation is checked
  /// between windows exactly as it is between segments.
  Future<void> _runNeural({
    required SeparationJob job,
    required String sourceWavPath,
    required String sourceKey,
    required SeparationModel model,
    required Set<StemKind> stems,
    required String title,
  }) async {
    final spec = model.spec;
    if (spec == null || model.outputOrder.isEmpty) {
      _fail(job, SeparationFailure(
        '${model.name} does not describe how to run it.',
      ));
      return;
    }

    final directory = cache.directoryFor(sourceKey, model.id);
    job._workingDirectory = directory;
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      await directory.create(recursive: true);
    } on FileSystemException catch (error) {
      _fail(job, SeparationFailure(
        'Could not prepare space for the separated stems.',
        details: '$error',
      ));
      return;
    }

    job._emit(const SeparationProgress(
      state: SeparationState.running,
      fraction: 0,
      message: 'Loading model',
    ));
    notifyListeners();

    InferenceSession? session;
    try {
      final modelPath = models.pathFor(model);
      if (modelPath == null) {
        throw const InferenceUnavailable('The model file is not installed.');
      }
      session = await inference.load(modelPath, spec);

      job._emit(const SeparationProgress(
        state: SeparationState.running,
        fraction: 0.05,
        message: 'Loading audio',
      ));
      final source = await WavCodec.read(sourceWavPath);

      final separator = NeuralSeparator(
        session: session,
        outputOrder: model.outputOrder,
      );
      final result = await separator.separate(
        source,
        stems,
        onProgress: (fraction) => job._emit(SeparationProgress(
          state: SeparationState.running,
          // Same split as the isolate: loading takes the first slice of the
          // bar and writing the last, so progress tracks wall-clock.
          fraction: (0.05 + fraction * 0.80).clamp(0.0, 1.0),
          message: 'Separating',
        )),
        isCancelled: () => job.isCancelled,
      );

      final written = <StemKind, String>{};
      var index = 0;
      for (final entry in result.stems.entries) {
        final fileName = entry.key.fileName;
        await writeStem('${directory.path}/$fileName', entry.value);
        written[entry.key] = fileName;
        index++;
        job._emit(SeparationProgress(
          state: SeparationState.running,
          fraction: 0.85 + (index / result.stems.length) * 0.15,
          message: 'Saving stems',
        ));
      }

      final stored = await cache.writeManifest(
        sourceKey: sourceKey,
        modelId: model.id,
        stemFileNames: written,
        sampleRate: source.sampleRate,
        channelCount: source.channelCount,
        frameCount: source.frameCount,
        title: title,
      );
      job._emit(const SeparationProgress(
        state: SeparationState.completed,
        fraction: 1,
        message: 'Done',
      ));
      if (!job._result.isCompleted) job._result.complete(stored);
      job._close();
      notifyListeners();
    } on SeparationCancelled {
      await job._discardPartialOutput();
      _fail(job, const SeparationFailure('Separation cancelled.'));
    } on InferenceUnavailable catch (error) {
      await job._discardPartialOutput();
      _fail(job, SeparationFailure(error.message));
    } on Object catch (error, stackTrace) {
      await job._discardPartialOutput();
      _fail(job, SeparationFailure(
        'Separation failed.',
        details: '$error\n$stackTrace',
      ));
    } finally {
      await session?.close();
    }
  }

  Future<void> _runSpectral({
    required SeparationJob job,
    required String sourceWavPath,
    required String sourceKey,
    required SeparationModel model,
    required Set<StemKind> stems,
    required String title,
  }) async {
    final directory = cache.directoryFor(sourceKey, model.id);
    job._workingDirectory = directory;
    try {
      // Start from a clean directory so a previous interrupted attempt cannot
      // leave a stale stem behind.
      if (await directory.exists()) await directory.delete(recursive: true);
      await directory.create(recursive: true);
    } on FileSystemException catch (error) {
      _fail(job, SeparationFailure(
        'Could not prepare space for the separated stems.',
        details: '$error',
      ));
      return;
    }

    final port = ReceivePort();
    job._port = port;
    job._emit(const SeparationProgress(
      state: SeparationState.running,
      fraction: 0,
      message: 'Starting',
    ));
    notifyListeners();

    port.listen((message) async {
      if (message is SeparationProgressMessage) {
        job._emit(SeparationProgress(
          state: SeparationState.running,
          fraction: message.fraction.clamp(0.0, 1.0),
          message: message.stage,
        ));
      } else if (message is SeparationDoneMessage) {
        final stored = await cache.writeManifest(
          sourceKey: sourceKey,
          modelId: model.id,
          stemFileNames: {
            for (final entry in message.stemFileNames.entries)
              StemKind.values.firstWhere((kind) => kind.name == entry.key):
                  entry.value,
          },
          sampleRate: message.sampleRate,
          channelCount: message.channelCount,
          frameCount: message.frameCount,
          title: title,
        );
        job._emit(const SeparationProgress(
          state: SeparationState.completed,
          fraction: 1,
          message: 'Done',
        ));
        if (!job._result.isCompleted) job._result.complete(stored);
        job._close();
        notifyListeners();
      } else if (message is SeparationErrorMessage) {
        _fail(job, SeparationFailure(message.message, details: message.details));
      }
    });

    try {
      job._isolate = await Isolate.spawn(
        runSeparationIsolate,
        SeparationTask(
          replyPort: port.sendPort,
          sourceWavPath: sourceWavPath,
          outputDirectory: directory.path,
          stemNames: [for (final stem in stems) stem.name],
          options: model.spectralOptions ??
              SpectralSeparationOptions.balanced,
        ),
        errorsAreFatal: true,
        onError: port.sendPort,
        onExit: port.sendPort,
      );
    } on Object catch (error) {
      _fail(job, SeparationFailure(
        'Could not start separation on this device.',
        details: '$error',
      ));
    }
  }

  void _fail(SeparationJob job, SeparationFailure failure) {
    if (job._result.isCompleted) return;
    job._emit(SeparationProgress(
      state: SeparationState.failed,
      fraction: 0,
      message: failure.message,
    ));
    job._result.completeError(failure);
    unawaited(job._discardPartialOutput());
    job._close();
    notifyListeners();
  }

  /// Cancels every running job, e.g. when the app is shutting down.
  void cancelAll() {
    for (final job in activeJobs) {
      job.cancel();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    cancelAll();
    super.dispose();
  }
}

/// Whether a model can run, with the reason when it cannot.
class ModelAvailability {
  const ModelAvailability({required this.isAvailable, this.reason});

  final bool isAvailable;
  final String? reason;
}
