import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_services.dart';
import '../../engine/offline_renderer.dart';
import '../../io/audio_file_format.dart';
import '../../io/codec/codec_exception.dart';
import '../../io/export_service.dart';
import '../../project/models/project.dart';
import '../../storage/storage_guard.dart';
import '../theme.dart';
import '../widgets/primitives.dart';

/// Export the finished mix, or each track on its own (MIX-02, MIX-03).
class ExportSheet extends StatefulWidget {
  const ExportSheet({required this.project, super.key});

  final Project project;

  @override
  State<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<ExportSheet> {
  late ExportSettings _settings;
  bool _stems = false;
  bool _running = false;
  bool _cancelled = false;
  double _progress = 0;
  String? _failure;
  List<ExportResult> _results = const [];

  bool _initialised = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // As in SeparationScreen: the services scope is an inherited widget, so it
    // cannot be read until dependencies are available.
    if (_initialised) return;
    _initialised = true;
    final services = ServicesScope.of(context);
    _settings = services.settings.exportSettings;
    final available = services.exporter.availableFormats();
    if (available.isNotEmpty && !available.contains(_settings.format)) {
      _settings = _settings.copyWith(format: available.first);
    }
  }

  AppServices get _services => ServicesScope.of(context);

  /// Warns before an export that will not fit in [folder] (NFR-RES-02).
  ///
  /// The folder is checked rather than the app's own storage: the picker can
  /// point at an external disk, and that is the volume the bytes land on.
  Future<bool> _confirmStorage(String folder) async {
    final project = widget.project;
    // Exporting each track separately writes one file per track that has
    // audio, all of them project-length.
    final fileCount = _stems
        ? project.tracks.where((track) => track.clips.isNotEmpty).length
        : 1;
    if (fileCount == 0) return true;

    final required = StorageGuard.exportEstimate(
          frameCount: project.durationFrames,
          channelCount: 2,
          bytesPerSample: switch (_settings.bitDepth) {
            ExportBitDepth.pcm16 => 2,
            ExportBitDepth.pcm24 => 3,
            ExportBitDepth.float32 => 4,
          },
          // Compressed formats are rendered to a float WAV and then encoded,
          // so both exist on disk at once.
          viaIntermediate: _settings.isCompressed,
        ) *
        fileCount;

    final check = await StorageGuard(_services.paths).checkAt(folder, required);
    if (!check.shouldWarn || !mounted) return true;

    final free = check.freeBytes;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          check.isBlocking ? 'Not enough space' : 'Storage is nearly full',
        ),
        content: Text(
          check.isBlocking
              ? 'This export needs about ${formatBytes(check.requiredBytes)}, '
                    'and there '
                    '${free == null ? 'may not be' : 'is only ${formatBytes(free)}'} '
                    'free where you chose to save it. Pick another location or '
                    'clear some space.'
              : 'This export needs about ${formatBytes(check.requiredBytes)}, '
                    'which would use nearly all the space left there.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(check.isBlocking ? 'Close' : 'Cancel'),
          ),
          if (!check.isBlocking)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Export anyway'),
            ),
        ],
      ),
    );
    return proceed ?? false;
  }

  Future<void> _export() async {
    final exporter = _services.exporter;
    // A folder is asked for rather than a file name because the render is
    // streamed to disk: the save-file dialog wants the finished bytes up
    // front, which would mean holding the whole mix in memory first.
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: _stems
          ? 'Choose a folder for the tracks'
          : 'Choose where to save the mix',
    );
    if (folder == null) return;

    final destination = _stems
        ? folder
        : '$folder${Platform.pathSeparator}'
              '${_safeName(widget.project.name)}.${_settings.extension}';

    if (!await _confirmStorage(folder)) return;
    if (!mounted) return;

    setState(() {
      _running = true;
      _cancelled = false;
      _progress = 0;
      _failure = null;
      _results = const [];
    });
    await _services.settings.setExportSettings(_settings);

    try {
      final buffers = _services.assets.buffers;
      if (_stems) {
        final results = await exporter.exportStems(
          project: widget.project,
          buffers: buffers,
          settings: _settings,
          destinationDirectory: destination,
          onProgress: _onProgress,
          isCancelled: () => _cancelled,
        );
        if (mounted) setState(() => _results = results);
      } else {
        final result = await exporter.exportMix(
          project: widget.project,
          buffers: buffers,
          settings: _settings,
          destinationPath: destination,
          onProgress: _onProgress,
          isCancelled: () => _cancelled,
        );
        if (mounted) setState(() => _results = [result]);
      }
    } on RenderCancelled {
      if (mounted) setState(() => _failure = 'Export cancelled.');
    } on CodecException catch (error) {
      if (mounted) setState(() => _failure = error.message);
    } on Object catch (error) {
      if (mounted) setState(() => _failure = 'Export failed: $error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  static String _safeName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-').trim();
    return cleaned.isEmpty ? 'Untitled' : cleaned;
  }

  void _onProgress(double value) {
    if (mounted) setState(() => _progress = value.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formats = _services.exporter.availableFormats();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            Space.xxl,
            Space.md,
            Space.xxl,
            Space.xxl,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: Space.lg),
                      decoration: const BoxDecoration(
                        color: Palette.lineStrong,
                        borderRadius: Radii.allControl,
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Text('Export', style: theme.textTheme.titleLarge),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded, size: 19),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  if (_results.isNotEmpty)
                    _resultsView(theme)
                  else if (_running)
                    _progressView(theme)
                  else
                    ..._settingsView(theme, formats),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _settingsView(ThemeData theme, List<AudioFileFormat> formats) {
    final note = _missingFormatsNote(formats);
    return [
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(
            value: false,
            icon: Icon(Icons.audio_file_rounded, size: 16),
            label: Text('One mixed file'),
          ),
          ButtonSegment(
            value: true,
            icon: Icon(Icons.library_music_rounded, size: 16),
            label: Text('Each track'),
          ),
        ],
        selected: {_stems},
        showSelectedIcon: false,
        onSelectionChanged: (value) => setState(() => _stems = value.first),
      ),
      const SizedBox(height: Space.xl),
      _labelled(
        'Format',
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            for (final format in formats)
              ChoiceChip(
                label: Text(format.displayName),
                selected: _settings.format == format,
                onSelected: (_) => setState(
                  () => _settings = _settings.copyWith(format: format),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: Space.lg),
      if (_settings.isCompressed)
        _labelled(
          'Bit rate',
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              for (final rate in ExportSettings.bitRateChoices)
                ChoiceChip(
                  label: Text('${rate ~/ 1000} kbps'),
                  selected: _settings.bitRate == rate,
                  onSelected: (_) => setState(
                    () => _settings = _settings.copyWith(bitRate: rate),
                  ),
                ),
            ],
          ),
        )
      else
        _labelled(
          'Bit depth',
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              for (final depth in ExportBitDepth.values)
                ChoiceChip(
                  label: Text(depth.displayName),
                  selected: _settings.bitDepth == depth,
                  onSelected: (_) => setState(
                    () => _settings = _settings.copyWith(bitDepth: depth),
                  ),
                ),
            ],
          ),
        ),
      const SizedBox(height: Space.lg),
      _labelled(
        'Sample rate',
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            for (final rate in ExportSettings.sampleRateChoices)
              ChoiceChip(
                label: Text('${(rate / 1000).toStringAsFixed(1)} kHz'),
                selected: _settings.sampleRate == rate,
                onSelected: (_) => setState(
                  () => _settings = _settings.copyWith(sampleRate: rate),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: Space.xl),
      _summary(theme),
      if (note != null) ...[
        const SizedBox(height: Space.md),
        _infoNote(theme, note),
      ],
      if (_failure != null) ...[
        const SizedBox(height: Space.md),
        Text(
          _failure!,
          style: theme.textTheme.bodyMedium?.copyWith(color: Palette.record),
        ),
      ],
      const SizedBox(height: Space.xl),
      FilledButton.icon(
        onPressed: formats.isEmpty ? null : _export,
        icon: const Icon(Icons.save_alt_rounded, size: 18),
        label: Text(_stems ? 'Export tracks' : 'Export mix'),
      ),
    ];
  }

  /// One line that spells out exactly what is about to be written.
  Widget _summary(ThemeData theme) {
    final parts = [
      _settings.format.displayName,
      if (_settings.isCompressed)
        '${_settings.bitRate ~/ 1000} kbps'
      else
        _settings.bitDepth.displayName,
      '${(_settings.sampleRate / 1000).toStringAsFixed(1)} kHz',
      _stems
          ? '${widget.project.tracks.length} files'
          : formatDuration(widget.project.duration),
    ];
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: Palette.well,
        borderRadius: Radii.allControl,
        border: Border.all(color: Palette.lineFaint),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.graphic_eq_rounded,
            size: 15,
            color: Palette.textTertiary,
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              parts.join('  ·  '),
              style: EncoreType.numeric.copyWith(color: Palette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoNote(ThemeData theme, String message) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Icon(
            Icons.info_outline_rounded,
            size: 14,
            color: Palette.textTertiary,
          ),
        ),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Palette.textTertiary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _labelled(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: label,
          padding: const EdgeInsets.only(bottom: Space.sm),
        ),
        child,
      ],
    );
  }

  /// Explains a gap rather than silently offering fewer formats.
  String? _missingFormatsNote(List<AudioFileFormat> available) {
    if (available.contains(AudioFileFormat.mp3)) return null;
    final canInstallFfmpeg =
        Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    return canInstallFfmpeg
        ? 'MP3 export needs an FFmpeg build on this computer. WAV and AAC are '
              'written by the system encoder and are always available.'
        : 'MP3 export is not available on this device. AAC is the compressed '
              'format here, and plays everywhere MP3 does.';
  }

  Widget _progressView(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text('Rendering…', style: theme.textTheme.titleMedium),
            ),
            Text(
              '${(_progress * 100).round()}%',
              style: EncoreType.timecode.copyWith(
                fontSize: 22,
                color: Palette.emberBright,
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        ProgressTrack(value: _progress),
        const SizedBox(height: Space.md),
        Text(
          'Rendered through the same graph and master limiter you have been '
          'listening to.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: Palette.textTertiary,
          ),
        ),
        const SizedBox(height: Space.xl),
        OutlinedButton(
          onPressed: () => setState(() => _cancelled = true),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _resultsView(ThemeData theme) {
    final folder = _results.first.path.substring(
      0,
      _results.first.path.lastIndexOf(Platform.pathSeparator),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Palette.play.withValues(alpha: 0.14),
                borderRadius: Radii.allControl,
              ),
              child: const Icon(
                Icons.check_rounded,
                size: 18,
                color: Palette.play,
              ),
            ),
            const SizedBox(width: Space.md),
            Text(
              _results.length == 1
                  ? 'Exported'
                  : 'Exported ${_results.length} files',
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
        const SizedBox(height: Space.lg),
        SurfacePanel(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.md,
            vertical: Space.sm,
          ),
          colour: Palette.well,
          child: Column(
            children: [
              for (final result in _results)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.insert_drive_file_outlined,
                        size: 14,
                        color: Palette.textTertiary,
                      ),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Text(
                          result.fileName,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Palette.textPrimary,
                          ),
                        ),
                      ),
                      Text(
                        formatBytes(result.sizeBytes),
                        style: EncoreType.numeric,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: Space.md),
        Row(
          children: [
            Expanded(
              child: Text(
                folder,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Palette.textTertiary,
                ),
              ),
            ),
            const SizedBox(width: Space.sm),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: folder));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Folder path copied')),
                );
              },
              icon: const Icon(Icons.copy_rounded, size: 15),
              label: const Text('Copy path'),
            ),
          ],
        ),
        const SizedBox(height: Space.xl),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
