import '../engine/engine_config.dart';
import '../library/media_item.dart';
import '../separation/stem_cache.dart';
import '../separation/stem_kind.dart';
import 'asset_store.dart';
import 'models/audio_asset.dart';
import 'models/clip.dart';
import 'models/project.dart';
import 'models/track.dart';
import 'project_repository.dart';

/// Builds the project a user actually wants after separating a song.
///
/// The point of the app is to sing over the instrumental, so a new project
/// opens ready to do exactly that: the backing is up and audible, the original
/// vocal is there but muted as a reference, and an empty track is already armed
/// so pressing record works without any setup (§3.3 use cases 1–3).
class ProjectFactory {
  const ProjectFactory({required this.repository, required this.assets});

  final ProjectRepository repository;
  final AssetStore assets;

  /// Creates a project from separated stems.
  Future<Project> fromStems({
    required MediaItem source,
    required CachedStems stems,
    EngineConfig config = const EngineConfig(),
    String? name,
  }) async {
    var project = await repository.create(
      name: name ?? source.title,
      config: config,
      sourceMediaId: source.id,
      sourceTitle: source.title,
    );

    final tracks = <Track>[];
    final registered = <AudioAsset>[];

    for (final kind in _order) {
      final path = stems.paths[kind];
      if (path == null) continue;
      final asset = await assets.reference(
        path: path,
        origin: AssetOrigin.separated,
        label: kind.displayName,
      );
      registered.add(asset);
      tracks.add(Track(
        id: _id(),
        name: kind.displayName,
        kind: _trackKindFor(kind),
        // The original vocal is kept for reference but starts silent — it is
        // the thing the user is replacing.
        muted: kind == StemKind.vocals,
        clips: [
          Clip(
            id: _id(),
            assetId: asset.id,
            timelineStart: 0,
            assetOffset: 0,
            length: asset.frameCount,
          ),
        ],
      ));
    }

    tracks.add(Track(
      id: _id(),
      name: 'My vocal',
      kind: TrackKind.recording,
      recordArmed: true,
    ));

    project = project.copyWith(assets: registered, tracks: tracks);
    return repository.save(project);
  }

  /// Creates a project that just plays an imported song, for when the user
  /// wants to rehearse against the original rather than separate it.
  Future<Project> fromMedia({
    required MediaItem source,
    required String audioPath,
    EngineConfig config = const EngineConfig(),
    String? name,
  }) async {
    var project = await repository.create(
      name: name ?? source.title,
      config: config,
      sourceMediaId: source.id,
      sourceTitle: source.title,
    );
    final asset = await assets.reference(
      path: audioPath,
      origin: AssetOrigin.imported,
      label: source.title,
    );
    project = project.copyWith(
      assets: [asset],
      tracks: [
        Track(
          id: _id(),
          name: source.title,
          kind: TrackKind.reference,
          clips: [
            Clip(
              id: _id(),
              assetId: asset.id,
              timelineStart: 0,
              assetOffset: 0,
              length: asset.frameCount,
            ),
          ],
        ),
        Track(
          id: _id(),
          name: 'My vocal',
          kind: TrackKind.recording,
          recordArmed: true,
        ),
      ],
    );
    return repository.save(project);
  }

  /// Stems are laid out backing-first so the instrumental is the top lane.
  static const List<StemKind> _order = [
    StemKind.instrumental,
    StemKind.drums,
    StemKind.bass,
    StemKind.other,
    StemKind.vocals,
  ];

  static TrackKind _trackKindFor(StemKind stem) => switch (stem) {
    StemKind.vocals => TrackKind.vocals,
    StemKind.instrumental => TrackKind.instrumental,
    StemKind.drums => TrackKind.drums,
    StemKind.bass => TrackKind.bass,
    StemKind.other => TrackKind.other,
  };

  String _id() => assets.newAssetId();
}
