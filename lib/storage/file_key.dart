import 'dart:io';
import 'dart:typed_data';

/// A stable identifier for a file's *contents*.
///
/// The stem cache is keyed by this rather than by path, so re-importing the
/// same song from a different folder reuses the separation that already ran
/// (§8, SEP-03) while a genuinely different file always gets a fresh key.
///
/// Hashing a whole album's worth of audio would be slow, so this samples the
/// head, middle and tail of the file and mixes in the exact byte length. For
/// telling user media files apart that is more than enough; it is not a
/// security primitive and is not used as one.
class FileKey {
  const FileKey._();

  static const int _sampleBytes = 64 * 1024;

  /// Two independently seeded 64-bit FNV-1a passes, rendered as 32 hex
  /// characters. Dart's integers wrap at 64 bits on the platforms this app
  /// targets, which is the arithmetic FNV expects.
  static Future<String> forFile(String path) async {
    final file = File(path);
    final length = await file.length();
    final handle = await file.open();
    try {
      var first = _seedA;
      var second = _seedB;
      first = _mixLength(first, length);
      second = _mixLength(second, length);

      for (final offset in _sampleOffsets(length)) {
        await handle.setPosition(offset);
        final bytes = await handle.read(_sampleBytes);
        first = _mixBytes(first, bytes);
        second = _mixBytes(second, bytes, rotate: true);
      }
      return _hex(first) + _hex(second);
    } finally {
      await handle.close();
    }
  }

  /// The same hash over an in-memory byte range, for tests and for keying
  /// generated audio.
  static String forBytes(Uint8List bytes) {
    var first = _mixLength(_seedA, bytes.length);
    var second = _mixLength(_seedB, bytes.length);
    first = _mixBytes(first, bytes);
    second = _mixBytes(second, bytes, rotate: true);
    return _hex(first) + _hex(second);
  }

  static List<int> _sampleOffsets(int length) {
    if (length <= _sampleBytes * 3) return const [0];
    return [0, (length ~/ 2) - (_sampleBytes ~/ 2), length - _sampleBytes];
  }

  static const int _seedA = 0xcbf29ce484222325;
  static const int _seedB = 0x9e3779b97f4a7c15;
  static const int _prime = 0x100000001b3;

  static int _mixBytes(int seed, Uint8List bytes, {bool rotate = false}) {
    var hash = seed;
    for (final byte in bytes) {
      hash ^= byte;
      hash *= _prime;
      // The second pass rotates as well as multiplies so the two halves of the
      // key do not move in lockstep.
      if (rotate) hash = (hash << 7) | (hash >>> 57);
    }
    return hash;
  }

  static int _mixLength(int seed, int length) {
    var hash = seed;
    for (var shift = 0; shift < 64; shift += 8) {
      hash ^= (length >>> shift) & 0xFF;
      hash *= _prime;
    }
    return hash;
  }

  /// Renders a 64-bit value as 16 unsigned hex digits.
  ///
  /// Done in two 32-bit halves because `toRadixString` on a negative int
  /// yields a signed `-...` string, which is neither hex nor fixed width, and
  /// these keys become directory names.
  static String _hex(int value) {
    final high = (value >> 32) & 0xFFFFFFFF;
    final low = value & 0xFFFFFFFF;
    return high.toRadixString(16).padLeft(8, '0') +
        low.toRadixString(16).padLeft(8, '0');
  }
}
