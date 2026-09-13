import 'dart:math' as math;

import '../core/audio_buffer.dart';

/// A clip as the renderer sees it: a window onto an in-memory asset.
class GraphClip {
  const GraphClip({
    required this.asset,
    required this.timelineStart,
    required this.assetOffset,
    required this.length,
    this.gain = 1.0,
    this.fadeInFrames = 0,
    this.fadeOutFrames = 0,
  });

  final AudioBuffer asset;
  final int timelineStart;
  final int assetOffset;
  final int length;
  final double gain;
  final int fadeInFrames;
  final int fadeOutFrames;

  int get timelineEnd => timelineStart + length;

  /// Linear fade envelope [frame] frames into the clip.
  double envelopeAt(int frame) {
    var envelope = 1.0;
    final fadeIn = math.min(fadeInFrames, length);
    final fadeOut = math.min(fadeOutFrames, length);
    if (fadeIn > 0 && frame < fadeIn) {
      envelope *= (frame + 0.5) / fadeIn;
    }
    if (fadeOut > 0) {
      final remaining = length - frame;
      if (remaining <= fadeOut) envelope *= (remaining - 0.5) / fadeOut;
    }
    return envelope < 0 ? 0 : (envelope > 1 ? 1 : envelope);
  }
}

/// A track as the renderer sees it.
class GraphTrack {
  const GraphTrack({
    required this.id,
    required this.clips,
    this.gain = 1.0,
    this.pan = 0.0,
    this.audible = true,
  });

  final String id;
  final List<GraphClip> clips;

  /// Linear gain (PLAY-03, MIX-01).
  final double gain;

  /// -1 hard left … +1 hard right (MIX-01).
  final double pan;

  /// False when the track is muted, or when something else is soloed.
  final bool audible;
}

/// Sums tracks into a stereo bus.
///
/// This is the whole of multi-track playback: every track is read from the same
/// timeline frame in the same call, so tracks cannot drift relative to each
/// other — they are sample-locked by construction rather than by
/// synchronisation (PLAY-02). The same code renders the live output and the
/// offline export, so what is exported is exactly what was heard (MIX-01).
class MixGraph {
  MixGraph({required this.sampleRate, this.channelCount = 2});

  final int sampleRate;
  final int channelCount;

  List<GraphTrack> tracks = const [];

  /// One past the last frame that contains audio.
  int get endFrame {
    var end = 0;
    for (final track in tracks) {
      for (final clip in track.clips) {
        if (clip.timelineEnd > end) end = clip.timelineEnd;
      }
    }
    return end;
  }

  /// Renders `[startFrame, startFrame + frames)` into [destination] starting
  /// at [destinationOffset], adding to whatever is already there.
  ///
  /// The offset exists so the engine can fill part of an output block, jump
  /// the transport (a loop wrap) and fill the rest, without allocating a
  /// scratch buffer on every callback.
  void render(
    int startFrame,
    AudioBuffer destination, {
    int destinationOffset = 0,
    int? frames,
  }) {
    for (final track in tracks) {
      if (!track.audible || track.gain == 0) continue;
      renderTrack(
        track,
        startFrame,
        destination,
        destinationOffset: destinationOffset,
        frames: frames,
      );
    }
  }

  /// Renders a single track, used both by [render] and by stem export
  /// (MIX-03).
  void renderTrack(
    GraphTrack track,
    int startFrame,
    AudioBuffer destination, {
    int destinationOffset = 0,
    int? frames,
  }) {
    // Never write past the destination, whatever the caller asked for.
    //
    // A loop wrap renders in two parts and computes `frames` from the loop
    // region rather than from the buffer, so a region shorter than a block —
    // or a destinationOffset close to the end — used to run the write index
    // off the end of the output. In a test that is a RangeError; on the audio
    // thread it is a crash in the callback, which takes the audio device with
    // it.
    final available = destination.frameCount - destinationOffset;
    if (available <= 0) return;
    final length = math.min(frames ?? available, available);
    if (length <= 0) return;
    final endFrame = startFrame + length;
    final (leftGain, rightGain) = panGains(track.pan);

    for (final clip in track.clips) {
      if (clip.timelineEnd <= startFrame || clip.timelineStart >= endFrame) {
        continue;
      }
      final from = math.max(clip.timelineStart, startFrame);
      final to = math.min(clip.timelineEnd, endFrame);
      final asset = clip.asset;
      final trackGain = track.gain * clip.gain;

      for (var frame = from; frame < to; frame++) {
        final positionInClip = frame - clip.timelineStart;
        final assetFrame = clip.assetOffset + positionInClip;
        if (assetFrame < 0 || assetFrame >= asset.frameCount) continue;
        final amplitude = trackGain * clip.envelopeAt(positionInClip);
        final destinationFrame = destinationOffset + (frame - startFrame);

        if (channelCount == 1) {
          var sum = 0.0;
          for (var ch = 0; ch < asset.channelCount; ch++) {
            sum += asset.channels[ch][assetFrame];
          }
          destination.channels[0][destinationFrame] +=
              (sum / asset.channelCount) * amplitude;
          continue;
        }

        // A mono asset is fed to both sides; a stereo asset keeps its image.
        final left = asset.channels[0][assetFrame];
        final right = asset.channelCount > 1
            ? asset.channels[1][assetFrame]
            : left;
        destination.channels[0][destinationFrame] +=
            left * amplitude * leftGain;
        destination.channels[1][destinationFrame] +=
            right * amplitude * rightGain;
      }
    }
  }

  /// Constant-power pan law: a centred source is -3 dB in each channel, so
  /// sweeping the control does not change the perceived loudness.
  static (double, double) panGains(double pan) {
    final position = pan.clamp(-1.0, 1.0);
    final angle = (position + 1) * math.pi / 4;
    return (math.cos(angle), math.sin(angle));
  }
}
