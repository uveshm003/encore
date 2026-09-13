import 'package:encore/storage/storage_guard.dart';
import 'package:flutter_test/flutter_test.dart';

const megabyte = 1024 * 1024;
const gigabyte = 1024 * megabyte;

void main() {
  group('estimates', () {
    // Four minutes of 48 kHz stereo float32 is a useful yardstick: it is a
    // normal song, and it is about 88 MiB per full-length stem.
    const frames = 4 * 60 * 48000;

    test('a float WAV is four bytes per sample per channel', () {
      expect(
        StorageGuard.wavBytes(frameCount: 48000, channelCount: 2),
        48000 * 2 * 4,
      );
    });

    test('two-stem separation counts both stems plus one in flight', () {
      final bytes = StorageGuard.separationEstimate(
        frameCount: frames,
        channelCount: 2,
        stemCount: 2,
      );
      // Three stems' worth: vocals, instrumental, and the segment scratch.
      expect(bytes, StorageGuard.wavBytes(frameCount: frames, channelCount: 2) * 3);
      expect(bytes ~/ megabyte, closeTo(263, 2));
    });

    test('four-stem separation costs more than two-stem', () {
      int estimate(int stems) => StorageGuard.separationEstimate(
            frameCount: frames,
            channelCount: 2,
            stemCount: stems,
          );
      expect(estimate(4), greaterThan(estimate(2)));
    });

    test('a 16-bit export is half the size of a float one', () {
      final small = StorageGuard.exportEstimate(
        frameCount: frames,
        channelCount: 2,
        bytesPerSample: 2,
      );
      final float = StorageGuard.exportEstimate(
        frameCount: frames,
        channelCount: 2,
        bytesPerSample: 4,
      );
      expect(float, small * 2);
    });

    test('a compressed export also counts its float intermediate', () {
      final direct = StorageGuard.exportEstimate(
        frameCount: frames,
        channelCount: 2,
        bytesPerSample: 2,
      );
      final viaWav = StorageGuard.exportEstimate(
        frameCount: frames,
        channelCount: 2,
        bytesPerSample: 2,
        viaIntermediate: true,
      );
      expect(
        viaWav,
        direct + StorageGuard.wavBytes(frameCount: frames, channelCount: 2),
      );
    });
  });

  group('verdict', () {
    test('unknown free space always proceeds', () {
      // The important case: a platform that will not answer must never block
      // the work, and must not claim to know how much room there is.
      final check = StorageGuard.verdictFor(
        requiredBytes: 500 * gigabyte,
        freeBytes: null,
      );
      expect(check.verdict, StorageVerdict.proceed);
      expect(check.shouldWarn, isFalse);
      expect(check.freeBytes, isNull);
    });

    test('plenty of room proceeds', () {
      final check = StorageGuard.verdictFor(
        requiredBytes: 300 * megabyte,
        freeBytes: 20 * gigabyte,
      );
      expect(check.verdict, StorageVerdict.proceed);
      expect(check.shouldWarn, isFalse);
    });

    test('fits, but only just, warns without blocking', () {
      final check = StorageGuard.verdictFor(
        requiredBytes: 300 * megabyte,
        freeBytes: 400 * megabyte,
      );
      expect(check.verdict, StorageVerdict.tight);
      expect(check.shouldWarn, isTrue);
      expect(check.isBlocking, isFalse);
    });

    test('does not fit, blocks', () {
      final check = StorageGuard.verdictFor(
        requiredBytes: 3 * gigabyte,
        freeBytes: 900 * megabyte,
      );
      expect(check.verdict, StorageVerdict.insufficient);
      expect(check.isBlocking, isTrue);
    });

    test('the boundary between tight and fine is the headroom', () {
      const required = 100 * megabyte;
      expect(
        StorageGuard.verdictFor(
          requiredBytes: required,
          freeBytes: required + StorageGuard.headroomBytes - 1,
        ).verdict,
        StorageVerdict.tight,
      );
      expect(
        StorageGuard.verdictFor(
          requiredBytes: required,
          freeBytes: required + StorageGuard.headroomBytes,
        ).verdict,
        StorageVerdict.proceed,
      );
    });

    test('exactly enough space is not insufficient', () {
      final check = StorageGuard.verdictFor(
        requiredBytes: 100 * megabyte,
        freeBytes: 100 * megabyte,
      );
      expect(check.isBlocking, isFalse);
      expect(check.verdict, StorageVerdict.tight);
    });
  });
}
