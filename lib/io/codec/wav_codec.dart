import 'dart:io';
import 'dart:typed_data';

import '../../core/audio_buffer.dart';
import 'codec_exception.dart';

/// Sample formats this app writes.
enum WavBitDepth {
  /// 16-bit signed integer — the compatible choice for delivery.
  pcm16,

  /// 24-bit signed integer.
  pcm24,

  /// 32-bit float — lossless against our internal representation, used for
  /// the stem cache and for hand-off to the native encoder.
  float32,
}

/// Header fields of a RIFF/WAVE file.
class WavInfo {
  const WavInfo({
    required this.sampleRate,
    required this.channelCount,
    required this.frameCount,
    required this.bitsPerSample,
    required this.isFloat,
    required this.dataOffset,
    required this.dataLength,
  });

  final int sampleRate;
  final int channelCount;
  final int frameCount;
  final int bitsPerSample;
  final bool isFloat;
  final int dataOffset;
  final int dataLength;

  Duration get duration => framesToDuration(frameCount, sampleRate);

  int get bytesPerFrame => channelCount * (bitsPerSample ~/ 8);
}

/// Reads and writes RIFF/WAVE files without any native dependency.
///
/// WAV is the app's interchange format: the native decoder produces one, the
/// native encoder consumes one, and the stem cache is made of them. Because it
/// is implemented here in Dart, importing and exporting WAV keeps working on
/// every platform even when no other backend is available (IMP-01, MIX-02).
class WavCodec {
  const WavCodec._();

  static const int _headerScanLimit = 1 << 20;

  /// Parses the header only.
  static Future<WavInfo> readInfo(String path) async {
    final handle = await _open(path);
    try {
      return await _readInfo(handle, path);
    } finally {
      await handle.close();
    }
  }

  /// Decodes the whole file into an [AudioBuffer].
  ///
  /// The data chunk is streamed in blocks and de-interleaved straight into the
  /// destination so a long track is never held twice in memory.
  static Future<AudioBuffer> read(
    String path, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final handle = await _open(path);
    try {
      final info = await _readInfo(handle, path);
      final buffer = AudioBuffer.silence(
        channelCount: info.channelCount,
        frameCount: info.frameCount,
        sampleRate: info.sampleRate,
      );
      if (info.frameCount == 0) return buffer;

      final bytesPerSample = info.bitsPerSample ~/ 8;
      // Round the block size down to a whole number of frames so a frame is
      // never split across two reads.
      final framesPerBlock = (1 << 18) ~/ info.bytesPerFrame;
      await handle.setPosition(info.dataOffset);

      var frame = 0;
      while (frame < info.frameCount) {
        if (isCancelled?.call() ?? false) {
          throw const CodecException(
            CodecErrorKind.cancelled,
            'Reading was cancelled.',
          );
        }
        final frames = framesPerBlock < info.frameCount - frame
            ? framesPerBlock
            : info.frameCount - frame;
        final bytes = await handle.read(frames * info.bytesPerFrame);
        if (bytes.isEmpty) break;
        final availableFrames = bytes.length ~/ info.bytesPerFrame;
        final view = ByteData.sublistView(bytes);
        for (var i = 0; i < availableFrames; i++) {
          for (var ch = 0; ch < info.channelCount; ch++) {
            final offset = (i * info.channelCount + ch) * bytesPerSample;
            buffer.channels[ch][frame + i] =
                _readSample(view, offset, info.bitsPerSample, info.isFloat);
          }
        }
        frame += availableFrames;
        onProgress?.call(frame / info.frameCount);
        if (availableFrames < frames) break;
      }
      return buffer;
    } finally {
      await handle.close();
    }
  }

  /// Streams the file as a sequence of blocks.
  ///
  /// Used where the whole track is not needed at once — building a waveform
  /// envelope, metering, checksumming — so a long import does not have to hold
  /// a hundred megabytes of PCM in memory (NFR-RES-02).
  static Stream<AudioBuffer> readBlocks(
    String path, {
    int framesPerBlock = 1 << 16,
  }) async* {
    final handle = await _open(path);
    try {
      final info = await _readInfo(handle, path);
      if (info.frameCount == 0) return;
      final bytesPerSample = info.bitsPerSample ~/ 8;
      await handle.setPosition(info.dataOffset);

      var frame = 0;
      while (frame < info.frameCount) {
        final frames = framesPerBlock < info.frameCount - frame
            ? framesPerBlock
            : info.frameCount - frame;
        final bytes = await handle.read(frames * info.bytesPerFrame);
        if (bytes.isEmpty) return;
        final availableFrames = bytes.length ~/ info.bytesPerFrame;
        final block = AudioBuffer.silence(
          channelCount: info.channelCount,
          frameCount: availableFrames,
          sampleRate: info.sampleRate,
        );
        final view = ByteData.sublistView(bytes);
        for (var i = 0; i < availableFrames; i++) {
          for (var ch = 0; ch < info.channelCount; ch++) {
            final offset = (i * info.channelCount + ch) * bytesPerSample;
            block.channels[ch][i] =
                _readSample(view, offset, info.bitsPerSample, info.isFloat);
          }
        }
        yield block;
        frame += availableFrames;
        if (availableFrames < frames) return;
      }
    } finally {
      await handle.close();
    }
  }

  /// Writes [buffer] to [path], creating parent directories as needed.
  static Future<void> write(
    String path,
    AudioBuffer buffer, {
    WavBitDepth depth = WavBitDepth.float32,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    try {
      final bytesPerSample = switch (depth) {
        WavBitDepth.pcm16 => 2,
        WavBitDepth.pcm24 => 3,
        WavBitDepth.float32 => 4,
      };
      final dataLength =
          buffer.frameCount * buffer.channelCount * bytesPerSample;
      sink.add(
        _buildHeader(
          sampleRate: buffer.sampleRate,
          channelCount: buffer.channelCount,
          bytesPerSample: bytesPerSample,
          isFloat: depth == WavBitDepth.float32,
          dataLength: dataLength,
        ),
      );

      final framesPerBlock = 1 << 15;
      for (var start = 0; start < buffer.frameCount; start += framesPerBlock) {
        final frames = start + framesPerBlock < buffer.frameCount
            ? framesPerBlock
            : buffer.frameCount - start;
        final block = Uint8List(frames * buffer.channelCount * bytesPerSample);
        final view = ByteData.sublistView(block);
        var offset = 0;
        for (var i = 0; i < frames; i++) {
          for (var ch = 0; ch < buffer.channelCount; ch++) {
            final sample = buffer.channels[ch][start + i];
            switch (depth) {
              case WavBitDepth.pcm16:
                view.setInt16(offset, floatToInt16(sample), Endian.little);
              case WavBitDepth.pcm24:
                // Scaled by 2^23 to mirror the read path exactly; see
                // floatToInt16 for the same reasoning at 16 bits.
                final value = _clampInt(
                  (sample * 8388608.0).round(),
                  -8388608,
                  8388607,
                );
                final unsigned = value & 0xFFFFFF;
                block[offset] = unsigned & 0xFF;
                block[offset + 1] = (unsigned >> 8) & 0xFF;
                block[offset + 2] = (unsigned >> 16) & 0xFF;
              case WavBitDepth.float32:
                view.setFloat32(offset, sample, Endian.little);
            }
            offset += bytesPerSample;
          }
        }
        sink.add(block);
      }
    } finally {
      await sink.close();
    }
  }

  static Future<RandomAccessFile> _open(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw CodecException(
        CodecErrorKind.notFound,
        'The file could not be found.',
        path: path,
      );
    }
    return file.open();
  }

  static Future<WavInfo> _readInfo(RandomAccessFile handle, String path) async {
    final length = await handle.length();
    if (length < 44) {
      throw CodecException(
        CodecErrorKind.corrupt,
        'This file is too short to be a WAV file.',
        path: path,
      );
    }
    await handle.setPosition(0);
    final riff = await handle.read(12);
    if (_tag(riff, 0) != 'RIFF' || _tag(riff, 8) != 'WAVE') {
      throw CodecException(
        CodecErrorKind.unsupportedFormat,
        'This is not a WAV file.',
        path: path,
      );
    }

    int? sampleRate;
    int? channelCount;
    int? bitsPerSample;
    var isFloat = false;
    var position = 12;

    while (position + 8 <= length && position < _headerScanLimit) {
      await handle.setPosition(position);
      final header = await handle.read(8);
      if (header.length < 8) break;
      final headerView = ByteData.sublistView(header);
      final chunkId = _tag(header, 0);
      final chunkSize = headerView.getUint32(4, Endian.little);
      final body = position + 8;

      if (chunkId == 'fmt ') {
        await handle.setPosition(body);
        final fmt = await handle.read(chunkSize < 16 ? chunkSize : 40);
        if (fmt.length < 16) {
          throw CodecException(
            CodecErrorKind.corrupt,
            'The WAV format header is truncated.',
            path: path,
          );
        }
        final fmtView = ByteData.sublistView(fmt);
        var formatTag = fmtView.getUint16(0, Endian.little);
        channelCount = fmtView.getUint16(2, Endian.little);
        sampleRate = fmtView.getUint32(4, Endian.little);
        bitsPerSample = fmtView.getUint16(14, Endian.little);
        // WAVE_FORMAT_EXTENSIBLE hides the real format in a sub-format GUID
        // whose first two bytes are the classic format tag.
        if (formatTag == 0xFFFE && fmt.length >= 26) {
          formatTag = fmtView.getUint16(24, Endian.little);
        }
        if (formatTag == 3) {
          isFloat = true;
        } else if (formatTag != 1) {
          throw CodecException(
            CodecErrorKind.unsupportedFormat,
            'This WAV file uses a compressed encoding this app cannot read.',
            path: path,
          );
        }
      } else if (chunkId == 'data') {
        if (sampleRate == null || channelCount == null || bitsPerSample == null) {
          throw CodecException(
            CodecErrorKind.corrupt,
            'The WAV file is missing its format header.',
            path: path,
          );
        }
        if (channelCount < 1 || sampleRate < 1) {
          throw CodecException(
            CodecErrorKind.corrupt,
            'The WAV file declares an invalid sample rate or channel count.',
            path: path,
          );
        }
        const supportedDepths = {8, 16, 24, 32, 64};
        if (!supportedDepths.contains(bitsPerSample)) {
          throw CodecException(
            CodecErrorKind.unsupportedFormat,
            'This app cannot read $bitsPerSample-bit WAV files.',
            path: path,
          );
        }
        // Some encoders write 0xFFFFFFFF or an over-long size for streamed
        // files; trust the file length instead when the chunk overruns it.
        final available = length - body;
        final dataLength = chunkSize == 0 || chunkSize > available
            ? available
            : chunkSize;
        final bytesPerFrame = channelCount * (bitsPerSample ~/ 8);
        return WavInfo(
          sampleRate: sampleRate,
          channelCount: channelCount,
          frameCount: dataLength ~/ bytesPerFrame,
          bitsPerSample: bitsPerSample,
          isFloat: isFloat,
          dataOffset: body,
          dataLength: dataLength,
        );
      }
      // Chunks are word-aligned: an odd size is followed by a pad byte.
      position = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }

    throw CodecException(
      CodecErrorKind.corrupt,
      'The WAV file has no audio data.',
      path: path,
    );
  }

  static double _readSample(
    ByteData view,
    int offset,
    int bitsPerSample,
    bool isFloat,
  ) {
    if (isFloat) {
      return bitsPerSample == 64
          ? view.getFloat64(offset, Endian.little)
          : view.getFloat32(offset, Endian.little);
    }
    switch (bitsPerSample) {
      case 8:
        // 8-bit WAV is unsigned with a midpoint of 128.
        return (view.getUint8(offset) - 128) / 128.0;
      case 16:
        return view.getInt16(offset, Endian.little) / 32768.0;
      case 24:
        final low = view.getUint8(offset);
        final mid = view.getUint8(offset + 1);
        final high = view.getInt8(offset + 2);
        return ((high << 16) | (mid << 8) | low) / 8388608.0;
      case 32:
        return view.getInt32(offset, Endian.little) / 2147483648.0;
      default:
        return 0.0;
    }
  }

  static Uint8List _buildHeader({
    required int sampleRate,
    required int channelCount,
    required int bytesPerSample,
    required bool isFloat,
    required int dataLength,
  }) {
    final header = Uint8List(44);
    final view = ByteData.sublistView(header);
    final byteRate = sampleRate * channelCount * bytesPerSample;
    final blockAlign = channelCount * bytesPerSample;

    _writeTag(header, 0, 'RIFF');
    view.setUint32(4, 36 + dataLength, Endian.little);
    _writeTag(header, 8, 'WAVE');
    _writeTag(header, 12, 'fmt ');
    view.setUint32(16, 16, Endian.little);
    view.setUint16(20, isFloat ? 3 : 1, Endian.little);
    view.setUint16(22, channelCount, Endian.little);
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, byteRate, Endian.little);
    view.setUint16(32, blockAlign, Endian.little);
    view.setUint16(34, bytesPerSample * 8, Endian.little);
    _writeTag(header, 36, 'data');
    view.setUint32(40, dataLength, Endian.little);
    return header;
  }

  static String _tag(Uint8List bytes, int offset) {
    return String.fromCharCodes(bytes.sublist(offset, offset + 4));
  }

  static void _writeTag(Uint8List bytes, int offset, String tag) {
    for (var i = 0; i < 4; i++) {
      bytes[offset + i] = tag.codeUnitAt(i);
    }
  }

  static int _clampInt(int value, int low, int high) {
    if (value < low) return low;
    if (value > high) return high;
    return value;
  }
}
