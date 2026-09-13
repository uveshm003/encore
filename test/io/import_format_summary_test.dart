import 'package:encore/io/audio_file_format.dart';
import 'package:encore/io/import_format_summary.dart';
import 'package:flutter_test/flutter_test.dart';

ImportFormatSummary summary({
  List<AudioFileFormat> supported = const [],
  List<AudioFileFormat> missing = const [],
  bool ffmpegInstallable = true,
}) => ImportFormatSummary(
  supported: supported,
  missing: missing,
  ffmpegInstallable: ffmpegInstallable,
);

void main() {
  group('what the user is told they can open', () {
    test('one format reads naturally', () {
      expect(
        summary(supported: const [AudioFileFormat.mp3]).supportedSentence,
        'Opens MP3 files.',
      );
    });

    test('two formats are joined with "and", not a comma', () {
      expect(
        summary(
          supported: const [AudioFileFormat.mp3, AudioFileFormat.wav],
        ).supportedSentence,
        'Opens MP3 and WAV files.',
      );
    });

    test('three or more get commas and a final "and"', () {
      expect(
        summary(
          supported: const [
            AudioFileFormat.mp3,
            AudioFileFormat.wav,
            AudioFileFormat.flac,
          ],
        ).supportedSentence,
        'Opens MP3, WAV and FLAC files.',
      );
    });

    test('a device with no codecs says so rather than "Opens  files."', () {
      expect(
        summary().supportedSentence,
        'No audio formats are available on this device.',
      );
    });
  });

  group('what the user is told is missing', () {
    test('nothing missing means nothing said', () {
      expect(
        summary(supported: const [AudioFileFormat.mp3]).missingSentence,
        isNull,
      );
    });

    test('on desktop it suggests the fix', () {
      expect(
        summary(
          supported: const [AudioFileFormat.mp3],
          missing: const [AudioFileFormat.ogg, AudioFileFormat.wma],
        ).missingSentence,
        'Installing FFmpeg adds Ogg Vorbis and WMA.',
      );
    });

    test('on mobile it does not suggest something impossible', () {
      // There is nowhere to install an FFmpeg binary on a phone, so telling
      // someone to do it is worse than saying nothing.
      final sentence = summary(
        supported: const [AudioFileFormat.mp3],
        missing: const [AudioFileFormat.wma],
        ffmpegInstallable: false,
      ).missingSentence;

      expect(sentence, 'This device cannot open WMA.');
      expect(sentence, isNot(contains('FFmpeg')));
    });
  });

  group('the combined sentence', () {
    test('joins both halves when something is missing', () {
      expect(
        summary(
          supported: const [AudioFileFormat.mp3, AudioFileFormat.wav],
          missing: const [AudioFileFormat.wma],
        ).fullSentence,
        'Opens MP3 and WAV files. Installing FFmpeg adds WMA.',
      );
    });

    test('is just the supported half when nothing is missing', () {
      expect(
        summary(supported: const [AudioFileFormat.mp3]).fullSentence,
        'Opens MP3 files.',
      );
    });

    test('never trails a stray space', () {
      for (final ffmpeg in [true, false]) {
        final text = summary(
          supported: const [AudioFileFormat.mp3],
          ffmpegInstallable: ffmpeg,
        ).fullSentence;
        expect(text, equals(text.trim()));
        expect(text, isNot(contains('  ')));
      }
    });
  });
}
