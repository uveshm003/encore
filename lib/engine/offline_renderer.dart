import 'dart:math' as math;

import '../core/audio_buffer.dart';
import '../core/dsp/limiter.dart';
import 'mix_graph.dart';

/// Renders a graph faster than real time, for export and bouncing.
///
/// It walks the same [MixGraph] the live engine does, in the same block sizes,
/// so an exported file is the mix that was being monitored rather than a
/// second implementation that has to be kept in agreement (MIX-01, MIX-02).
class OfflineRenderer {
  const OfflineRenderer({this.blockFrames = 8192});

  /// Larger than the live block size — nothing here is latency-sensitive, and
  /// bigger blocks mean less per-block overhead.
  final int blockFrames;

  /// Renders `[startFrame, endFrame)` of the whole mix.
  ///
  /// The master limiter is applied exactly as in playback (MIX-04). Because it
  /// looks ahead, the render runs on past [endFrame] by the limiter's latency
  /// and the delayed output is realigned, so the file starts on the first
  /// sample of the timeline rather than a few milliseconds of silence.
  Future<AudioBuffer> renderMix(
    MixGraph graph, {
    required int startFrame,
    required int endFrame,
    double masterGain = 1.0,
    bool limiterEnabled = true,
    double ceilingLinear = 0.97,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) {
    return _render(
      startFrame: startFrame,
      endFrame: endFrame,
      channelCount: graph.channelCount,
      sampleRate: graph.sampleRate,
      masterGain: masterGain,
      limiterEnabled: limiterEnabled,
      ceilingLinear: ceilingLinear,
      onProgress: onProgress,
      isCancelled: isCancelled,
      renderBlock: (position, destination, offset, frames) => graph.render(
        position,
        destination,
        destinationOffset: offset,
        frames: frames,
      ),
    );
  }

  /// Renders one track on its own, for stem export (MIX-03).
  ///
  /// Track gain and pan are applied but the master chain is not, so stems can
  /// be reassembled elsewhere and still add up to the mix.
  Future<AudioBuffer> renderTrack(
    MixGraph graph,
    GraphTrack track, {
    required int startFrame,
    required int endFrame,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) {
    return _render(
      startFrame: startFrame,
      endFrame: endFrame,
      channelCount: graph.channelCount,
      sampleRate: graph.sampleRate,
      masterGain: 1.0,
      limiterEnabled: false,
      ceilingLinear: 1.0,
      onProgress: onProgress,
      isCancelled: isCancelled,
      renderBlock: (position, destination, offset, frames) => graph.renderTrack(
        track,
        position,
        destination,
        destinationOffset: offset,
        frames: frames,
      ),
    );
  }

  Future<AudioBuffer> _render({
    required int startFrame,
    required int endFrame,
    required int channelCount,
    required int sampleRate,
    required double masterGain,
    required bool limiterEnabled,
    required double ceilingLinear,
    required void Function(int position, AudioBuffer destination, int offset,
            int frames)
        renderBlock,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final total = math.max(0, endFrame - startFrame);
    final output = AudioBuffer.silence(
      channelCount: channelCount,
      frameCount: total,
      sampleRate: sampleRate,
    );
    if (total == 0) return output;

    final limiter = limiterEnabled
        ? Limiter(
            sampleRate: sampleRate,
            channelCount: channelCount,
            thresholdLinear: ceilingLinear,
          )
        : null;
    // Extra frames rendered so the limiter's delay line is flushed and the
    // result can be shifted back into alignment.
    final tail = limiter?.latencyFrames ?? 0;
    final block = AudioBuffer.silence(
      channelCount: channelCount,
      frameCount: blockFrames,
      sampleRate: sampleRate,
    );

    var produced = 0;
    var position = startFrame;
    while (produced < total + tail) {
      if (isCancelled?.call() ?? false) {
        throw const RenderCancelled();
      }
      for (final channel in block.channels) {
        channel.fillRange(0, channel.length, 0);
      }
      final frames = math.min(blockFrames, total + tail - produced);
      renderBlock(position, block, 0, frames);
      if (masterGain != 1.0) {
        for (final channel in block.channels) {
          for (var i = 0; i < frames; i++) {
            channel[i] *= masterGain;
          }
        }
      }
      limiter?.process(block.channels);

      for (var i = 0; i < frames; i++) {
        // Undo the limiter's look-ahead delay by writing each block back
        // `tail` frames earlier than it was produced.
        final destinationFrame = produced + i - tail;
        if (destinationFrame < 0 || destinationFrame >= total) continue;
        for (var ch = 0; ch < channelCount; ch++) {
          output.channels[ch][destinationFrame] = block.channels[ch][i];
        }
      }

      produced += frames;
      position += frames;
      onProgress?.call((produced / (total + tail)).clamp(0.0, 1.0));
      // Yield so a long export does not freeze the interface.
      await Future<void>.delayed(Duration.zero);
    }
    return output;
  }
}

/// Thrown when an export is cancelled part way through.
class RenderCancelled implements Exception {
  const RenderCancelled();

  @override
  String toString() => 'Rendering was cancelled.';
}
