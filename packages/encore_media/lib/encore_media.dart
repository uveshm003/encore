import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the host platform can read and write.
class MediaCapabilities {
  const MediaCapabilities({
    required this.decodableExtensions,
    required this.encodableExtensions,
  });

  static const MediaCapabilities none = MediaCapabilities(
    decodableExtensions: <String>{},
    encodableExtensions: <String>{},
  );

  /// Lower-case file extensions, without the leading dot.
  final Set<String> decodableExtensions;
  final Set<String> encodableExtensions;

  bool get isAvailable => decodableExtensions.isNotEmpty;
}

/// Sample rate, channel count and length of a media file.
class MediaInfo {
  const MediaInfo({
    required this.sampleRate,
    required this.channelCount,
    required this.frameCount,
    required this.duration,
  });

  final int sampleRate;
  final int channelCount;
  final int frameCount;
  final Duration duration;
}

/// Raised for any failure inside the native media layer.
///
/// [code] mirrors the platform error code so callers can distinguish "the file
/// vanished" from "this format is not supported" without parsing messages.
class MediaException implements Exception {
  const MediaException(this.code, this.message, {this.details});

  final String code;
  final String message;
  final String? details;

  bool get isUnsupportedFormat => code == 'unsupported' || code == 'decode_failed';

  @override
  String toString() => 'MediaException($code): $message';
}

/// Decode/encode bridge onto the platform's native audio framework.
///
/// On Apple platforms this is AVFoundation, which covers wav, aiff, caf, mp3,
/// aac/m4a and flac; on Android it is MediaCodec, which adds ogg and opus.
/// Formats the platform cannot read are handled by a different backend in the
/// app layer — see `CodecRegistry`.
///
/// [decodeToWav]'s [sampleRate] and [channelCount] are a request, not a
/// guarantee: AVFoundation converts as it decodes, while MediaCodec does not
/// resample at all. Callers must check the returned [MediaInfo] and convert
/// themselves if it differs — `NativeTranscoder` does exactly that.
class EncoreMedia {
  EncoreMedia({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.encore/media');

  final MethodChannel _channel;

  MediaCapabilities? _cachedCapabilities;

  /// True on platforms where the native plugin is compiled in.
  static bool get isSupportedPlatform =>
      Platform.isMacOS || Platform.isIOS || Platform.isAndroid;

  /// Which formats this platform can handle. Cached after the first call, and
  /// degrades to [MediaCapabilities.none] rather than throwing so the app can
  /// fall back to another backend.
  Future<MediaCapabilities> capabilities() async {
    final cached = _cachedCapabilities;
    if (cached != null) return cached;
    if (!isSupportedPlatform) {
      return _cachedCapabilities = MediaCapabilities.none;
    }
    try {
      final response =
          await _channel.invokeMapMethod<String, Object?>('capabilities');
      if (response == null) return _cachedCapabilities = MediaCapabilities.none;
      return _cachedCapabilities = MediaCapabilities(
        decodableExtensions: _extensions(response['decodableExtensions']),
        encodableExtensions: _extensions(response['encodableExtensions']),
      );
    } on PlatformException {
      return _cachedCapabilities = MediaCapabilities.none;
    } on MissingPluginException {
      return _cachedCapabilities = MediaCapabilities.none;
    }
  }

  /// Reads sample rate, channels and duration without decoding the audio.
  Future<MediaInfo> probe(String path) async {
    final response = await _invoke('probe', {'path': path});
    return _mediaInfoFrom(response);
  }

  /// Decodes [source] into a canonical 32-bit float WAV at [destination].
  ///
  /// Passing [sampleRate] or [channelCount] resamples/remixes during the
  /// decode, which is how imports are normalised to the engine's rate in one
  /// pass instead of two.
  Future<MediaInfo> decodeToWav({
    required String source,
    required String destination,
    int? sampleRate,
    int? channelCount,
  }) async {
    final response = await _invoke('decodeToWav', {
      'source': source,
      'destination': destination,
      if (sampleRate != null) 'sampleRate': sampleRate.toDouble(),
      'channels': ?channelCount,
    });
    return _mediaInfoFrom(response);
  }

  /// Encodes a float WAV at [source] into AAC in an .m4a container.
  Future<MediaInfo> encodeFromWav({
    required String source,
    required String destination,
    int bitRate = 256000,
    int? sampleRate,
  }) async {
    final response = await _invoke('encodeFromWav', {
      'source': source,
      'destination': destination,
      'bitRate': bitRate,
      if (sampleRate != null) 'sampleRate': sampleRate.toDouble(),
    });
    return _mediaInfoFrom(response);
  }

  /// Bytes available on the volume holding [path], or null when the platform
  /// will not say.
  ///
  /// Storage sits on the media channel because it has the same constraint the
  /// codecs do: it has to answer from inside the macOS app sandbox, where
  /// shelling out to `df` is not something to rely on. Null is a normal answer
  /// — callers must treat "unknown" as "carry on", never as "no space".
  Future<int?> freeSpaceBytes(String path) async {
    if (!isSupportedPlatform) return null;
    try {
      final bytes = await _channel.invokeMethod<Object?>('freeSpace', {
        'path': path,
      });
      final value = (bytes as num?)?.toInt();
      return value != null && value >= 0 ? value : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<Map<String, Object?>> _invoke(
    String method,
    Map<String, Object?> arguments,
  ) async {
    if (!isSupportedPlatform) {
      throw const MediaException(
        'unavailable',
        'Native media decoding is not available on this platform.',
      );
    }
    try {
      final response =
          await _channel.invokeMapMethod<String, Object?>(method, arguments);
      if (response == null) {
        throw MediaException('empty_response', '$method returned no data.');
      }
      return response;
    } on PlatformException catch (error) {
      throw MediaException(
        error.code,
        error.message ?? 'The audio file could not be read.',
        details: error.details?.toString(),
      );
    } on MissingPluginException {
      throw const MediaException(
        'unavailable',
        'Native media decoding is not available on this platform.',
      );
    }
  }

  static MediaInfo _mediaInfoFrom(Map<String, Object?> response) {
    final sampleRate = (response['sampleRate'] as num?)?.round() ?? 0;
    final frameCount = (response['frameCount'] as num?)?.round() ?? 0;
    return MediaInfo(
      sampleRate: sampleRate,
      channelCount: (response['channelCount'] as num?)?.round() ?? 0,
      frameCount: frameCount,
      duration: Duration(
        milliseconds: (response['durationMs'] as num?)?.round() ?? 0,
      ),
    );
  }

  static Set<String> _extensions(Object? raw) {
    if (raw is! List) return const <String>{};
    return raw.map((e) => e.toString().toLowerCase()).toSet();
  }
}
