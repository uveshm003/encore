import 'package:encore/io/audio_file_format.dart';
import 'package:encore/io/codec/codec_exception.dart';
import 'package:encore/io/codec/codec_registry.dart';
import 'package:encore/io/codec/transcoder.dart';
import 'package:flutter_test/flutter_test.dart';

/// A backend that claims whatever the test says it claims.
class FakeTranscoder implements Transcoder {
  FakeTranscoder({
    required this.name,
    required this.priority,
    required this.decodable,
    this.encodable = const {},
    this.available = true,
  });

  @override
  final String name;

  @override
  final int priority;

  final Set<AudioFileFormat> decodable;
  final Set<AudioFileFormat> encodable;
  final bool available;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<Set<AudioFileFormat>> decodableFormats() async => decodable;

  @override
  Future<Set<AudioFileFormat>> encodableFormats() async => encodable;

  @override
  Future<AudioFileInfo> probe(String path) async => AudioFileInfo(
    path: path,
    format: AudioFileFormat.fromPath(path),
    sampleRate: 48000,
    channelCount: 2,
    frameCount: 0,
    duration: Duration.zero,
  );

  @override
  Future<AudioFileInfo> decodeToWav({
    required String source,
    required String destination,
    int? sampleRate,
    int? channelCount,
  }) => probe(source);

  @override
  Future<void> encodeFromWav({
    required String source,
    required String destination,
    required AudioFileFormat format,
    required int bitRate,
    int? sampleRate,
  }) async {}
}

/// What an Apple machine with no FFmpeg reports.
Set<AudioFileFormat> get applePlatformFormats => {
  AudioFileFormat.wav,
  AudioFileFormat.mp3,
  AudioFileFormat.m4a,
  AudioFileFormat.aac,
  AudioFileFormat.aiff,
  AudioFileFormat.caf,
  AudioFileFormat.flac,
};

void main() {
  Future<CodecRegistry> registryWith(List<Transcoder> backends) async {
    final registry = CodecRegistry(backends);
    await registry.initialise();
    return registry;
  }

  group('what the picker is offered', () {
    test('only extensions the host can actually decode', () async {
      final registry = await registryWith([
        FakeTranscoder(
          name: 'platform',
          priority: 100,
          decodable: applePlatformFormats,
        ),
      ]);

      final extensions = registry.decodableExtensions;

      // The whole point: these are in the requirement's list and in
      // AudioFileFormat.importableExtensions, but this host cannot read them,
      // so the picker must not offer them.
      expect(extensions, isNot(contains('ogg')));
      expect(extensions, isNot(contains('opus')));
      expect(extensions, isNot(contains('wma')));

      expect(extensions, containsAll(['mp3', 'wav', 'flac', 'm4a', 'aiff']));
      expect(
        AudioFileFormat.importableExtensions,
        containsAll(['ogg', 'opus', 'wma']),
        reason: 'the static list still describes the requirement, not the host',
      );
    });

    test('installing FFmpeg widens it without any other change', () async {
      final registry = await registryWith([
        FakeTranscoder(
          name: 'platform',
          priority: 100,
          decodable: applePlatformFormats,
        ),
        FakeTranscoder(
          name: 'ffmpeg',
          priority: 50,
          decodable: AudioFileFormat.importable.toSet(),
        ),
      ]);

      expect(registry.decodableExtensions, containsAll(['ogg', 'opus', 'wma']));
      expect(registry.unsupportedImportFormats, isEmpty);
    });

    test('the list is sorted and free of duplicates', () async {
      final registry = await registryWith([
        FakeTranscoder(
          name: 'a',
          priority: 100,
          decodable: {AudioFileFormat.wav, AudioFileFormat.mp3},
        ),
        FakeTranscoder(
          name: 'b',
          priority: 50,
          decodable: {AudioFileFormat.wav, AudioFileFormat.flac},
        ),
      ]);

      final extensions = registry.decodableExtensions;
      expect(extensions, equals(extensions.toSet().toList()));
      expect(extensions, orderedEquals(List.of(extensions)..sort()));
    });

    test('no backend at all yields an empty list, not a crash', () async {
      // The UI reads this as "do not filter" rather than "allow nothing",
      // which is the difference between a working picker and an empty one.
      final registry = await registryWith([
        FakeTranscoder(
          name: 'broken',
          priority: 100,
          decodable: const {},
          available: false,
        ),
      ]);

      expect(registry.decodableExtensions, isEmpty);
      expect(registry.supportedImportFormats, isEmpty);
    });

    test('platform extras are offered even though IMP-01 omits them', () async {
      // AVFoundation and MediaCodec read these for free. Before they existed
      // in the enum the extension mapped to `unknown` and was dropped, so a
      // file the device could open was not offered.
      final registry = await registryWith([
        FakeTranscoder(
          name: 'platform',
          priority: 100,
          decodable: {
            ...applePlatformFormats,
            AudioFileFormat.amr,
            AudioFileFormat.au,
          },
        ),
      ]);

      expect(registry.decodableExtensions, containsAll(['amr', 'au', 'snd']));
      // …but they do not count towards requirement coverage either way.
      expect(
        registry.supportedImportFormats,
        isNot(contains(AudioFileFormat.amr)),
      );
    });
  });

  group('what the user is told', () {
    test('supported formats are named, not just extensions', () async {
      final registry = await registryWith([
        FakeTranscoder(
          name: 'platform',
          priority: 100,
          decodable: applePlatformFormats,
        ),
      ]);

      final names = registry.supportedImportFormats
          .map((format) => format.displayName)
          .toList();
      expect(names, contains('MP3'));
      expect(names, contains('FLAC'));
      expect(names, isNot(contains('WMA')));
      expect(names, orderedEquals(List.of(names)..sort()));
    });

    test(
      'the gap is exactly what the requirement asked for and is missing',
      () async {
        final registry = await registryWith([
          FakeTranscoder(
            name: 'platform',
            priority: 100,
            decodable: applePlatformFormats,
          ),
        ]);

        expect(registry.unsupportedImportFormats, {
          AudioFileFormat.ogg,
          AudioFileFormat.opus,
          AudioFileFormat.wma,
        });
      },
    );

    test('an unreadable format fails with a message naming it', () async {
      final registry = await registryWith([
        FakeTranscoder(
          name: 'platform',
          priority: 100,
          decodable: applePlatformFormats,
        ),
      ]);

      await expectLater(
        registry.decodeToWav(
          source: '/tmp/song.wma',
          destination: '/tmp/o.wav',
        ),
        throwsA(
          isA<CodecException>()
              .having((e) => e.kind, 'kind', CodecErrorKind.noBackend)
              .having((e) => e.message, 'message', contains('WMA')),
        ),
      );
    });

    test('a file that is not audio at all says so differently', () async {
      final registry = await registryWith([
        FakeTranscoder(
          name: 'platform',
          priority: 100,
          decodable: applePlatformFormats,
        ),
      ]);

      await expectLater(
        registry.decodeToWav(
          source: '/tmp/notes.txt',
          destination: '/tmp/o.wav',
        ),
        throwsA(
          isA<CodecException>().having(
            (e) => e.kind,
            'kind',
            CodecErrorKind.unsupportedFormat,
          ),
        ),
      );
    });
  });

  group('AudioFileFormat', () {
    test('every extension maps back to exactly one format', () {
      final seen = <String, AudioFileFormat>{};
      for (final format in AudioFileFormat.values) {
        for (final extension in format.extensions) {
          expect(
            seen.containsKey(extension),
            isFalse,
            reason:
                '$extension is claimed by both ${seen[extension]} and '
                '$format, so the picker would be ambiguous',
          );
          seen[extension] = format;
          expect(AudioFileFormat.fromExtension(extension), format);
        }
      }
    });

    test('extensions are lower case and carry no dot', () {
      for (final format in AudioFileFormat.values) {
        for (final extension in format.extensions) {
          expect(extension, equals(extension.toLowerCase()));
          expect(extension, isNot(startsWith('.')));
        }
      }
    });

    test('a dotted or upper-case extension still resolves', () {
      expect(AudioFileFormat.fromExtension('.MP3'), AudioFileFormat.mp3);
      expect(
        AudioFileFormat.fromPath('/music/Song.FLAC'),
        AudioFileFormat.flac,
      );
      expect(
        AudioFileFormat.fromPath('/music/no-extension'),
        AudioFileFormat.unknown,
      );
    });
  });
}
