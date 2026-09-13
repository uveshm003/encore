import 'audio_file_format.dart';
import 'codec/codec_registry.dart';

/// Turns "what can this device open?" into something to put on screen.
///
/// Kept out of the widgets so the wording can be tested without a widget tree,
/// and kept out of [CodecRegistry] so the registry stays about capability
/// rather than prose. Both sentences are derived from the backends at runtime,
/// so installing or removing FFmpeg changes them with no string to edit.
class ImportFormatSummary {
  const ImportFormatSummary({
    required this.supported,
    required this.missing,
    required this.ffmpegInstallable,
  });

  /// Reads the current state of [registry].
  factory ImportFormatSummary.of(CodecRegistry registry) {
    final missing =
        registry.unsupportedImportFormats
            .where((format) => format != AudioFileFormat.unknown)
            .toList()
          ..sort((a, b) => a.displayName.compareTo(b.displayName));
    return ImportFormatSummary(
      supported: registry.supportedImportFormats,
      missing: missing,
      ffmpegInstallable: CodecRegistry.canInstallFfmpeg,
    );
  }

  final List<AudioFileFormat> supported;
  final List<AudioFileFormat> missing;

  /// Whether "install FFmpeg" is advice the user could act on here. There is
  /// nowhere to put a binary on a phone, so on mobile the gap is just a gap.
  final bool ffmpegInstallable;

  /// What this device can open, e.g. "Opens MP3, WAV and FLAC files."
  String get supportedSentence {
    if (supported.isEmpty) {
      return 'No audio formats are available on this device.';
    }
    return 'Opens ${_list(supported)} files.';
  }

  /// What it cannot, and what would fix it — or null when nothing is missing.
  String? get missingSentence {
    if (missing.isEmpty) return null;
    final names = _list(missing);
    return ffmpegInstallable
        ? 'Installing FFmpeg adds $names.'
        : 'This device cannot open $names.';
  }

  /// Both sentences, for somewhere with room for them.
  String get fullSentence {
    final missingPart = missingSentence;
    return missingPart == null
        ? supportedSentence
        : '$supportedSentence $missingPart';
  }

  /// "A", "A and B", "A, B and C" — an Oxford-comma-free list, because these
  /// are read aloud by a screen reader as often as they are scanned.
  static String _list(List<AudioFileFormat> formats) {
    final names = formats.map((format) => format.displayName).toList();
    if (names.length == 1) return names.single;
    final last = names.removeLast();
    return '${names.join(', ')} and $last';
  }
}
