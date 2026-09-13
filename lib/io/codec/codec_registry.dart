import 'dart:io' show Platform;
import '../audio_file_format.dart';
import 'codec_exception.dart';
import 'ffmpeg_transcoder.dart';
import 'native_transcoder.dart';
import 'transcoder.dart';
import 'wav_transcoder.dart';

/// Chooses a [Transcoder] for each job and reports what the host can do.
///
/// Backends are discovered once at start-up and ranked by priority. Nothing
/// else in the app knows which backend ran; it asks for "decode this file" and
/// gets WAV back, or a [CodecException] with a message worth showing (IMP-04).
class CodecRegistry {
  CodecRegistry(List<Transcoder> backends)
    : _backends = List<Transcoder>.unmodifiable(
        backends.toList()..sort((a, b) => b.priority.compareTo(a.priority)),
      );

  /// The stack the app ships with: the platform's own framework first, an
  /// installed FFmpeg second, the built-in WAV reader as the floor.
  factory CodecRegistry.defaults() => CodecRegistry([
    NativeTranscoder(),
    FfmpegTranscoder(),
    const WavTranscoder(),
  ]);

  final List<Transcoder> _backends;

  final List<Transcoder> _available = [];
  final Map<Transcoder, Set<AudioFileFormat>> _decodable = {};
  final Map<Transcoder, Set<AudioFileFormat>> _encodable = {};
  bool _initialised = false;

  /// Probes every backend. Safe to call more than once.
  Future<void> initialise() async {
    if (_initialised) return;
    for (final backend in _backends) {
      bool available;
      try {
        available = await backend.isAvailable();
      } on Object {
        // A backend that throws while probing is simply treated as absent;
        // one broken codec must not stop the app from starting.
        available = false;
      }
      if (!available) continue;
      _available.add(backend);
      _decodable[backend] = await backend.decodableFormats();
      _encodable[backend] = await backend.encodableFormats();
    }
    _initialised = true;
  }

  /// Backends that are usable right now, highest priority first.
  List<Transcoder> get availableBackends => List.unmodifiable(_available);

  /// Every format that can be imported on this host.
  Set<AudioFileFormat> get decodableFormats =>
      _decodable.values.expand((formats) => formats).toSet();

  /// Every format that can be exported on this host.
  Set<AudioFileFormat> get encodableFormats =>
      _encodable.values.expand((formats) => formats).toSet();

  bool canDecode(AudioFileFormat format) => decodableFormats.contains(format);

  bool canEncode(AudioFileFormat format) => encodableFormats.contains(format);

  /// Extensions to hand the file picker: what this host can actually open.
  ///
  /// Deliberately not `AudioFileFormat.importableExtensions`, which is the
  /// full list from the requirement regardless of the device. Offering `.ogg`
  /// on a Mac with no FFmpeg lets someone choose a file that cannot possibly
  /// import, and they only find out afterwards — so the picker is built from
  /// capability, and Settings explains what is missing (IMP-01, IMP-05).
  ///
  /// Sorted and de-duplicated. Empty only if no backend is available at all,
  /// which callers must treat as "do not filter" rather than "allow nothing".
  List<String> get decodableExtensions {
    final extensions = <String>{};
    for (final format in decodableFormats) {
      extensions.addAll(format.extensions);
    }
    final sorted = extensions.toList()..sort();
    return sorted;
  }

  /// Import formats this host can open, in display order.
  List<AudioFileFormat> get supportedImportFormats {
    final supported = AudioFileFormat.importable
        .where(decodableFormats.contains)
        .toList();
    supported.sort((a, b) => a.displayName.compareTo(b.displayName));
    return supported;
  }

  /// Formats listed in the requirements that this host cannot open, so the UI
  /// can explain the gap rather than failing at the moment of import.
  Set<AudioFileFormat> get unsupportedImportFormats =>
      AudioFileFormat.importable.toSet().difference(decodableFormats);

  /// Whether telling the user to install FFmpeg is advice they can act on.
  ///
  /// [FfmpegTranscoder] finds a binary on the host's `PATH`, which is a
  /// desktop notion. On Android and iOS there is nowhere to put one, so the
  /// gap is simply a gap and saying "install FFmpeg" would be worse than
  /// saying nothing.
  static bool get canInstallFfmpeg =>
      Platform.isMacOS || Platform.isLinux || Platform.isWindows;

  Future<AudioFileInfo> probe(String path) {
    return _withBackends(
      path: path,
      format: AudioFileFormat.fromPath(path),
      capability: _decodable,
      action: (backend) => backend.probe(path),
    );
  }

  Future<AudioFileInfo> decodeToWav({
    required String source,
    required String destination,
    int? sampleRate,
    int? channelCount,
  }) {
    return _withBackends(
      path: source,
      format: AudioFileFormat.fromPath(source),
      capability: _decodable,
      action: (backend) => backend.decodeToWav(
        source: source,
        destination: destination,
        sampleRate: sampleRate,
        channelCount: channelCount,
      ),
    );
  }

  Future<void> encodeFromWav({
    required String source,
    required String destination,
    required AudioFileFormat format,
    required int bitRate,
    int? sampleRate,
  }) {
    return _withBackends(
      path: destination,
      format: format,
      capability: _encodable,
      action: (backend) => backend.encodeFromWav(
        source: source,
        destination: destination,
        format: format,
        bitRate: bitRate,
        sampleRate: sampleRate,
      ),
    );
  }

  /// Runs [action] on the best backend for [format], falling back to the next
  /// one if it fails for a reason another backend might handle.
  Future<T> _withBackends<T>({
    required String path,
    required AudioFileFormat format,
    required Map<Transcoder, Set<AudioFileFormat>> capability,
    required Future<T> Function(Transcoder backend) action,
  }) async {
    await initialise();
    final candidates = _available
        .where((backend) => capability[backend]?.contains(format) ?? false)
        .toList();
    if (candidates.isEmpty) {
      throw CodecException(
        format == AudioFileFormat.unknown
            ? CodecErrorKind.unsupportedFormat
            : CodecErrorKind.noBackend,
        format == AudioFileFormat.unknown
            ? 'This file type is not recognised as audio.'
            : '${format.displayName} files are not supported on this device.',
        path: path,
      );
    }

    CodecException? lastError;
    for (final backend in candidates) {
      try {
        return await action(backend);
      } on CodecException catch (error) {
        // A missing or cancelled file will fail identically everywhere, so
        // stop rather than retrying the same failure on each backend.
        if (error.kind == CodecErrorKind.notFound ||
            error.kind == CodecErrorKind.cancelled) {
          rethrow;
        }
        lastError = error;
      }
    }
    throw lastError ??
        CodecException(
          CodecErrorKind.unknown,
          'This file could not be processed.',
          path: path,
        );
  }
}
