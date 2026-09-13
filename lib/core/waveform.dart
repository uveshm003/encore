import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_buffer.dart';

/// Pre-computed min/max envelope used to draw waveforms (UI-01).
///
/// Drawing straight from PCM would mean touching millions of samples on every
/// frame, so the envelope is reduced once — at import, or when a recording
/// finishes — and cached next to the audio. Zooming in and out then only ever
/// reduces this much smaller array.
class WaveformPeaks {
  WaveformPeaks({
    required this.framesPerBucket,
    required this.sampleRate,
    required this.frameCount,
    required this.minimums,
    required this.maximums,
  }) : assert(minimums.length == maximums.length,
            'peak arrays must be the same length');

  /// A reasonable default: ~5 ms per bucket at 48 kHz, which is finer than any
  /// screen can show while staying small enough to cache.
  static const int defaultFramesPerBucket = 256;

  static final WaveformPeaks empty = WaveformPeaks(
    framesPerBucket: defaultFramesPerBucket,
    sampleRate: 48000,
    frameCount: 0,
    minimums: Float32List(0),
    maximums: Float32List(0),
  );

  final int framesPerBucket;
  final int sampleRate;
  final int frameCount;
  final Float32List minimums;
  final Float32List maximums;

  int get bucketCount => minimums.length;

  bool get isEmpty => bucketCount == 0;

  /// Reduces [buffer] to an envelope, summing channels to mono first so the
  /// drawn shape matches what is heard.
  static WaveformPeaks fromBuffer(
    AudioBuffer buffer, {
    int framesPerBucket = defaultFramesPerBucket,
  }) {
    final buckets = framesPerBucket <= 0
        ? 0
        : (buffer.frameCount / framesPerBucket).ceil();
    final minimums = Float32List(buckets);
    final maximums = Float32List(buckets);
    final scale = 1.0 / buffer.channelCount;

    for (var bucket = 0; bucket < buckets; bucket++) {
      final start = bucket * framesPerBucket;
      final end = math.min(start + framesPerBucket, buffer.frameCount);
      var lowest = 0.0;
      var highest = 0.0;
      var initialised = false;
      for (var frame = start; frame < end; frame++) {
        var mixed = 0.0;
        for (var ch = 0; ch < buffer.channelCount; ch++) {
          mixed += buffer.channels[ch][frame];
        }
        mixed *= scale;
        // A NaN or infinity in the audio — from a damaged file or a bad
        // decode — would otherwise reach the painter as a coordinate, and a
        // non-finite coordinate takes the whole frame down rather than
        // drawing a wrong waveform.
        if (!mixed.isFinite) mixed = 0.0;
        if (!initialised) {
          lowest = highest = mixed;
          initialised = true;
        } else {
          if (mixed < lowest) lowest = mixed;
          if (mixed > highest) highest = mixed;
        }
      }
      minimums[bucket] = lowest;
      maximums[bucket] = highest;
    }

    return WaveformPeaks(
      framesPerBucket: framesPerBucket,
      sampleRate: buffer.sampleRate,
      frameCount: buffer.frameCount,
      minimums: minimums,
      maximums: maximums,
    );
  }

  /// Reduces the envelope again to exactly [columns] pixels covering the frame
  /// range `[startFrame, endFrame)` — the shape a painter actually draws.
  ///
  /// When zoomed in past one bucket per column the same bucket is repeated,
  /// which is correct: there is no more detail stored to show.
  WaveformEnvelope envelopeFor({
    required int columns,
    required int startFrame,
    required int endFrame,
  }) {
    final lows = Float32List(math.max(columns, 0));
    final highs = Float32List(math.max(columns, 0));
    if (columns <= 0 || isEmpty || endFrame <= startFrame) {
      return WaveformEnvelope(lows, highs);
    }
    final framesPerColumn = (endFrame - startFrame) / columns;
    for (var column = 0; column < columns; column++) {
      final columnStart = startFrame + framesPerColumn * column;
      final columnEnd = columnStart + framesPerColumn;
      var firstBucket = (columnStart / framesPerBucket).floor();
      var lastBucket = (columnEnd / framesPerBucket).ceil();
      firstBucket = firstBucket.clamp(0, bucketCount - 1);
      lastBucket = lastBucket.clamp(firstBucket + 1, bucketCount);

      var lowest = 0.0;
      var highest = 0.0;
      for (var bucket = firstBucket; bucket < lastBucket; bucket++) {
        if (minimums[bucket] < lowest) lowest = minimums[bucket];
        if (maximums[bucket] > highest) highest = maximums[bucket];
      }
      lows[column] = lowest;
      highs[column] = highest;
    }
    return WaveformEnvelope(lows, highs);
  }

  /// Compact binary form: a small header followed by the two float arrays.
  Uint8List encode() {
    final header = ByteData(20);
    header.setUint32(0, _magic, Endian.little);
    header.setUint32(4, framesPerBucket, Endian.little);
    header.setUint32(8, sampleRate, Endian.little);
    header.setUint32(12, frameCount, Endian.little);
    header.setUint32(16, bucketCount, Endian.little);

    final bytes = Uint8List(20 + bucketCount * 8);
    bytes.setRange(0, 20, header.buffer.asUint8List());
    bytes.setRange(
      20,
      20 + bucketCount * 4,
      minimums.buffer.asUint8List(
        minimums.offsetInBytes,
        bucketCount * 4,
      ),
    );
    bytes.setRange(
      20 + bucketCount * 4,
      20 + bucketCount * 8,
      maximums.buffer.asUint8List(
        maximums.offsetInBytes,
        bucketCount * 4,
      ),
    );
    return bytes;
  }

  /// Reads [encode]'s output, returning null if it is not a peaks file.
  static WaveformPeaks? decode(Uint8List bytes) {
    if (bytes.length < 20) return null;
    final header = ByteData.sublistView(bytes, 0, 20);
    if (header.getUint32(0, Endian.little) != _magic) return null;
    final buckets = header.getUint32(16, Endian.little);
    if (bytes.length < 20 + buckets * 8) return null;

    final minimums = Float32List(buckets);
    final maximums = Float32List(buckets);
    final view = ByteData.sublistView(bytes, 20);
    for (var i = 0; i < buckets; i++) {
      minimums[i] = view.getFloat32(i * 4, Endian.little);
      maximums[i] = view.getFloat32(buckets * 4 + i * 4, Endian.little);
    }
    return WaveformPeaks(
      framesPerBucket: header.getUint32(4, Endian.little),
      sampleRate: header.getUint32(8, Endian.little),
      frameCount: header.getUint32(12, Endian.little),
      minimums: minimums,
      maximums: maximums,
    );
  }

  static const int _magic = 0x45574650; // "EWFP"
}

/// One column-per-pixel min/max pair set, ready to paint.
class WaveformEnvelope {
  const WaveformEnvelope(this.lows, this.highs);

  final Float32List lows;
  final Float32List highs;

  int get length => lows.length;
}

/// Builds a [WaveformPeaks] incrementally from blocks of audio.
///
/// Lets the envelope be produced while a file is streamed off disk, so a long
/// import never needs the whole track resident at once.
class WaveformPeaksBuilder {
  WaveformPeaksBuilder({
    required this.sampleRate,
    this.framesPerBucket = WaveformPeaks.defaultFramesPerBucket,
  });

  final int sampleRate;
  final int framesPerBucket;

  final List<double> _minimums = [];
  final List<double> _maximums = [];

  int _frameCount = 0;
  int _framesInBucket = 0;
  double _bucketLow = 0.0;
  double _bucketHigh = 0.0;

  /// Feeds the next contiguous block. Blocks may be any length; bucket
  /// boundaries are carried across calls.
  void add(AudioBuffer block) {
    final scale = 1.0 / block.channelCount;
    for (var frame = 0; frame < block.frameCount; frame++) {
      var mixed = 0.0;
      for (var ch = 0; ch < block.channelCount; ch++) {
        mixed += block.channels[ch][frame];
      }
      mixed *= scale;
      if (_framesInBucket == 0) {
        _bucketLow = _bucketHigh = mixed;
      } else {
        if (mixed < _bucketLow) _bucketLow = mixed;
        if (mixed > _bucketHigh) _bucketHigh = mixed;
      }
      _framesInBucket++;
      if (_framesInBucket == framesPerBucket) _closeBucket();
    }
    _frameCount += block.frameCount;
  }

  /// Closes the trailing partial bucket and returns the finished envelope.
  WaveformPeaks build() {
    if (_framesInBucket > 0) _closeBucket();
    return WaveformPeaks(
      framesPerBucket: framesPerBucket,
      sampleRate: sampleRate,
      frameCount: _frameCount,
      minimums: Float32List.fromList(_minimums),
      maximums: Float32List.fromList(_maximums),
    );
  }

  void _closeBucket() {
    _minimums.add(_bucketLow);
    _maximums.add(_bucketHigh);
    _framesInBucket = 0;
    _bucketLow = 0.0;
    _bucketHigh = 0.0;
  }
}
