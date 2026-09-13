import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/audio_buffer.dart';
import '../core/waveform.dart';
import '../engine/audio_engine.dart';
import 'asset_store.dart';
import 'edit_commands.dart';
import 'models/audio_asset.dart';
import 'models/clip.dart';
import 'models/project.dart';
import 'models/take.dart';
import 'models/track.dart';
import 'project_graph.dart';
import 'project_repository.dart';

/// The open project, and everything that acts on it.
///
/// It owns three things that have to stay in step: the immutable [Project], the
/// audio loaded for it, and the graph the engine is playing. Every edit goes
/// through [edit], which pushes the previous project onto the undo stack
/// (EDIT-04), rebuilds the graph, and schedules an auto-save (PROJ-03).
class ProjectController extends ChangeNotifier {
  ProjectController({
    required this.repository,
    required this.assets,
    required this.engine,
    Uuid? uuid,
    this.autoSaveDelay = const Duration(seconds: 2),
  }) : _uuid = uuid ?? const Uuid();

  final ProjectRepository repository;
  final AssetStore assets;
  final AudioEngine engine;
  final Uuid _uuid;

  /// How long after the last edit the project is written out.
  final Duration autoSaveDelay;

  static const int _maxUndoSteps = 200;

  Project? _project;
  final List<Project> _undo = [];
  final List<Project> _redo = [];
  Timer? _autoSaveTimer;

  bool _loading = false;
  bool _dirty = false;
  bool _recording = false;
  double _loadProgress = 0;
  String? _error;
  List<AudioAsset> _missingAssets = const [];

  Project? get project => _project;

  bool get hasProject => _project != null;

  bool get isLoading => _loading;

  bool get isDirty => _dirty;

  bool get isRecording => _recording;

  double get loadProgress => _loadProgress;

  /// The last failure, for the UI to show and dismiss.
  String? get error => _error;

  /// Assets referenced by the project whose files could not be read.
  List<AudioAsset> get missingAssets => _missingAssets;

  bool get canUndo => _undo.isNotEmpty;

  bool get canRedo => _redo.isNotEmpty;

  // ------------------------------------------------------------ open and save

  /// Opens a project and loads its audio (PROJ-02).
  Future<void> open(String projectId) async {
    _loading = true;
    _loadProgress = 0;
    _error = null;
    notifyListeners();
    try {
      final loaded = await repository.load(projectId);
      assets.clear();
      _missingAssets = await assets.loadAll(
        loaded.assets,
        onProgress: (progress) {
          _loadProgress = progress;
          notifyListeners();
        },
      );
      _project = loaded;
      _undo.clear();
      _redo.clear();
      _dirty = false;
      _applyToEngine();
    } on ProjectException catch (failure) {
      _error = failure.message;
      _project = null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Adopts an already-loaded project, used straight after creating one.
  Future<void> adopt(Project project) async {
    assets.clear();
    _project = project;
    _missingAssets = await assets.loadAll(project.assets);
    _undo.clear();
    _redo.clear();
    _dirty = false;
    _applyToEngine();
    notifyListeners();
  }

  /// Saves now, cancelling any pending auto-save.
  Future<void> save() async {
    final current = _project;
    if (current == null || _disposed) return;
    _autoSaveTimer?.cancel();
    try {
      _project = await repository.save(current);
      _dirty = false;
    } on ProjectException catch (failure) {
      _error = failure.message;
    }
    notifyListeners();
  }

  /// Saves and releases the audio held for this project.
  Future<void> close({bool save = true}) async {
    engine.stop();
    if (save && _dirty) await this.save();
    _autoSaveTimer?.cancel();
    _project = null;
    _undo.clear();
    _redo.clear();
    assets.clear();
    engine.setGraph(const []);
    notifyListeners();
  }

  // ------------------------------------------------------------------- edits

  /// Applies an edit, recording it for undo.
  ///
  /// [coalesce] merges this edit with the previous one on the undo stack,
  /// which is what keeps dragging a fader from filling the history with a
  /// hundred steps.
  void edit(
    Project Function(Project project) transform, {
    bool coalesce = false,
  }) {
    final current = _project;
    if (current == null) return;
    final next = transform(current);
    if (identical(next, current)) return;

    if (!coalesce || _undo.isEmpty) {
      _undo.add(current);
      if (_undo.length > _maxUndoSteps) _undo.removeAt(0);
    }
    _redo.clear();
    _project = next;
    _dirty = true;
    _applyToEngine();
    _scheduleAutoSave();
    notifyListeners();
  }

  void undo() {
    final current = _project;
    if (current == null || _undo.isEmpty) return;
    _redo.add(current);
    _project = _undo.removeLast();
    _dirty = true;
    _applyToEngine();
    _scheduleAutoSave();
    notifyListeners();
  }

  void redo() {
    final current = _project;
    if (current == null || _redo.isEmpty) return;
    _undo.add(current);
    _project = _redo.removeLast();
    _dirty = true;
    _applyToEngine();
    _scheduleAutoSave();
    notifyListeners();
  }

  /// A fresh identifier for a new clip, track or take.
  String newId() => _uuid.v4();

  // --------------------------------------------------------------- transport

  void play() => engine.play();

  void pause() => engine.pause();

  void stop() => engine.stop();

  void seek(int frame) => engine.seek(frame);

  /// Turns the practice loop on or off (PLAY-04).
  void setLoopEnabled(bool enabled) {
    final current = _project;
    if (current == null) return;
    edit((project) => ProjectEdits.setTransport(
      project,
      project.transport.copyWith(loopEnabled: enabled),
    ));
  }

  void setLoopRegion(int start, int end) {
    edit((project) => ProjectEdits.setLoopRegion(project, start, end));
  }

  void setMetronomeEnabled(bool enabled) {
    edit((project) => ProjectEdits.setTransport(
      project,
      project.transport.copyWith(metronomeEnabled: enabled),
    ));
  }

  // --------------------------------------------------------------- recording

  /// Starts a recording pass into every armed track (REC-01, REC-03).
  Future<void> startRecording({String? deviceId, int channelCount = 1}) async {
    final current = _project;
    if (current == null || _recording) return;
    final armed = current.tracks.where((track) => track.recordArmed).toList();
    if (armed.isEmpty) {
      _error = 'Arm a track before recording.';
      notifyListeners();
      return;
    }
    try {
      await engine.startRecording(
        countInBars: current.transport.metronomeEnabled
            ? current.transport.countInBars
            : 0,
        channelCount: channelCount,
        deviceId: deviceId,
        monitor: armed.any((track) => track.monitorEnabled),
      );
      _recording = true;
      _error = null;
    } on Object catch (failure) {
      _error = '$failure';
    }
    notifyListeners();
  }

  /// Ends the pass and commits the take to the armed track (REC-05).
  Future<Take?> stopRecording() async {
    final current = _project;
    if (current == null || !_recording) return null;
    _recording = false;
    final recorded = await engine.stopRecording();
    notifyListeners();
    if (recorded == null || recorded.audio.frameCount == 0) return null;

    // Where the take goes: the armed track, or any track, or a new one.
    //
    // The last case is not hypothetical. `startRecording` refuses unless a
    // track is armed, but nothing stops the user deleting that track — or
    // every track — while the pass is still running, and then pressing stop.
    // This used to end in `tracks.first` on an empty list and take the app
    // down, losing the performance with it.
    //
    // A recording app must not drop audio somebody just played. If there is
    // nowhere to put the take, make somewhere.
    final destination = _destinationForTake(current) ??
        Track(
          id: newId(),
          name: 'Recording',
          kind: TrackKind.recording,
          recordArmed: true,
        );

    final takeNumber = destination.takes.length + 1;
    final asset = await assets.writeRecording(
      projectId: current.id,
      audio: recorded.audio,
      label: '${destination.name} take $takeNumber',
    );
    final take = Take(
      id: newId(),
      assetId: asset.id,
      name: 'Take $takeNumber',
      recordedAt: DateTime.now(),
      timelineStart: recorded.timelineStart,
      length: recorded.audio.frameCount,
    );
    edit((project) {
      // Resolved again against the project as it is *now*: writing the audio
      // to disk is an await, and the track can disappear during it.
      final existing = _destinationForTake(project);
      final target = existing ?? destination;
      final withTrack = project.tracks.any((track) => track.id == target.id)
          ? project
          : ProjectEdits.addTrack(project, target);
      return ProjectEdits.addTake(withTrack, target.id, take, asset, newId);
    });
    await save();
    return take;
  }

  /// The track a finished take belongs to: the armed one, else any one.
  ///
  /// Null means the project has no tracks at all, and the caller has to make
  /// one rather than drop the recording.
  static Track? _destinationForTake(Project project) {
    for (final track in project.tracks) {
      if (track.recordArmed) return track;
    }
    return project.tracks.isEmpty ? null : project.tracks.first;
  }

  // ------------------------------------------------------------------ tracks

  /// Adds a track that plays an existing WAV file — a separated stem or a
  /// library decode — without copying the audio.
  Future<Track> addTrackFromFile({
    required String path,
    required String name,
    required TrackKind kind,
    AssetOrigin origin = AssetOrigin.separated,
    int timelineStart = 0,
  }) async {
    final current = _project;
    if (current == null) {
      throw StateError('no project is open');
    }
    final asset = await assets.reference(
      path: path,
      origin: origin,
      label: name,
    );
    await assets.load(asset);

    final track = Track(
      id: newId(),
      name: name,
      kind: kind,
      clips: [
        Clip(
          id: newId(),
          assetId: asset.id,
          timelineStart: timelineStart,
          assetOffset: 0,
          length: asset.frameCount,
        ),
      ],
    );
    edit((project) =>
        ProjectEdits.addTrack(project.withAsset(asset), track));
    return track;
  }

  /// Adds an empty track to record onto (REC-03).
  Track addEmptyTrack({String? name, TrackKind kind = TrackKind.recording}) {
    final current = _project;
    if (current == null) {
      throw StateError('no project is open');
    }
    final index = current.tracks.length + 1;
    final track = Track(
      id: newId(),
      name: name ?? 'Track $index',
      kind: kind,
      recordArmed: true,
    );
    edit((project) => ProjectEdits.addTrack(project, track));
    return track;
  }

  /// Envelope for a clip's asset, for the timeline to draw (UI-01).
  Future<WaveformPeaks> peaksForAsset(String assetId) async {
    final current = _project;
    final asset = current?.assetById(assetId);
    if (asset == null) return WaveformPeaks.empty;
    return assets.peaks(asset);
  }

  AudioBuffer? bufferForAsset(String assetId) => assets.bufferFor(assetId);

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  // ----------------------------------------------------------------- internal

  void _applyToEngine() {
    final current = _project;
    if (current == null) return;
    engine.setGraph(ProjectGraph.build(current, assets.buffers));
    engine.setMaster(
      gain: current.mix.masterGain,
      limiterEnabled: current.mix.limiterEnabled,
      ceilingDb: current.mix.limiterCeilingDb,
    );
    engine.setMetronome(
      enabled: current.transport.metronomeEnabled,
      tempoBpm: current.transport.tempoBpm,
      beatsPerBar: current.transport.beatsPerBar,
    );
    engine.setLoop(
      enabled: current.transport.loopEnabled && current.transport.hasLoopRegion,
      start: current.transport.loopStart,
      end: current.transport.loopEnd,
    );
  }

  void _scheduleAutoSave() {
    if (_disposed) return;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(autoSaveDelay, () => unawaited(save()));
  }

  /// True once [dispose] has run.
  ///
  /// Cancelling the timer in [dispose] is not on its own enough. `edit`
  /// schedules the next auto-save *before* it notifies, so an edit arriving
  /// after disposal would leave a fresh timer behind to fire against a dead
  /// controller — writing a project to disk that nothing is watching any more,
  /// and tripping ChangeNotifier's use-after-dispose assert in debug. The flag
  /// makes teardown final whatever order the calls arrive in.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    super.dispose();
  }
}
