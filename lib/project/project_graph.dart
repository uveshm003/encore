import '../core/audio_buffer.dart';
import '../engine/mix_graph.dart';
import 'models/project.dart';
import 'models/track.dart';

/// Turns the saved project model into the flat structure the renderer walks.
///
/// This is the only place the two representations meet: the project is
/// immutable and describes intent, the graph is a snapshot the audio thread can
/// read without allocating or looking anything up.
class ProjectGraph {
  const ProjectGraph._();

  /// Builds the graph for [project] using audio already loaded in [buffers].
  ///
  /// Clips whose asset is not resident are skipped rather than silently
  /// producing silence for the whole track — an asset still loading simply has
  /// not appeared yet, and the graph is rebuilt when it does.
  static List<GraphTrack> build(
    Project project,
    Map<String, AudioBuffer> buffers, {
    Set<String> excludedTrackIds = const {},
  }) {
    final tracks = <GraphTrack>[];
    for (final track in project.tracks) {
      if (excludedTrackIds.contains(track.id)) continue;
      final clips = <GraphClip>[];
      for (final clip in track.clips) {
        final asset = buffers[clip.assetId];
        if (asset == null) continue;
        clips.add(GraphClip(
          asset: asset,
          timelineStart: clip.timelineStart,
          assetOffset: clip.assetOffset,
          length: clip.length,
          gain: clip.gain,
          fadeInFrames: clip.fadeInFrames,
          fadeOutFrames: clip.fadeOutFrames,
        ));
      }
      tracks.add(GraphTrack(
        id: track.id,
        clips: clips,
        gain: track.gain,
        pan: track.pan,
        audible: project.isAudible(track),
      ));
    }
    return tracks;
  }

  /// A graph containing only [track], used for stem export (MIX-03).
  static GraphTrack buildTrack(
    Project project,
    Track track,
    Map<String, AudioBuffer> buffers,
  ) {
    final built = build(project, buffers);
    for (final candidate in built) {
      if (candidate.id == track.id) {
        // Exported on its own, a track is heard regardless of mute and solo.
        return GraphTrack(
          id: candidate.id,
          clips: candidate.clips,
          gain: candidate.gain,
          pan: candidate.pan,
        );
      }
    }
    return GraphTrack(id: track.id, clips: const []);
  }
}
