import 'app_paths.dart';

/// What a storage check concluded (NFR-RES-02).
enum StorageVerdict {
  /// Either there is room, or the platform would not say how much there is.
  /// Both mean the same thing to a caller: go ahead.
  proceed,

  /// It will probably fit, but not with any margin left over.
  tight,

  /// It will not fit.
  insufficient,
}

/// The answer to "should this job start?", with the numbers behind it.
class StorageCheck {
  const StorageCheck({
    required this.verdict,
    required this.requiredBytes,
    this.freeBytes,
  });

  final StorageVerdict verdict;

  /// What the job is estimated to write.
  final int requiredBytes;

  /// What the volume says is available, or null when it would not say.
  final int? freeBytes;

  bool get shouldWarn => verdict != StorageVerdict.proceed;
  bool get isBlocking => verdict == StorageVerdict.insufficient;
}

/// Estimates what a job will write, and asks whether the disk can take it.
///
/// The point is to say so *before* a four-minute separation runs for two
/// minutes and dies, which is the difference between NFR-RES-02 being met and
/// merely being survivable. It is deliberately an estimate: the exact size of
/// an encoded export is not knowable in advance, so the numbers below round
/// against us.
///
/// One rule governs every path through this class: **unknown free space means
/// proceed**. `AppPaths.freeSpaceBytes` returns null whenever the platform will
/// not answer, and refusing to work because a query failed would be a far worse
/// bug than running out of disk.
class StorageGuard {
  const StorageGuard(this.paths);

  final AppPaths paths;

  /// Kept free on top of the job itself, so finishing does not leave the
  /// user's device wedged. Deliberately modest: this is a working margin, not
  /// a healthy-disk policy.
  static const int headroomBytes = 256 * 1024 * 1024;

  /// Internal audio is planar float32 — four bytes per sample per channel.
  static const int _bytesPerSample = 4;

  /// Bytes one WAV of this shape occupies, header ignored as noise at this
  /// scale.
  static int wavBytes({
    required int frameCount,
    required int channelCount,
    int bytesPerSample = _bytesPerSample,
  }) => frameCount * channelCount * bytesPerSample;

  /// What separating a track into [stemCount] stems will write.
  ///
  /// Each stem is a full-length float32 WAV beside the source, and the
  /// separator works in overlapping segments that land in the temp directory
  /// before being moved into the cache — so at the peak, roughly one extra
  /// stem's worth is in flight.
  static int separationEstimate({
    required int frameCount,
    required int channelCount,
    required int stemCount,
  }) {
    final perStem = wavBytes(
      frameCount: frameCount,
      channelCount: channelCount,
    );
    return perStem * (stemCount + 1);
  }

  /// What exporting will write.
  ///
  /// [bytesPerSample] is the output format's, not the engine's: a 16-bit WAV
  /// writes half of what float32 does. Compressed formats are rendered to a
  /// float WAV first and then encoded, so the intermediate dominates and is
  /// what this counts.
  static int exportEstimate({
    required int frameCount,
    required int channelCount,
    int bytesPerSample = _bytesPerSample,
    bool viaIntermediate = false,
  }) {
    final output = wavBytes(
      frameCount: frameCount,
      channelCount: channelCount,
      bytesPerSample: bytesPerSample,
    );
    if (!viaIntermediate) return output;
    return output +
        wavBytes(frameCount: frameCount, channelCount: channelCount);
  }

  /// Compares an estimate against the app's own volume.
  Future<StorageCheck> check(int requiredBytes) async {
    final free = await paths.freeSpaceBytes();
    return StorageGuard.verdictFor(
      requiredBytes: requiredBytes,
      freeBytes: free,
    );
  }

  /// Compares an estimate against the volume holding [path].
  ///
  /// Exports land wherever the user chose, which need not be the disk the
  /// library is on.
  Future<StorageCheck> checkAt(String path, int requiredBytes) async {
    final free = await paths.freeSpaceBytesAt(path);
    return StorageGuard.verdictFor(
      requiredBytes: requiredBytes,
      freeBytes: free,
    );
  }

  /// The decision, separated from the I/O so it can be tested directly.
  static StorageCheck verdictFor({
    required int requiredBytes,
    required int? freeBytes,
  }) {
    if (freeBytes == null) {
      // The platform would not say. Never block on that.
      return StorageCheck(
        verdict: StorageVerdict.proceed,
        requiredBytes: requiredBytes,
      );
    }
    if (freeBytes < requiredBytes) {
      return StorageCheck(
        verdict: StorageVerdict.insufficient,
        requiredBytes: requiredBytes,
        freeBytes: freeBytes,
      );
    }
    if (freeBytes < requiredBytes + headroomBytes) {
      return StorageCheck(
        verdict: StorageVerdict.tight,
        requiredBytes: requiredBytes,
        freeBytes: freeBytes,
      );
    }
    return StorageCheck(
      verdict: StorageVerdict.proceed,
      requiredBytes: requiredBytes,
      freeBytes: freeBytes,
    );
  }
}
