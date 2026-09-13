/// Fixed operating point for the audio engine.
///
/// Everything the mixer touches lives at this rate and channel count, so
/// timeline frames mean the same thing on every track and multi-track playback
/// stays sample-accurate by construction (PLAY-02). Imports are converted once,
/// at import time, rather than in the playback path.
class EngineConfig {
  const EngineConfig({
    this.sampleRate = defaultSampleRate,
    this.channelCount = defaultChannelCount,
    this.blockFrames = defaultBlockFrames,
    this.bufferedBlocks = defaultBufferedBlocks,
  });

  /// 48 kHz: what every current output device runs at natively, so nothing has
  /// to be resampled on the way out.
  static const int defaultSampleRate = 48000;
  static const int defaultChannelCount = 2;

  /// Frames rendered per mix call. 1024 at 48 kHz is ~21 ms — small enough to
  /// keep the transport responsive, large enough that per-block overhead is
  /// negligible.
  static const int defaultBlockFrames = 1024;

  /// How many blocks are kept queued at the output. Two gives ~43 ms of
  /// cushion against a scheduling hiccup without adding noticeable lag to
  /// transport changes (NFR-PERF-04).
  static const int defaultBufferedBlocks = 2;

  final int sampleRate;
  final int channelCount;
  final int blockFrames;
  final int bufferedBlocks;

  /// Latency the output buffering itself contributes, in frames.
  int get outputBufferFrames => blockFrames * bufferedBlocks;

  Duration get blockDuration =>
      Duration(microseconds: (blockFrames * 1000000 / sampleRate).round());

  EngineConfig copyWith({
    int? sampleRate,
    int? channelCount,
    int? blockFrames,
    int? bufferedBlocks,
  }) {
    return EngineConfig(
      sampleRate: sampleRate ?? this.sampleRate,
      channelCount: channelCount ?? this.channelCount,
      blockFrames: blockFrames ?? this.blockFrames,
      bufferedBlocks: bufferedBlocks ?? this.bufferedBlocks,
    );
  }
}
