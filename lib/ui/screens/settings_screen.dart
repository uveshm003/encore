import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/app_info.dart';
import '../../app/app_services.dart';
import '../../core/audio_buffer.dart';
import '../../engine/audio_input.dart';
import '../../engine/latency.dart';
import '../../engine/playback_engine.dart';
import '../../io/audio_file_format.dart';
import '../../io/codec/codec_registry.dart';
import '../../separation/model_store.dart';
import '../../separation/separation_model.dart';
import '../theme.dart';
import '../widgets/brand.dart';
import '../widgets/primitives.dart';
import 'licences_screen.dart';

/// Device setup, storage and what this build can actually do.
///
/// The last part matters: which formats can be opened and written depends on
/// what is installed on the machine, and it is better to say so here than to
/// let the user discover it at the end of an export.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<AudioInputDevice> _devices = const [];
  List<ModelInstallation> _models = const [];
  int _librarySize = 0;
  int _cacheSize = 0;
  int _modelSize = 0;
  bool _calibrating = false;
  LatencyMeasurement? _measurement;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  AppServices get _services => ServicesScope.of(context);

  Future<void> _refresh() async {
    final services = _services;
    final library = await services.library.storageSize();
    final cache = await services.stemCache.sizeBytes();
    final models = await services.modelStore.sizeBytes();
    final installations = await services.modelStore.listAll();
    if (!mounted) return;
    setState(() {
      _librarySize = library;
      _cacheSize = cache;
      _modelSize = models;
      _models = installations;
    });
    await _loadDevices();
  }

  Future<void> _loadDevices() async {
    // Device enumeration goes through the recorder, which is only reachable
    // on the concrete engine; a different engine simply offers no list.
    final engine = _services.engine;
    if (engine is! PlaybackEngine) return;
    final input = RecordAudioInput();
    final devices = await input.listDevices();
    if (mounted) setState(() => _devices = devices);
  }

  Future<void> _calibrate() async {
    final engine = _services.engine;
    setState(() {
      _calibrating = true;
      _measurement = null;
    });
    try {
      final measurement = await engine.calibrateLatency(
        deviceId: _services.settings.inputDeviceId,
      );
      if (!mounted) return;
      setState(() => _measurement = measurement);
      if (measurement.isReliable && engine is PlaybackEngine) {
        final updated = engine.applyMeasurement(measurement);
        engine.latency = updated;
        await _services.settings.setLatency(updated);
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Calibration failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _calibrating = false);
    }
  }

  Future<void> _clearCache() async {
    await _services.stemCache.clear();
    await _refresh();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Separated stems cleared.')),
      );
    }
  }

  Future<void> _installModel(SeparationModel model) async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Choose the ${model.name} model file',
      type: FileType.custom,
      allowedExtensions: const ['onnx'],
    );
    final path = files.isEmpty ? null : files.first.path;
    if (path == null) return;
    await _services.modelStore.installFromFile(model, path);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = _services.settings;

    return Scaffold(
      backgroundColor: Palette.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Settings'),
      ),
      body: AppGround(
        child: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  Space.xl,
                  0,
                  Space.xl,
                  Space.huge,
                ),
                children: [
                  const SectionHeader(
                    title: 'Recording',
                    padding: EdgeInsets.fromLTRB(
                      Space.xs,
                      Space.md,
                      Space.xs,
                      Space.md,
                    ),
                  ),
                  SurfacePanel(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        _inputDeviceTile(settings.inputDeviceId),
                        const Divider(height: 1),
                        SwitchListTile(
                          value: settings.monitorInput,
                          onChanged: settings.setMonitorInput,
                          title: const Text('Hear yourself while recording'),
                          subtitle: const Text(
                            'Software monitoring adds the round-trip delay '
                            'below. If your interface or headphones offer '
                            'direct monitoring, use that instead — it is '
                            'always faster.',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  _latencyCard(theme),

                  const SectionHeader(title: 'Separation'),
                  SurfacePanel(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        ListTile(
                          title: const Text('Default quality'),
                          subtitle: Text(settings.separationModel.summary),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                settings.separationModel.name,
                                style: EncoreType.numeric,
                              ),
                              const SizedBox(width: Space.xs),
                              const Icon(
                                Icons.chevron_right_rounded,
                                size: 18,
                              ),
                            ],
                          ),
                          onTap: _chooseDefaultModel,
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          value: settings.fourStemSeparation,
                          onChanged: settings.setFourStemSeparation,
                          title: const Text(
                            'Separate into four parts by default',
                          ),
                          subtitle: const Text(
                            'Vocals, drums, bass and everything else, instead '
                            'of just vocals and backing.',
                          ),
                        ),
                        for (final installation in _models)
                          if (installation.model.requiresInstall) ...[
                            const Divider(height: 1),
                            _modelTile(installation),
                          ],
                      ],
                    ),
                  ),

                  const SectionHeader(title: 'Storage'),
                  _storageCard(theme),

                  const SectionHeader(title: 'This device'),
                  _capabilitiesCard(theme),

                  const SectionHeader(title: 'About'),
                  _aboutCard(theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _inputDeviceTile(String? selected) {
    return ListTile(
      leading: const Icon(Icons.mic_none_rounded),
      title: const Text('Input'),
      subtitle: Text(
        _devices.isEmpty
            ? 'System default'
            : _devices
                  .firstWhere(
                    (device) => device.id == selected,
                    orElse: () => const AudioInputDevice(
                      id: '',
                      label: 'System default',
                    ),
                  )
                  .label,
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Choose input',
        icon: const Icon(Icons.expand_more_rounded, size: 18),
        onSelected: (value) =>
            _services.settings.setInputDeviceId(value.isEmpty ? null : value),
        itemBuilder: (context) => [
          const PopupMenuItem(value: '', child: Text('System default')),
          for (final device in _devices)
            PopupMenuItem(value: device.id, child: Text(device.label)),
        ],
      ),
    );
  }

  /// Latency gets a card of its own because it is the one setting that
  /// changes whether a recording lands in time.
  Widget _latencyCard(ThemeData theme) {
    final latency = _services.engine.latency;
    final sampleRate = _services.config.sampleRate;
    final measurement = _measurement;

    return SurfacePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Timing', style: theme.textTheme.titleSmall),
              const SizedBox(width: Space.sm),
              MetaChip(
                label: latency.isCalibrated ? 'Measured' : 'Estimated',
                colour: latency.isCalibrated ? Palette.play : Palette.warn,
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Text(
            'Encore shifts each take back by the delay between playing a '
            'sound and hearing it recorded, so overdubs land in time. '
            'Measuring it on your own hardware makes that exact.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _milliseconds(latency.compensationFrames, sampleRate),
                      style: EncoreType.timecode.copyWith(fontSize: 26),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'round-trip compensation',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Palette.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _calibrating ? null : _calibrate,
                style: FilledButton.styleFrom(
                  backgroundColor: Palette.inset,
                  foregroundColor: Palette.textPrimary,
                  minimumSize: const Size(0, 40),
                ),
                icon: _calibrating
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.speed_rounded, size: 18),
                label: Text(_calibrating ? 'Listening…' : 'Measure'),
              ),
            ],
          ),
          if (_calibrating) ...[
            const SizedBox(height: Space.md),
            Text(
              'Turn the volume up and keep the room quiet — Encore plays a '
              'short sweep and listens for it through the microphone.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (measurement != null) ...[
            const SizedBox(height: Space.md),
            Text(
              measurement.isReliable
                  ? 'Measured ${_milliseconds(measurement.roundTripFrames, sampleRate)} '
                        'round trip and applied it.'
                  : 'The sweep could not be heard clearly. Check the '
                        'microphone and speaker volume, then try again.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: measurement.isReliable ? Palette.play : Palette.record,
              ),
            ),
          ],
          const SizedBox(height: Space.lg),
          Row(
            children: [
              Text('Fine adjustment', style: theme.textTheme.bodySmall),
              const Spacer(),
              Text(
                _milliseconds(latency.manualOffsetFrames, sampleRate),
                style: EncoreType.numeric,
              ),
            ],
          ),
          Slider(
            value: latency.manualOffsetFrames
                .clamp(-sampleRate ~/ 10, sampleRate ~/ 10)
                .toDouble(),
            min: -sampleRate / 10,
            max: sampleRate / 10,
            onChanged: (value) {
              final updated = latency.copyWith(
                manualOffsetFrames: value.round(),
              );
              _services.engine.latency = updated;
              _services.settings.setLatency(updated);
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  Widget _modelTile(ModelInstallation installation) {
    final model = installation.model;
    return ListTile(
      leading: Icon(
        installation.isInstalled
            ? Icons.check_circle_outline_rounded
            : Icons.download_outlined,
        color: installation.isInstalled ? Palette.play : Palette.textTertiary,
      ),
      title: Text(model.name),
      subtitle: Text(
        installation.isInstalled
            ? 'Installed · ${formatBytes(installation.sizeBytes)}'
            : model.licence ?? 'Not installed',
      ),
      trailing: installation.isInstalled
          ? TextButton(
              onPressed: () async {
                await _services.modelStore.remove(model);
                await _refresh();
              },
              child: const Text('Remove'),
            )
          : TextButton(
              onPressed: () => _installModel(model),
              child: const Text('Install…'),
            ),
    );
  }

  /// Where the disk has gone, as one bar and three rows.
  Widget _storageCard(ThemeData theme) {
    final total = _librarySize + _cacheSize + _modelSize;
    final segments = [
      (
        'Imported songs',
        _librarySize,
        Palette.trackInstrumental,
        'Working copies of the songs you imported.',
        null,
      ),
      (
        'Separated stems',
        _cacheSize,
        Palette.ember,
        'Saved so a song never has to be separated twice.',
        _cacheSize == 0
            ? null
            : TextButton(onPressed: _clearCache, child: const Text('Clear')),
      ),
      (
        'Models',
        _modelSize,
        Palette.trackBass,
        'Installed separation models.',
        null,
      ),
    ];

    return SurfacePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Used by Encore', style: theme.textTheme.titleSmall),
              const Spacer(),
              Text(formatBytes(total), style: EncoreType.numeric),
            ],
          ),
          const SizedBox(height: Space.md),
          ClipRRect(
            borderRadius: Radii.allControl,
            child: SizedBox(
              height: 8,
              child: total == 0
                  ? const ColoredBox(color: Palette.well)
                  : Row(
                      children: [
                        for (final segment in segments)
                          if (segment.$2 > 0)
                            Expanded(
                              flex: segment.$2,
                              child: ColoredBox(color: segment.$3),
                            ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: Space.lg),
          for (final segment in segments) ...[
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    color: segment.$3,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(segment.$1, style: theme.textTheme.bodyMedium),
                      Text(segment.$4, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                Text(formatBytes(segment.$2), style: EncoreType.numeric),
                if (segment.$5 != null) ...[
                  const SizedBox(width: Space.xs),
                  segment.$5!,
                ],
              ],
            ),
            if (segment != segments.last) const SizedBox(height: Space.md),
          ],
          const Divider(height: Space.xxl),
          Text('Where files are kept', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 2),
          SelectableText(
            _services.paths.root.path,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Palette.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _capabilitiesCard(ThemeData theme) {
    final codecs = _services.codecs;
    final unsupported = codecs.unsupportedImportFormats;
    return SurfacePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Audio formats', style: theme.textTheme.titleSmall),
          const SizedBox(height: Space.md),
          _formatRow(theme, 'Reading', codecs.decodableFormats),
          const SizedBox(height: Space.sm),
          _formatRow(theme, 'Writing', codecs.encodableFormats),
          if (unsupported.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            Text(
              CodecRegistry.canInstallFfmpeg
                  // Only advice that can be acted on: there is nowhere to put
                  // an FFmpeg binary on a phone.
                  ? 'Not available here: ${_formatList(unsupported)}. '
                        'Installing FFmpeg on this machine adds them, along '
                        'with MP3 export.'
                  : 'Not available here: ${_formatList(unsupported)}. This '
                        'device has no decoder for them.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Palette.textTertiary,
              ),
            ),
          ],
          const SizedBox(height: Space.md),
          Text(
            'Backends: '
            '${codecs.availableBackends.map((backend) => backend.name).join(', ')}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: Palette.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _formatRow(
    ThemeData theme,
    String label,
    Iterable<AudioFileFormat> formats,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 62,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Palette.textTertiary,
            ),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              for (final format in formats.toList()
                ..sort((a, b) => a.displayName.compareTo(b.displayName)))
                MetaChip(label: format.displayName),
            ],
          ),
        ),
      ],
    );
  }

  Widget _aboutCard(ThemeData theme) {
    return SurfacePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const EncoreWordmark(markSize: 30),
              const SizedBox(width: Space.md),
              Text(AppInfo.versionLabel, style: EncoreType.numeric),
              const Spacer(),
              const OfflineBadge(),
            ],
          ),
          const SizedBox(height: Space.lg),
          _aboutRow(
            theme,
            Icons.lock_outline_rounded,
            'Everything stays on this device',
            'Encore has no accounts and no servers. Your audio is never '
                'uploaded, and nothing about it is collected.',
          ),
          const SizedBox(height: Space.md),
          _aboutRow(
            theme,
            Icons.gavel_rounded,
            'Use only music you have the right to use',
            'Encore is a personal practice and recording tool. Separating '
                'and re-recording someone else’s song does not give you the '
                'right to publish the result.',
          ),
          const SizedBox(height: Space.lg),
          const Divider(height: 1),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.description_outlined,
              size: 16,
              color: Palette.textTertiary,
            ),
            title: const Text('Open-source licences'),
            subtitle: const Text(
              'The copyright notices of everything Encore is built on.',
            ),
            trailing: const Icon(Icons.chevron_right_rounded, size: 18),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => const LicencesScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _aboutRow(
    ThemeData theme,
    IconData icon,
    String title,
    String body,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 16, color: Palette.textTertiary),
        ),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 2),
              Text(body, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _chooseDefaultModel() async {
    final chosen = await showDialog<SeparationModel>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Default separation quality'),
        contentPadding: const EdgeInsets.fromLTRB(
          Space.sm,
          Space.md,
          Space.sm,
          Space.lg,
        ),
        children: [
          for (final model in SeparationCatalog.builtIn)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(model),
              padding: EdgeInsets.zero,
              child: ListTile(
                title: Text(model.name),
                subtitle: Text(model.summary),
              ),
            ),
        ],
      ),
    );
    if (chosen != null) await _services.settings.setSeparationModel(chosen);
  }

  static String _formatList(Iterable<AudioFileFormat> formats) {
    final names = formats.map((format) => format.displayName).toList()..sort();
    return names.isEmpty ? 'none' : names.join(', ');
  }

  static String _milliseconds(int frames, int sampleRate) {
    final ms = framesToDuration(frames.abs(), sampleRate).inMicroseconds / 1000;
    return '${frames < 0 ? '-' : ''}${ms.toStringAsFixed(1)} ms';
  }
}
