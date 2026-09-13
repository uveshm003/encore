import '../../core/audio_buffer.dart';
import '../../core/dsp/resampler.dart';
import '../audio_file_format.dart';
import 'codec_exception.dart';
import 'transcoder.dart';
import 'wav_codec.dart';

/// The always-available backend: pure Dart, WAV in and WAV out.
///
/// It is the lowest priority because native backends handle far more formats,
/// but it guarantees the import → export path is never completely broken, on
/// any platform, with no external dependency.
class WavTranscoder implements Transcoder {
  const WavTranscoder({this.resampler = const Resampler()});

  final Resampler resampler;

  @override
  String get name => 'Built-in WAV';

  @override
  int get priority => 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<Set<AudioFileFormat>> decodableFormats() async =>
      const {AudioFileFormat.wav};

  @override
  Future<Set<AudioFileFormat>> encodableFormats() async =>
      const {AudioFileFormat.wav};

  @override
  Future<AudioFileInfo> probe(String path) async {
    final info = await WavCodec.readInfo(path);
    return audioFileInfo(
      path: path,
      sampleRate: info.sampleRate,
      channelCount: info.channelCount,
      frameCount: info.frameCount,
      format: AudioFileFormat.wav,
    );
  }

  @override
  Future<AudioFileInfo> decodeToWav({
    required String source,
    required String destination,
    int? sampleRate,
    int? channelCount,
  }) async {
    var buffer = await WavCodec.read(source);
    buffer = _normalise(buffer, sampleRate, channelCount);
    await WavCodec.write(destination, buffer, depth: WavBitDepth.float32);
    return audioFileInfo(
      path: destination,
      sampleRate: buffer.sampleRate,
      channelCount: buffer.channelCount,
      frameCount: buffer.frameCount,
      format: AudioFileFormat.wav,
    );
  }

  @override
  Future<void> encodeFromWav({
    required String source,
    required String destination,
    required AudioFileFormat format,
    required int bitRate,
    int? sampleRate,
  }) async {
    if (format != AudioFileFormat.wav) {
      throw CodecException(
        CodecErrorKind.unsupportedFormat,
        'The built-in encoder only writes WAV files.',
        path: destination,
      );
    }
    var buffer = await WavCodec.read(source);
    buffer = _normalise(buffer, sampleRate, null);
    // bitRate is meaningless for uncompressed audio; the app maps its export
    // quality onto a bit depth instead.
    final depth = bitRate >= 24 ? WavBitDepth.pcm24 : WavBitDepth.pcm16;
    await WavCodec.write(destination, buffer, depth: depth);
  }

  AudioBuffer _normalise(AudioBuffer buffer, int? sampleRate, int? channelCount) {
    var result = buffer;
    if (channelCount != null && channelCount != result.channelCount) {
      result = result.withChannelCount(channelCount);
    }
    if (sampleRate != null && sampleRate != result.sampleRate) {
      result = resampler.resample(result, sampleRate);
    }
    return result;
  }
}
