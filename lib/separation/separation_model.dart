import 'inference_backend.dart';
import 'spectral_separator.dart';
import 'stem_kind.dart';

/// How a model does the work.
enum SeparationEngine {
  /// Signal processing only: no model file, works on first launch, runs
  /// anywhere (SEP-07).
  spectral,

  /// A neural separator executed by an on-device inference runtime (SEP-02).
  neural,
}

/// Speed/quality trade-off offered to the user (SEP-06).
enum SeparationTier {
  fast('Fast'),
  balanced('Balanced'),
  detailed('Best quality');

  const SeparationTier(this.displayName);

  final String displayName;
}

/// A separation method the app can offer.
class SeparationModel {
  const SeparationModel({
    required this.id,
    required this.name,
    required this.summary,
    required this.engine,
    required this.tier,
    required this.supportedStems,
    this.spectralOptions,
    this.assetFileName,
    this.downloadBytes,
    this.licence,
    this.sourceUrl,
    this.spec,
    this.outputOrder = const [],
  });

  final String id;
  final String name;

  /// One line describing the trade-off, shown next to the choice.
  final String summary;
  final SeparationEngine engine;
  final SeparationTier tier;
  final Set<StemKind> supportedStems;

  /// Tuning for [SeparationEngine.spectral] models.
  final SpectralSeparationOptions? spectralOptions;

  /// File name of the weights inside the models directory, for neural models.
  final String? assetFileName;
  final int? downloadBytes;

  /// Licence the weights are distributed under — recorded here because it has
  /// to be cleared before shipping (NFR-LEG-01).
  final String? licence;
  final String? sourceUrl;

  /// Rate, window and overlap the model expects. Neural models only.
  final NeuralModelSpec? spec;

  /// Which stem each of the model's outputs is, in the order it emits them.
  ///
  /// An ONNX graph does not name its outputs in any standard way, so the
  /// mapping is recorded here alongside the weights it describes.
  final List<StemKind> outputOrder;

  /// Neural models need their weights present before they can run.
  bool get requiresInstall => engine == SeparationEngine.neural;

  bool supports(Set<StemKind> stems) => supportedStems.containsAll(stems);
}

/// The models the app knows about.
///
/// The three spectral tiers are always present and always usable — they are
/// what makes the app work offline the moment it is installed (NFR-OFF-03).
/// The neural entries describe models the app is designed to host once an
/// inference runtime and licence-cleared weights are bundled.
class SeparationCatalog {
  const SeparationCatalog._();

  static const SeparationModel spectralFast = SeparationModel(
    id: 'spectral-fast',
    name: 'Quick separation',
    summary: 'Fastest. Good for checking an idea or for low-powered devices.',
    engine: SeparationEngine.spectral,
    tier: SeparationTier.fast,
    supportedStems: {StemKind.vocals, StemKind.instrumental},
    spectralOptions: SpectralSeparationOptions.fast,
  );

  static const SeparationModel spectralBalanced = SeparationModel(
    id: 'spectral-balanced',
    name: 'Standard separation',
    summary: 'Panning and harmonic analysis. The default for most songs.',
    engine: SeparationEngine.spectral,
    tier: SeparationTier.balanced,
    supportedStems: {
      StemKind.vocals,
      StemKind.instrumental,
      StemKind.drums,
      StemKind.bass,
      StemKind.other,
    },
    spectralOptions: SpectralSeparationOptions.balanced,
  );

  static const SeparationModel spectralDetailed = SeparationModel(
    id: 'spectral-detailed',
    name: 'High detail separation',
    summary: 'Finer analysis, noticeably slower. Best for dense mixes.',
    engine: SeparationEngine.spectral,
    tier: SeparationTier.detailed,
    supportedStems: {
      StemKind.vocals,
      StemKind.instrumental,
      StemKind.drums,
      StemKind.bass,
      StemKind.other,
    },
    spectralOptions: SpectralSeparationOptions.detailed,
  );

  static const SeparationModel htdemucsFineTuned = SeparationModel(
    id: 'htdemucs-ft',
    name: 'HT-Demucs (fine-tuned)',
    summary: 'Neural four-stem separation. Needs the model to be installed.',
    engine: SeparationEngine.neural,
    tier: SeparationTier.detailed,
    supportedStems: {
      StemKind.vocals,
      StemKind.instrumental,
      StemKind.drums,
      StemKind.bass,
      StemKind.other,
    },
    assetFileName: 'htdemucs_ft.onnx',
    downloadBytes: 340 * 1024 * 1024,
    licence: 'Code MIT; weights trained on MUSDB18 (academic use) — '
        'user-installed, never distributed with Encore. See docs/licences.md.',
    sourceUrl: 'https://github.com/facebookresearch/demucs',
    // Demucs is a 44.1 kHz model and emits its stems in this order.
    spec: NeuralModelSpec(
      sampleRate: 44100,
      windowFrames: 44100 * 10,
      overlapFrames: 44100 ~/ 4,
    ),
    outputOrder: [
      StemKind.drums,
      StemKind.bass,
      StemKind.other,
      StemKind.vocals,
    ],
  );

  static const SeparationModel roformerVocals = SeparationModel(
    id: 'roformer-vocals',
    name: 'RoFormer vocals',
    summary: 'Neural two-stem separation, tuned for lead vocals.',
    engine: SeparationEngine.neural,
    tier: SeparationTier.balanced,
    supportedStems: {StemKind.vocals, StemKind.instrumental},
    assetFileName: 'roformer_vocals.onnx',
    downloadBytes: 160 * 1024 * 1024,
    licence: 'Provenance varies by checkpoint — user-installed, never '
        'distributed with Encore. See docs/licences.md.',
    spec: NeuralModelSpec(
      sampleRate: 44100,
      windowFrames: 44100 * 8,
      overlapFrames: 44100 ~/ 4,
    ),
    outputOrder: [StemKind.vocals],
  );

  static const List<SeparationModel> all = [
    spectralBalanced,
    spectralFast,
    spectralDetailed,
    htdemucsFineTuned,
    roformerVocals,
  ];

  /// The model used when the user has not chosen one.
  static const SeparationModel defaultModel = spectralBalanced;

  static SeparationModel? byId(String id) {
    for (final model in all) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// Models that can run without installing anything.
  static List<SeparationModel> get builtIn =>
      all.where((model) => !model.requiresInstall).toList();
}
