/// The components a track can be separated into (SEP-01, SEP-05).
enum StemKind {
  vocals('Vocals'),
  instrumental('Instrumental'),
  drums('Drums'),
  bass('Bass'),
  other('Other');

  const StemKind(this.displayName);

  final String displayName;

  /// The two-way split that the core workflow needs (SEP-01).
  static const Set<StemKind> twoStem = {
    StemKind.vocals,
    StemKind.instrumental,
  };

  /// The full split (SEP-05). Note that `instrumental` is not in this set: it
  /// is the sum of drums, bass and other, and is produced on demand.
  static const Set<StemKind> fourStem = {
    StemKind.vocals,
    StemKind.drums,
    StemKind.bass,
    StemKind.other,
  };

  /// File name used inside the stem cache.
  String get fileName => '$name.wav';
}
