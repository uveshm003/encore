import 'dart:io' show Platform;

/// Container/codec combinations the app knows about (IMP-01).
enum AudioFileFormat {
  wav('WAV', ['wav', 'wave']),
  aiff('AIFF', ['aif', 'aiff', 'aifc']),
  caf('CAF', ['caf']),
  mp3('MP3', ['mp3']),
  aac('AAC', ['aac', 'adts']),
  m4a('M4A / AAC', ['m4a', 'mp4', 'm4b']),
  flac('FLAC', ['flac']),
  ogg('Ogg Vorbis', ['ogg', 'oga']),
  opus('Opus', ['opus']),
  wma('WMA', ['wma']),

  // Beyond the requirement's list, but decoded by the platform frameworks for
  // free — AVFoundation reads AU and AMR, MediaCodec reads AMR, Matroska and
  // 3GP. Leaving them out of the enum silently dropped them: the extension
  // mapped to `unknown`, so the picker never offered a file the device could
  // in fact open. They are deliberately not in [importable], which tracks
  // coverage of IMP-01 and should not grow extras.
  amr('AMR', ['amr']),
  au('AU', ['au', 'snd']),
  matroska('Matroska', ['mkv']),
  threeGp('3GP', ['3gp']),

  unknown('Unknown', []);

  const AudioFileFormat(this.displayName, this.extensions);

  final String displayName;

  /// Lower-case extensions without the leading dot.
  final List<String> extensions;

  /// The formats IMP-01 asks for, used to measure what a device is missing.
  ///
  /// Not what the picker offers — that comes from
  /// `CodecRegistry.decodableExtensions`, which is what this host can really
  /// open and may be both narrower (no Ogg on Apple without FFmpeg) and wider
  /// (the platform extras above).
  static List<AudioFileFormat> get importable => const [
    AudioFileFormat.mp3,
    AudioFileFormat.wav,
    AudioFileFormat.flac,
    AudioFileFormat.aac,
    AudioFileFormat.m4a,
    AudioFileFormat.ogg,
    AudioFileFormat.opus,
    AudioFileFormat.wma,
    AudioFileFormat.aiff,
    AudioFileFormat.caf,
  ];

  /// Extensions to hand a file picker, de-duplicated and sorted.
  static List<String> get importableExtensions {
    final extensions = <String>{};
    for (final format in importable) {
      extensions.addAll(format.extensions);
    }
    final sorted = extensions.toList()..sort();
    return sorted;
  }

  /// Resolves a format from a file path, falling back to [unknown].
  static AudioFileFormat fromPath(String path) {
    final extension = extensionOf(path);
    if (extension.isEmpty) return AudioFileFormat.unknown;
    for (final format in AudioFileFormat.values) {
      if (format.extensions.contains(extension)) return format;
    }
    return AudioFileFormat.unknown;
  }

  static AudioFileFormat fromExtension(String extension) {
    final normalised = extension.toLowerCase().replaceFirst('.', '');
    for (final format in AudioFileFormat.values) {
      if (format.extensions.contains(normalised)) return format;
    }
    return AudioFileFormat.unknown;
  }

  /// The lower-case extension of [path] without the dot.
  static String extensionOf(String path) {
    final separator = Platform.isWindows ? '\\' : '/';
    final name = path.split(separator).last;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// The file name of [path] without its directory or extension.
  static String titleOf(String path) {
    final separator = Platform.isWindows ? '\\' : '/';
    final name = path.split(separator).last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }
}
