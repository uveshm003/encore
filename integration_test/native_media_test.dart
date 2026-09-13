import 'dart:io';
import 'dart:math' as math;

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/io/audio_file_format.dart';
import 'package:encore/io/codec/codec_registry.dart';
import 'package:encore/io/codec/native_transcoder.dart';
import 'package:encore/io/codec/wav_codec.dart';
import 'package:encore/io/codec/wav_transcoder.dart';
import 'package:encore/library/media_library.dart';
import 'package:encore/storage/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Exercises the real platform codec on a real device.
///
/// The unit tests deliberately run against the built-in WAV backend so they do
/// not depend on what is installed; this suite is the counterpart that proves
/// the native path — AVFoundation via the `encore_media` plugin — actually
/// decodes and encodes compressed audio (IMP-01, IMP-02, MIX-02).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late AppPaths paths;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('encore-native-');
    paths = AppPaths(root);
    await paths.ensureDirectories();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// A 3-second stereo tone: 440 Hz left, 660 Hz right.
  Future<String> writeSourceWav(String path, {int sampleRate = 44100}) async {
    final frames = sampleRate * 3;
    final buffer = AudioBuffer.silence(
      channelCount: 2,
      frameCount: frames,
      sampleRate: sampleRate,
    );
    for (var i = 0; i < frames; i++) {
      buffer.channels[0][i] =
          math.sin(2 * math.pi * 440 * i / sampleRate) * 0.5;
      buffer.channels[1][i] =
          math.sin(2 * math.pi * 660 * i / sampleRate) * 0.5;
    }
    await WavCodec.write(path, buffer, depth: WavBitDepth.pcm16);
    return path;
  }

  testWidgets('the platform codec is available', (tester) async {
    final native = NativeTranscoder();

    expect(await native.isAvailable(), isTrue);
    final decodable = await native.decodableFormats();
    expect(decodable, contains(AudioFileFormat.mp3));
    expect(decodable, contains(AudioFileFormat.m4a));
    expect(decodable, contains(AudioFileFormat.wav));
  });

  testWidgets('probe reports a file without decoding it', (tester) async {
    final source = await writeSourceWav('${root.path}/probe.wav');
    final native = NativeTranscoder();

    final info = await native.probe(source);

    expect(info.sampleRate, 44100);
    expect(info.channelCount, 2);
    expect(info.duration.inMilliseconds, closeTo(3000, 50));
  });

  testWidgets('round-trips through AAC and comes back as usable audio',
      (tester) async {
    final source = await writeSourceWav('${root.path}/source.wav');
    final compressed = '${root.path}/encoded.m4a';
    final decoded = '${root.path}/decoded.wav';
    final native = NativeTranscoder();

    // Encode to AAC (MIX-02 without needing FFmpeg)...
    await native.encodeFromWav(
      source: source,
      destination: compressed,
      format: AudioFileFormat.m4a,
      bitRate: 192000,
    );
    expect(await File(compressed).exists(), isTrue);
    expect(await File(compressed).length(), greaterThan(1000));
    // ...and it should be markedly smaller than the WAV it came from.
    expect(
      await File(compressed).length(),
      lessThan(await File(source).length()),
    );

    // ...then decode it back at the engine's rate and channel count.
    final info = await native.decodeToWav(
      source: compressed,
      destination: decoded,
      sampleRate: 48000,
      channelCount: 2,
    );

    expect(info.sampleRate, 48000);
    expect(info.channelCount, 2);
    final audio = await WavCodec.read(decoded);
    expect(audio.sampleRate, 48000);
    expect(audio.channelCount, 2);
    // AAC adds priming silence, so check the body rather than frame zero.
    expect(audio.frameCount, greaterThan(48000 * 2));
    expect(audio.slice(24000, 48000).rms(), greaterThan(0.1));
  });

  testWidgets('a missing file is reported, not thrown raw', (tester) async {
    final native = NativeTranscoder();

    await expectLater(
      native.probe('${root.path}/does-not-exist.m4a'),
      throwsA(anything),
    );
  });

  testWidgets('the registry imports a compressed file end to end',
      (tester) async {
    // Make an .m4a to import, using the platform encoder.
    final source = await writeSourceWav('${root.path}/song-source.wav');
    final song = '${root.path}/song.m4a';
    await NativeTranscoder().encodeFromWav(
      source: source,
      destination: song,
      format: AudioFileFormat.m4a,
      bitRate: 192000,
    );

    final codecs = CodecRegistry([NativeTranscoder(), const WavTranscoder()]);
    await codecs.initialise();
    final library = MediaLibrary(paths: paths, codecs: codecs);
    await library.load();

    final item = await library.import(song);

    expect(item.title, 'song');
    expect(item.sourceFormat, AudioFileFormat.m4a);
    expect(item.sourceSampleRate, 44100);
    // The working copy is normalised to the engine's format...
    expect(item.sampleRate, 48000);
    expect(item.channelCount, 2);
    expect(item.wasConverted, isTrue);
    // ...and the decode and its envelope are both on disk.
    expect(await File(library.audioPathFor(item)).exists(), isTrue);
    final peaks = await library.loadPeaks(item);
    expect(peaks.bucketCount, greaterThan(0));
    expect(peaks.maximums.any((value) => value > 0.1), isTrue);
  });

  testWidgets('an unreadable file fails with a message, not a crash',
      (tester) async {
    final rubbish = '${root.path}/broken.mp3';
    await File(rubbish).writeAsBytes(List.filled(4096, 0x42));

    final codecs = CodecRegistry([NativeTranscoder(), const WavTranscoder()]);
    await codecs.initialise();
    final library = MediaLibrary(paths: paths, codecs: codecs);
    await library.load();

    await expectLater(library.import(rubbish), throwsA(anything));
    // Nothing half-written is left behind for the next launch to trip over.
    expect(library.items, isEmpty);
  });
}
