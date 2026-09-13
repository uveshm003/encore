import 'package:encore_media/encore_media.dart';

import '../../core/audio_buffer.dart';
import '../../core/dsp/resampler.dart';
import '../audio_file_format.dart';
import 'codec_exception.dart';
import 'transcoder.dart';
import 'wav_codec.dart';

/// Backend built on the host's own audio framework via the `encore_media`
/// plugin (AVFoundation on macOS and iOS).
///
/// Preferred over everything else: it runs in-process, so it keeps working
/// inside the macOS app sandbox where launching a helper binary would not.
class NativeTranscoder implements Transcoder {
  NativeTranscoder({EncoreMedia? media, Resampler? resampler})
    : _media = media ?? EncoreMedia(),
      _resampler = resampler ?? const Resampler();

  final EncoreMedia _media;
  final Resampler _resampler;

  Set<AudioFileFormat>? _decodable;
  Set<AudioFileFormat>? _encodable;

  @override
  String get name => 'System audio framework';

  @override
  int get priority => 100;

  @override
  Future<bool> isAvailable() async {
    if (!EncoreMedia.isSupportedPlatform) return false;
    final capabilities = await _media.capabilities();
    return capabilities.isAvailable;
  }

  @override
  Future<Set<AudioFileFormat>> decodableFormats() async {
    return _decodable ??= _formatsFor(
      (await _media.capabilities()).decodableExtensions,
    );
  }

  @override
  Future<Set<AudioFileFormat>> encodableFormats() async {
    return _encodable ??= _formatsFor(
      (await _media.capabilities()).encodableExtensions,
    );
  }

  @override
  Future<AudioFileInfo> probe(String path) async {
    try {
      final info = await _media.probe(path);
      return audioFileInfo(
        path: path,
        sampleRate: info.sampleRate,
        channelCount: info.channelCount,
        frameCount: info.frameCount,
      );
    } on MediaException catch (error) {
      throw _translate(error, path);
    }
  }

  @override
  Future<AudioFileInfo> decodeToWav({
    required String source,
    required String destination,
    int? sampleRate,
    int? channelCount,
  }) async {
    try {
      final info = await _media.decodeToWav(
        source: source,
        destination: destination,
        sampleRate: sampleRate,
        channelCount: channelCount,
      );
      // Platforms that cannot convert while decoding hand back the source's
      // own format; finish the job here so every backend returns exactly what
      // was asked for.
      final needsRate = sampleRate != null && info.sampleRate != sampleRate;
      final needsChannels =
          channelCount != null && info.channelCount != channelCount;
      if (needsRate || needsChannels) {
        return _convertInPlace(
          destination,
          sampleRate: sampleRate,
          channelCount: channelCount,
        );
      }
      return audioFileInfo(
        path: destination,
        sampleRate: info.sampleRate,
        channelCount: info.channelCount,
        frameCount: info.frameCount,
        format: AudioFileFormat.wav,
      );
    } on MediaException catch (error) {
      throw _translate(error, source);
    }
  }

  @override
  Future<void> encodeFromWav({
    required String source,
    required String destination,
    required AudioFileFormat format,
    required int bitRate,
    int? sampleRate,
  }) async {
    if (format != AudioFileFormat.m4a && format != AudioFileFormat.aac) {
      throw CodecException(
        CodecErrorKind.unsupportedFormat,
        '${format.displayName} cannot be written by the system encoder.',
        path: destination,
      );
    }
    try {
      await _media.encodeFromWav(
        source: source,
        destination: destination,
        bitRate: bitRate,
        sampleRate: sampleRate,
      );
    } on MediaException catch (error) {
      throw _translate(error, destination);
    }
  }

  /// Rewrites a decoded WAV at the requested rate and channel count.
  Future<AudioFileInfo> _convertInPlace(
    String path, {
    int? sampleRate,
    int? channelCount,
  }) async {
    AudioBuffer buffer = await WavCodec.read(path);
    if (channelCount != null && channelCount != buffer.channelCount) {
      buffer = buffer.withChannelCount(channelCount);
    }
    if (sampleRate != null && sampleRate != buffer.sampleRate) {
      buffer = _resampler.resample(buffer, sampleRate);
    }
    await WavCodec.write(path, buffer, depth: WavBitDepth.float32);
    return audioFileInfo(
      path: path,
      sampleRate: buffer.sampleRate,
      channelCount: buffer.channelCount,
      frameCount: buffer.frameCount,
      format: AudioFileFormat.wav,
    );
  }

  static Set<AudioFileFormat> _formatsFor(Set<String> extensions) {
    final formats = <AudioFileFormat>{};
    for (final extension in extensions) {
      final format = AudioFileFormat.fromExtension(extension);
      if (format != AudioFileFormat.unknown) formats.add(format);
    }
    return formats;
  }

  static CodecException _translate(MediaException error, String path) {
    final kind = switch (error.code) {
      'not_found' => CodecErrorKind.notFound,
      'unsupported' => CodecErrorKind.unsupportedFormat,
      'unavailable' => CodecErrorKind.noBackend,
      'out_of_memory' => CodecErrorKind.resourceExhausted,
      'decode_failed' => CodecErrorKind.corrupt,
      _ => CodecErrorKind.unknown,
    };
    return CodecException(
      kind,
      error.message,
      path: path,
      details: error.details,
    );
  }
}
