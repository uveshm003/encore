import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../engine/latency.dart';
import '../io/audio_file_format.dart';
import '../io/export_service.dart';
import '../separation/separation_model.dart';
import '../storage/app_paths.dart';

/// User preferences, kept in a JSON file next to the projects.
///
/// Deliberately local and unremarkable: there is no account, no sync and no
/// telemetry, so there is nowhere else for this to live (NFR-OFF-02,
/// NFR-LEG-03).
class AppSettings extends ChangeNotifier {
  AppSettings({required this.paths});

  final AppPaths paths;

  LatencySettings _latency = const LatencySettings();
  String _separationModelId = SeparationCatalog.defaultModel.id;
  bool _fourStemSeparation = false;
  ExportSettings _export = const ExportSettings();
  String? _inputDeviceId;
  bool _monitorInput = false;
  bool _hasSeenOnboarding = false;

  LatencySettings get latency => _latency;

  /// The separation model to use when the user has not picked one (SEP-06).
  SeparationModel get separationModel =>
      SeparationCatalog.byId(_separationModelId) ??
      SeparationCatalog.defaultModel;

  /// Whether to produce four stems rather than two (SEP-05).
  bool get fourStemSeparation => _fourStemSeparation;

  ExportSettings get exportSettings => _export;

  /// Capture device, or null for the system default (REC-06).
  String? get inputDeviceId => _inputDeviceId;

  /// Whether input is folded into the monitor mix (REC-02).
  bool get monitorInput => _monitorInput;

  bool get hasSeenOnboarding => _hasSeenOnboarding;

  File get _file => File('${paths.root.path}/settings.json');

  Future<void> load() async {
    final file = _file;
    if (!await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      _latency = LatencySettings.fromJson(
        (json['latency'] as Map<String, Object?>?) ?? const {},
      );
      _separationModelId =
          json['separationModelId'] as String? ?? _separationModelId;
      _fourStemSeparation = json['fourStemSeparation'] as bool? ?? false;
      _inputDeviceId = json['inputDeviceId'] as String?;
      _monitorInput = json['monitorInput'] as bool? ?? false;
      _hasSeenOnboarding = json['hasSeenOnboarding'] as bool? ?? false;
      final export = json['export'] as Map<String, Object?>?;
      if (export != null) {
        _export = ExportSettings(
          format: AudioFileFormat.values.firstWhere(
            (value) => value.name == export['format'],
            orElse: () => AudioFileFormat.wav,
          ),
          sampleRate: (export['sampleRate'] as num?)?.toInt() ?? 48000,
          bitRate: (export['bitRate'] as num?)?.toInt() ?? 256000,
          bitDepth: ExportBitDepth.values.firstWhere(
            (value) => value.name == export['bitDepth'],
            orElse: () => ExportBitDepth.pcm16,
          ),
        );
      }
      notifyListeners();
    } on Object {
      // Corrupt settings fall back to defaults rather than blocking start-up.
    }
  }

  Future<void> setLatency(LatencySettings value) async {
    _latency = value;
    await _save();
  }

  Future<void> setSeparationModel(SeparationModel model) async {
    _separationModelId = model.id;
    await _save();
  }

  Future<void> setFourStemSeparation(bool value) async {
    _fourStemSeparation = value;
    await _save();
  }

  Future<void> setExportSettings(ExportSettings value) async {
    _export = value;
    await _save();
  }

  Future<void> setInputDeviceId(String? value) async {
    _inputDeviceId = value;
    await _save();
  }

  Future<void> setMonitorInput(bool value) async {
    _monitorInput = value;
    await _save();
  }

  Future<void> markOnboardingSeen() async {
    if (_hasSeenOnboarding) return;
    _hasSeenOnboarding = true;
    await _save();
  }

  Future<void> _save() async {
    notifyListeners();
    try {
      await paths.root.create(recursive: true);
      await _file.writeAsString(
        jsonEncode({
          'latency': _latency.toJson(),
          'separationModelId': _separationModelId,
          'fourStemSeparation': _fourStemSeparation,
          'inputDeviceId': _inputDeviceId,
          'monitorInput': _monitorInput,
          'hasSeenOnboarding': _hasSeenOnboarding,
          'export': {
            'format': _export.format.name,
            'sampleRate': _export.sampleRate,
            'bitRate': _export.bitRate,
            'bitDepth': _export.bitDepth.name,
          },
        }),
        flush: true,
      );
    } on FileSystemException {
      // Settings are a convenience; a failed write should not interrupt work.
    }
  }
}
