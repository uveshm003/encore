import 'package:encore/project/edit_commands.dart';
import 'package:encore/project/models/audio_asset.dart';
import 'package:encore/project/models/clip.dart';
import 'package:encore/project/models/project.dart';
import 'package:encore/project/models/take.dart';
import 'package:encore/project/models/track.dart';
import 'package:flutter_test/flutter_test.dart';

var _nextId = 0;
String newId() => 'id-${_nextId++}';

Project projectWithClip({
  int timelineStart = 1000,
  int assetOffset = 0,
  int length = 4000,
  int assetFrames = 10000,
}) {
  return Project(
    id: 'p',
    name: 'Test',
    sampleRate: 48000,
    createdAt: DateTime(2026),
    modifiedAt: DateTime(2026),
    assets: [
      AudioAsset(
        id: 'asset',
        path: '/tmp/asset.wav',
        origin: AssetOrigin.imported,
        sampleRate: 48000,
        channelCount: 2,
        frameCount: assetFrames,
      ),
    ],
    tracks: [
      Track(
        id: 'track',
        name: 'Backing',
        kind: TrackKind.instrumental,
        clips: [
          Clip(
            id: 'clip',
            assetId: 'asset',
            timelineStart: timelineStart,
            assetOffset: assetOffset,
            length: length,
          ),
        ],
      ),
    ],
  );
}

void main() {
  setUp(() => _nextId = 0);

  group('clips', () {
    test('split produces two clips over the same asset', () {
      final project = projectWithClip();

      final split =
          ProjectEdits.splitClip(project, 'track', 'clip', 3000, newId);
      final clips = split.tracks.single.clips;

      expect(clips, hasLength(2));
      expect(clips[0].timelineStart, 1000);
      expect(clips[0].length, 2000);
      expect(clips[1].timelineStart, 3000);
      expect(clips[1].assetOffset, 2000);
      expect(clips[1].length, 2000);
      // The two halves still add up to the original range.
      expect(clips[0].length + clips[1].length, 4000);
    });

    test('split outside the clip changes nothing', () {
      final project = projectWithClip();

      final before =
          ProjectEdits.splitClip(project, 'track', 'clip', 10, newId);
      final after =
          ProjectEdits.splitClip(project, 'track', 'clip', 99000, newId);

      expect(before.tracks.single.clips, hasLength(1));
      expect(after.tracks.single.clips, hasLength(1));
    });

    test('trimming the start moves the asset offset with it', () {
      final project = projectWithClip(assetOffset: 500);

      final trimmed =
          ProjectEdits.trimClipStart(project, 'track', 'clip', 1500);
      final clip = trimmed.tracks.single.clips.single;

      expect(clip.timelineStart, 1500);
      expect(clip.assetOffset, 1000);
      expect(clip.length, 3500);
    });

    test('trimming the start cannot run past the head of the asset', () {
      final project = projectWithClip(timelineStart: 1000, assetOffset: 200);

      final trimmed =
          ProjectEdits.trimClipStart(project, 'track', 'clip', 0);
      final clip = trimmed.tracks.single.clips.single;

      // Only 200 frames of asset exist before the clip's current start.
      expect(clip.timelineStart, 800);
      expect(clip.assetOffset, 0);
    });

    test('trimming the end cannot run past the tail of the asset', () {
      final project =
          projectWithClip(assetOffset: 9000, length: 500, assetFrames: 10000);

      final trimmed =
          ProjectEdits.trimClipEnd(project, 'track', 'clip', 99000);
      final clip = trimmed.tracks.single.clips.single;

      expect(clip.length, 1000);
    });

    test('deleting a range splits a clip around the hole', () {
      final project = projectWithClip();

      final edited = ProjectEdits.deleteRange(
        project,
        'track',
        2000,
        3000,
        newId,
      );
      final clips = edited.tracks.single.clips;

      expect(clips, hasLength(2));
      expect(clips[0].timelineStart, 1000);
      expect(clips[0].length, 1000);
      expect(clips[1].timelineStart, 3000);
      expect(clips[1].assetOffset, 2000);
      expect(clips[1].length, 2000);
    });

    test('deleting a range that covers the clip removes it', () {
      final project = projectWithClip();

      final edited =
          ProjectEdits.deleteRange(project, 'track', 0, 99000, newId);

      expect(edited.tracks.single.clips, isEmpty);
    });

    test('moving a clip never takes it before zero', () {
      final project = projectWithClip(timelineStart: 100);

      final moved = ProjectEdits.moveClip(project, 'track', 'clip', -5000);

      expect(moved.tracks.single.clips.single.timelineStart, 0);
    });

    test('fades are clamped to the clip length', () {
      final project = projectWithClip(length: 1000);

      final faded = ProjectEdits.setClipFades(
        project,
        'track',
        'clip',
        fadeInFrames: 99000,
        fadeOutFrames: 300,
      );
      final clip = faded.tracks.single.clips.single;

      expect(clip.fadeInFrames, 1000);
      expect(clip.fadeOutFrames, 300);
    });

    test('crossfade overlaps the clips and fades them through each other', () {
      var project = projectWithClip(length: 2000);
      project = ProjectEdits.addClip(
        project,
        'track',
        const Clip(
          id: 'second',
          assetId: 'asset',
          timelineStart: 3000,
          assetOffset: 4000,
          length: 2000,
        ),
      );

      final faded =
          ProjectEdits.crossfade(project, 'track', 'clip', 'second', 400);
      final clips = faded.tracks.single.clips;

      expect(clips.first.fadeOutFrames, 400);
      expect(clips.last.timelineStart, 2600);
      expect(clips.last.fadeInFrames, 400);
    });

    test('clips stay sorted by position', () {
      var project = projectWithClip(timelineStart: 5000);
      project = ProjectEdits.addClip(
        project,
        'track',
        const Clip(
          id: 'early',
          assetId: 'asset',
          timelineStart: 0,
          assetOffset: 0,
          length: 500,
        ),
      );

      expect(
        project.tracks.single.clips.map((clip) => clip.id),
        ['early', 'clip'],
      );
    });
  });

  group('tracks', () {
    test('gain and pan are clamped to sensible ranges', () {
      final project = projectWithClip();

      expect(
        ProjectEdits.setTrackGain(project, 'track', 99).tracks.single.gain,
        4.0,
      );
      expect(
        ProjectEdits.setTrackPan(project, 'track', -9).tracks.single.pan,
        -1.0,
      );
    });

    test('solo silences other tracks', () {
      var project = projectWithClip();
      project = ProjectEdits.addTrack(
        project,
        const Track(id: 'other', name: 'Other', kind: TrackKind.recording),
      );
      project = ProjectEdits.setTrackSoloed(project, 'track', true);

      expect(project.isAudible(project.tracks[0]), isTrue);
      expect(project.isAudible(project.tracks[1]), isFalse);
    });

    test('mute is ignored while something else is soloed', () {
      var project = projectWithClip();
      project = ProjectEdits.setTrackMuted(project, 'track', true);
      expect(project.isAudible(project.tracks.single), isFalse);

      project = ProjectEdits.setTrackSoloed(project, 'track', true);
      expect(project.isAudible(project.tracks.single), isTrue);
    });

    test('removing a track leaves the rest alone', () {
      var project = projectWithClip();
      project = ProjectEdits.addTrack(
        project,
        const Track(id: 'other', name: 'Other', kind: TrackKind.recording),
      );

      final edited = ProjectEdits.removeTrack(project, 'track');

      expect(edited.tracks.map((track) => track.id), ['other']);
    });
  });

  group('takes', () {
    Take makeTake(String id, int start) => Take(
      id: id,
      assetId: 'take-asset-$id',
      name: 'Take $id',
      recordedAt: DateTime(2026),
      timelineStart: start,
      length: 5000,
    );

    AudioAsset makeAsset(String id) => AudioAsset(
      id: 'take-asset-$id',
      path: '/tmp/$id.wav',
      origin: AssetOrigin.recorded,
      sampleRate: 48000,
      channelCount: 1,
      frameCount: 5000,
    );

    test('adding a take puts it on the timeline', () {
      final project = projectWithClip();

      final edited = ProjectEdits.addTake(
        project,
        'track',
        makeTake('a', 2000),
        makeAsset('a'),
        newId,
      );
      final track = edited.tracks.single;

      expect(track.activeTakeId, 'a');
      expect(track.clips.single.assetId, 'take-asset-a');
      expect(track.clips.single.timelineStart, 2000);
      expect(edited.assetById('take-asset-a'), isNotNull);
    });

    test('choosing another take swaps what is heard', () {
      var project = projectWithClip();
      project = ProjectEdits.addTake(
        project, 'track', makeTake('a', 0), makeAsset('a'), newId);
      project = ProjectEdits.addTake(
        project, 'track', makeTake('b', 1000), makeAsset('b'), newId);

      expect(project.tracks.single.activeTakeId, 'b');

      project = ProjectEdits.selectTake(project, 'track', 'a', newId);

      expect(project.tracks.single.activeTakeId, 'a');
      expect(project.tracks.single.clips.single.assetId, 'take-asset-a');
      // Both takes are still kept.
      expect(project.tracks.single.takes, hasLength(2));
    });

    test('removing the active take clears the timeline', () {
      var project = projectWithClip();
      project = ProjectEdits.addTake(
        project, 'track', makeTake('a', 0), makeAsset('a'), newId);

      project = ProjectEdits.removeTake(project, 'track', 'a');

      expect(project.tracks.single.takes, isEmpty);
      expect(project.tracks.single.activeTakeId, isNull);
      expect(project.tracks.single.clips, isEmpty);
    });
  });

  group('project', () {
    test('orphaned assets are the ones nothing points at', () {
      var project = projectWithClip();
      project = project.withAsset(
        const AudioAsset(
          id: 'unused',
          path: '/tmp/unused.wav',
          origin: AssetOrigin.rendered,
          sampleRate: 48000,
          channelCount: 2,
          frameCount: 10,
        ),
      );

      expect(project.orphanedAssets.map((asset) => asset.id), ['unused']);
    });

    test('a loop region is normalised whichever way it is dragged', () {
      final project = ProjectEdits.setLoopRegion(projectWithClip(), 9000, 3000);

      expect(project.transport.loopStart, 3000);
      expect(project.transport.loopEnd, 9000);
      expect(project.transport.hasLoopRegion, isTrue);
    });

    test('duration is the end of the longest track', () {
      final project = projectWithClip(timelineStart: 48000, length: 48000);

      expect(project.durationFrames, 96000);
      expect(project.duration.inSeconds, 2);
    });
  });
}
