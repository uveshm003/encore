import 'dart:io';

import 'package:uuid/uuid.dart';

import '../core/audio_buffer.dart';
import '../core/waveform.dart';
import '../io/codec/wav_codec.dart';
import 'models/audio_asset.dart';
import 'project_repository.dart';

/// Loads and writes the audio a project references.
///
/// Decoded audio is held in memory while a project is open, because the mixing
/// graph reads directly from it on every block; keeping it here means each
/// asset is decoded once no matter how many clips point at it. Envelopes are
/// cached beside the audio so re-opening a project draws immediately.
class AssetStore {
  AssetStore({required this.repository, Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final ProjectRepository repository;
  final Uuid _uuid;

  final Map<String, AudioBuffer> _buffers = {};
  final Map<String, WaveformPeaks> _peaks = {};

  /// Assets currently resident, keyed by asset id.
  Map<String, AudioBuffer> get buffers => Map.unmodifiable(_buffers);

  bool isLoaded(String assetId) => _buffers.containsKey(assetId);

  AudioBuffer? bufferFor(String assetId) => _buffers[assetId];

  WaveformPeaks? peaksFor(String assetId) => _peaks[assetId];

  /// Reads an asset into memory, or returns the copy already there.
  Future<AudioBuffer> load(AudioAsset asset) async {
    final existing = _buffers[asset.id];
    if (existing != null) return existing;
    final buffer = await WavCodec.read(asset.path);
    _buffers[asset.id] = buffer;
    return buffer;
  }

  /// Loads every asset, reporting how far along it is.
  ///
  /// Assets whose files have gone missing are skipped rather than aborting the
  /// load, so a project with one broken reference still opens.
  Future<List<AudioAsset>> loadAll(
    List<AudioAsset> assets, {
    void Function(double progress)? onProgress,
  }) async {
    final missing = <AudioAsset>[];
    for (var i = 0; i < assets.length; i++) {
      try {
        await load(assets[i]);
      } on Object {
        missing.add(assets[i]);
      }
      onProgress?.call((i + 1) / assets.length);
    }
    return missing;
  }

  /// The envelope for an asset, read from the sidecar cache or computed and
  /// then cached.
  Future<WaveformPeaks> peaks(AudioAsset asset) async {
    final existing = _peaks[asset.id];
    if (existing != null) return existing;

    final sidecar = File('${asset.path}.peaks');
    if (await sidecar.exists()) {
      final decoded = WaveformPeaks.decode(await sidecar.readAsBytes());
      if (decoded != null) return _peaks[asset.id] = decoded;
    }

    final buffer = await load(asset);
    final computed = WaveformPeaks.fromBuffer(buffer);
    _peaks[asset.id] = computed;
    try {
      await sidecar.writeAsBytes(computed.encode(), flush: true);
    } on FileSystemException {
      // The cache is an optimisation; failing to write it is not an error.
    }
    return computed;
  }

  /// Writes a recorded take into the project folder and registers it.
  Future<AudioAsset> writeRecording({
    required String projectId,
    required AudioBuffer audio,
    required String label,
    AssetOrigin origin = AssetOrigin.recorded,
  }) async {
    final id = _uuid.v4();
    final path = repository.assetPathFor(projectId, id);
    await WavCodec.write(path, audio, depth: WavBitDepth.float32);

    final asset = AudioAsset(
      id: id,
      path: path,
      origin: origin,
      sampleRate: audio.sampleRate,
      channelCount: audio.channelCount,
      frameCount: audio.frameCount,
      label: label,
    );
    _buffers[id] = audio;
    final peaks = WaveformPeaks.fromBuffer(audio);
    _peaks[id] = peaks;
    try {
      await File('$path.peaks').writeAsBytes(peaks.encode(), flush: true);
    } on FileSystemException {
      // As above: the envelope will simply be recomputed next time.
    }
    return asset;
  }

  /// Registers an existing WAV file — a library decode or a cached stem —
  /// without copying it.
  Future<AudioAsset> reference({
    required String path,
    required AssetOrigin origin,
    String? label,
  }) async {
    final info = await WavCodec.readInfo(path);
    return AudioAsset(
      id: _uuid.v4(),
      path: path,
      origin: origin,
      sampleRate: info.sampleRate,
      channelCount: info.channelCount,
      frameCount: info.frameCount,
      label: label,
    );
  }

  /// A fresh identifier, so callers that build tracks and clips do not each
  /// need their own generator.
  String newAssetId() => _uuid.v4();

  /// Drops an asset from memory. The file is untouched.
  void evict(String assetId) {
    _buffers.remove(assetId);
    _peaks.remove(assetId);
  }

  /// Frees everything, called when a project is closed.
  void clear() {
    _buffers.clear();
    _peaks.clear();
  }

  /// Approximate memory held by loaded audio, for the storage screen
  /// (NFR-RES-02).
  int get residentBytes {
    var total = 0;
    for (final buffer in _buffers.values) {
      total += buffer.frameCount * buffer.channelCount * 4;
    }
    return total;
  }
}
