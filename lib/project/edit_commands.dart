import 'dart:math' as math;

import 'models/audio_asset.dart';
import 'models/clip.dart';
import 'models/mix_settings.dart';
import 'models/project.dart';
import 'models/take.dart';
import 'models/track.dart';
import 'models/transport_settings.dart';

/// Generates ids for newly created clips and tracks.
typedef IdFactory = String Function();

/// Pure transformations over a [Project].
///
/// Every editing operation is a function from one project to the next, with no
/// hidden state and no audio touched: trims and splits only change which range
/// of an asset a clip plays (EDIT-01, EDIT-03). That makes undo a matter of
/// keeping the previous value (EDIT-04), and makes every edit directly
/// testable without an audio device.
class ProjectEdits {
  const ProjectEdits._();

  // ------------------------------------------------------------------ tracks

  static Project addTrack(Project project, Track track) =>
      project.copyWith(tracks: [...project.tracks, track]);

  static Project removeTrack(Project project, String trackId) {
    return project.copyWith(
      tracks: project.tracks.where((track) => track.id != trackId).toList(),
    );
  }

  static Project renameTrack(Project project, String trackId, String name) =>
      _mapTrack(project, trackId, (track) => track.copyWith(name: name));

  static Project setTrackGain(Project project, String trackId, double gain) =>
      _mapTrack(project, trackId,
          (track) => track.copyWith(gain: gain.clamp(0.0, 4.0)));

  static Project setTrackPan(Project project, String trackId, double pan) =>
      _mapTrack(project, trackId,
          (track) => track.copyWith(pan: pan.clamp(-1.0, 1.0)));

  static Project setTrackMuted(Project project, String trackId, bool muted) =>
      _mapTrack(project, trackId, (track) => track.copyWith(muted: muted));

  /// Toggling solo on one track leaves the others alone: several tracks can be
  /// soloed at once, which is what a mixer does.
  static Project setTrackSoloed(Project project, String trackId, bool soloed) =>
      _mapTrack(project, trackId, (track) => track.copyWith(soloed: soloed));

  static Project setTrackArmed(Project project, String trackId, bool armed) =>
      _mapTrack(project, trackId, (track) => track.copyWith(recordArmed: armed));

  static Project setTrackMonitoring(
    Project project,
    String trackId,
    bool monitoring,
  ) =>
      _mapTrack(project, trackId,
          (track) => track.copyWith(monitorEnabled: monitoring));

  static Project reorderTracks(Project project, int from, int to) {
    if (from == to) return project;
    final tracks = [...project.tracks];
    if (from < 0 || from >= tracks.length) return project;
    final moved = tracks.removeAt(from);
    tracks.insert(to.clamp(0, tracks.length), moved);
    return project.copyWith(tracks: tracks);
  }

  // ------------------------------------------------------------------- clips

  static Project addClip(Project project, String trackId, Clip clip) =>
      _mapTrack(project, trackId,
          (track) => track.copyWith(clips: _sorted([...track.clips, clip])));

  static Project removeClip(Project project, String trackId, String clipId) {
    return _mapTrack(
      project,
      trackId,
      (track) => track.copyWith(
        clips: track.clips.where((clip) => clip.id != clipId).toList(),
      ),
    );
  }

  /// Moves a clip along the timeline, never before frame zero (EDIT-01).
  static Project moveClip(
    Project project,
    String trackId,
    String clipId,
    int deltaFrames,
  ) {
    return _mapClip(project, trackId, clipId, (clip) {
      final start = math.max(0, clip.timelineStart + deltaFrames);
      return clip.copyWith(timelineStart: start);
    });
  }

  /// Moves a clip to another track, keeping its position in time.
  static Project moveClipToTrack(
    Project project,
    String fromTrackId,
    String toTrackId,
    String clipId,
  ) {
    final source = project.trackById(fromTrackId);
    final target = project.trackById(toTrackId);
    if (source == null || target == null || fromTrackId == toTrackId) {
      return project;
    }
    Clip? moved;
    for (final clip in source.clips) {
      if (clip.id == clipId) moved = clip;
    }
    if (moved == null) return project;
    var result = removeClip(project, fromTrackId, clipId);
    return addClip(result, toTrackId, moved);
  }

  /// Trims the start of a clip to [frame] on the timeline.
  static Project trimClipStart(
    Project project,
    String trackId,
    String clipId,
    int frame,
  ) {
    return _mapClip(project, trackId, clipId, (clip) {
      // The clip cannot be trimmed back past the start of the asset it plays.
      final int earliest = math.max(0, clip.timelineStart - clip.assetOffset);
      final target = frame.clamp(earliest, clip.timelineEnd - 1);
      final delta = target - clip.timelineStart;
      return clip.copyWith(
        timelineStart: target,
        assetOffset: clip.assetOffset + delta,
        length: clip.length - delta,
      );
    });
  }

  /// Trims the end of a clip to [frame] on the timeline.
  static Project trimClipEnd(
    Project project,
    String trackId,
    String clipId,
    int frame,
  ) {
    final asset = _assetForClip(project, trackId, clipId);
    return _mapClip(project, trackId, clipId, (clip) {
      final maximum = asset == null
          ? clip.timelineEnd
          : clip.timelineStart + (asset.frameCount - clip.assetOffset);
      final target = frame.clamp(clip.timelineStart + 1, maximum);
      return clip.copyWith(length: target - clip.timelineStart);
    });
  }

  /// Splits a clip at [frame], leaving two clips over the same asset
  /// (EDIT-01).
  static Project splitClip(
    Project project,
    String trackId,
    String clipId,
    int frame,
    IdFactory newId,
  ) {
    final track = project.trackById(trackId);
    if (track == null) return project;
    final clips = <Clip>[];
    var changed = false;
    for (final clip in track.clips) {
      if (clip.id != clipId ||
          frame <= clip.timelineStart ||
          frame >= clip.timelineEnd) {
        clips.add(clip);
        continue;
      }
      changed = true;
      final firstLength = frame - clip.timelineStart;
      clips.add(clip.copyWith(
        length: firstLength,
        // The fade-out belongs to the second half now.
        fadeOutFrames: 0,
      ));
      clips.add(clip.copyWith(
        id: newId(),
        timelineStart: frame,
        assetOffset: clip.assetOffset + firstLength,
        length: clip.length - firstLength,
        fadeInFrames: 0,
      ));
    }
    if (!changed) return project;
    return project.withTrack(track.copyWith(clips: _sorted(clips)));
  }

  /// Removes `[startFrame, endFrame)` from a track, splitting clips that
  /// straddle the boundaries (EDIT-01).
  static Project deleteRange(
    Project project,
    String trackId,
    int startFrame,
    int endFrame,
    IdFactory newId,
  ) {
    final track = project.trackById(trackId);
    if (track == null || endFrame <= startFrame) return project;
    final clips = <Clip>[];
    for (final clip in track.clips) {
      if (!clip.intersects(startFrame, endFrame)) {
        clips.add(clip);
        continue;
      }
      // Keep whatever sits before the range...
      if (clip.timelineStart < startFrame) {
        clips.add(clip.copyWith(
          length: startFrame - clip.timelineStart,
          fadeOutFrames: 0,
        ));
      }
      // ...and whatever sits after it.
      if (clip.timelineEnd > endFrame) {
        final offset = endFrame - clip.timelineStart;
        clips.add(clip.copyWith(
          id: newId(),
          timelineStart: endFrame,
          assetOffset: clip.assetOffset + offset,
          length: clip.timelineEnd - endFrame,
          fadeInFrames: 0,
        ));
      }
    }
    return project.withTrack(track.copyWith(clips: _sorted(clips)));
  }

  /// Sets fade lengths on a clip (EDIT-02).
  static Project setClipFades(
    Project project,
    String trackId,
    String clipId, {
    int? fadeInFrames,
    int? fadeOutFrames,
  }) {
    return _mapClip(project, trackId, clipId, (clip) {
      final fadeIn = (fadeInFrames ?? clip.fadeInFrames).clamp(0, clip.length);
      final fadeOut = (fadeOutFrames ?? clip.fadeOutFrames).clamp(0, clip.length);
      return clip.copyWith(fadeInFrames: fadeIn, fadeOutFrames: fadeOut);
    });
  }

  static Project setClipGain(
    Project project,
    String trackId,
    String clipId,
    double gain,
  ) {
    return _mapClip(project, trackId, clipId,
        (clip) => clip.copyWith(gain: gain.clamp(0.0, 4.0)));
  }

  /// Crossfades two adjacent clips by [frames], pulling the later clip earlier
  /// so the two overlap and fade through each other (EDIT-02).
  static Project crossfade(
    Project project,
    String trackId,
    String firstClipId,
    String secondClipId,
    int frames,
  ) {
    final track = project.trackById(trackId);
    if (track == null || frames <= 0) return project;
    Clip? first;
    Clip? second;
    for (final clip in track.clips) {
      if (clip.id == firstClipId) first = clip;
      if (clip.id == secondClipId) second = clip;
    }
    if (first == null || second == null) return project;
    final overlap = math.min(frames, math.min(first.length, second.length));
    if (overlap <= 0) return project;

    final movedSecond = second.copyWith(
      timelineStart: second.timelineStart - overlap,
      assetOffset: second.assetOffset,
      fadeInFrames: overlap,
    );
    final fadedFirst = first.copyWith(fadeOutFrames: overlap);
    return project.withTrack(track.copyWith(
      clips: _sorted([
        for (final clip in track.clips)
          if (clip.id == firstClipId)
            fadedFirst
          else if (clip.id == secondClipId)
            movedSecond
          else
            clip,
      ]),
    ));
  }

  // ------------------------------------------------------------------- takes

  /// Adds a recorded take and makes it the one on the timeline (REC-05).
  static Project addTake(
    Project project,
    String trackId,
    Take take,
    AudioAsset asset,
    IdFactory newId,
  ) {
    final withAsset = project.withAsset(asset);
    return _mapTrack(withAsset, trackId, (track) {
      return track.copyWith(
        takes: [...track.takes, take],
        activeTakeId: take.id,
        clips: _clipsForTake(take, newId),
      );
    });
  }

  /// Switches which take is heard, replacing the track's clips (REC-05).
  static Project selectTake(
    Project project,
    String trackId,
    String takeId,
    IdFactory newId,
  ) {
    return _mapTrack(project, trackId, (track) {
      Take? chosen;
      for (final take in track.takes) {
        if (take.id == takeId) chosen = take;
      }
      if (chosen == null) return track;
      return track.copyWith(
        activeTakeId: takeId,
        clips: _clipsForTake(chosen, newId),
      );
    });
  }

  static Project removeTake(Project project, String trackId, String takeId) {
    return _mapTrack(project, trackId, (track) {
      final remaining =
          track.takes.where((take) => take.id != takeId).toList();
      if (track.activeTakeId != takeId) {
        return track.copyWith(takes: remaining);
      }
      return track.copyWith(
        takes: remaining,
        clearActiveTake: true,
        clips: const [],
      );
    });
  }

  static List<Clip> _clipsForTake(Take take, IdFactory newId) => [
    Clip(
      id: newId(),
      assetId: take.assetId,
      timelineStart: take.timelineStart,
      assetOffset: 0,
      length: take.length,
    ),
  ];

  // -------------------------------------------------------- mix and transport

  static Project setMix(Project project, MixSettings mix) =>
      project.copyWith(mix: mix);

  static Project setTransport(Project project, TransportSettings transport) =>
      project.copyWith(transport: transport);

  /// Sets the practice loop region (PLAY-04).
  static Project setLoopRegion(Project project, int start, int end) {
    final low = math.max(0, math.min(start, end));
    final high = math.max(start, end);
    return project.copyWith(
      transport: project.transport.copyWith(loopStart: low, loopEnd: high),
    );
  }

  static Project rename(Project project, String name) =>
      project.copyWith(name: name);

  // ----------------------------------------------------------------- helpers

  static Project _mapTrack(
    Project project,
    String trackId,
    Track Function(Track track) transform,
  ) {
    final track = project.trackById(trackId);
    if (track == null) return project;
    return project.withTrack(transform(track));
  }

  static Project _mapClip(
    Project project,
    String trackId,
    String clipId,
    Clip Function(Clip clip) transform,
  ) {
    return _mapTrack(project, trackId, (track) {
      return track.copyWith(
        clips: _sorted([
          for (final clip in track.clips)
            if (clip.id == clipId) transform(clip) else clip,
        ]),
      );
    });
  }

  static AudioAsset? _assetForClip(
    Project project,
    String trackId,
    String clipId,
  ) {
    final track = project.trackById(trackId);
    if (track == null) return null;
    for (final clip in track.clips) {
      if (clip.id == clipId) return project.assetById(clip.assetId);
    }
    return null;
  }

  /// Keeping clips in timeline order makes rendering and hit-testing simple
  /// and keeps saved files diffable.
  static List<Clip> _sorted(List<Clip> clips) {
    final sorted = [...clips]
      ..removeWhere((clip) => clip.isEmpty)
      ..sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
    return sorted;
  }
}
