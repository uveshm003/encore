import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_services.dart';
import '../../core/audio_buffer.dart';
import '../../engine/audio_engine.dart';
import '../../project/edit_commands.dart';
import '../../project/models/project.dart';
import '../../project/models/take.dart';
import '../../project/models/track.dart';
import '../../project/project_controller.dart';
import '../theme.dart';
import '../widgets/primitives.dart';
import '../widgets/timeline_view.dart';
import '../widgets/track_header.dart';
import '../widgets/transport_bar.dart';
import 'export_sheet.dart';

/// The workspace: tracks on a timeline, a transport underneath, and the
/// editing tools that act on whatever is selected (UI-01, UI-02, UI-03).
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  double _zoom = 1024;
  String? _selectedTrackId;
  String? _selectedClipId;
  String? _shownError;
  bool _bannerDismissed = false;

  AppServices get _services => ServicesScope.of(context);

  ProjectController get _controller => _services.controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final project = _controller.project;
        _reportErrors();

        if (_controller.isLoading || project == null) {
          return _loadingScaffold();
        }

        return CallbackShortcuts(
          bindings: _shortcuts(project),
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: Palette.well,
              appBar: _appBar(project),
              body: Column(
                children: [
                  if (_controller.missingAssets.isNotEmpty && !_bannerDismissed)
                    _missingAssetsBanner(),
                  Expanded(
                    child: TimelineView(
                      controller: _controller,
                      project: project,
                      framesPerPixel: _zoom,
                      selectedTrackId: _selectedTrackId,
                      selectedClipId: _selectedClipId,
                      onTrackSelected: (id) =>
                          setState(() => _selectedTrackId = id),
                      onClipSelected: (trackId, clipId) => setState(() {
                        _selectedTrackId = trackId;
                        _selectedClipId = clipId;
                      }),
                      onTrackMenu: _handleTrackMenu,
                      onAddTrack: _addTrack,
                    ),
                  ),
                  if (_selectedClipId != null) _clipTools(project),
                  TransportBar(
                    controller: _controller,
                    project: project,
                    onRecordPressed: _toggleRecording,
                    onExportPressed: () => _openExport(project),
                    zoom: _zoom,
                    onZoomChanged: (value) => setState(() => _zoom = value),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _loadingScaffold() {
    final loading = _controller.isLoading;
    return Scaffold(
      backgroundColor: Palette.surface,
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(
                Icons.error_outline_rounded,
                size: 28,
                color: Palette.record,
              ),
            const SizedBox(height: Space.lg),
            Text(
              loading ? 'Loading audio…' : 'This project could not be opened.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Palette.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- app bar

  PreferredSizeWidget _appBar(Project project) {
    return AppBar(
      backgroundColor: Palette.panel,
      shape: const Border(bottom: BorderSide(color: Palette.line)),
      titleSpacing: 0,
      title: Row(
        children: [
          Flexible(
            child: Text(
              project.name,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(width: Space.md),
          _saveIndicator(),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: _addTrack,
          icon: const Icon(Icons.add_rounded, size: 17),
          label: const Text('Add track'),
          style: TextButton.styleFrom(
            foregroundColor: Palette.textSecondary,
            backgroundColor: Palette.inset,
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            minimumSize: const Size(0, 34),
            shape: const RoundedRectangleBorder(borderRadius: Radii.allControl),
          ),
        ),
        const SizedBox(width: Space.lg),
      ],
    );
  }

  /// Auto-save is silent, which is right, but a project that has just changed
  /// should still say so somewhere.
  Widget _saveIndicator() {
    final dirty = _controller.isDirty;
    return AnimatedSwitcher(
      duration: Motion.base,
      child: Row(
        key: ValueKey(dirty),
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(
            colour: dirty ? Palette.warn : Palette.play,
            size: 6,
            pulse: dirty,
          ),
          const SizedBox(width: Space.sm),
          Text(
            dirty ? 'Saving…' : 'Saved',
            style: EncoreType.numeric.copyWith(
              fontSize: 10.5,
              color: Palette.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _missingAssetsBanner() {
    final count = _controller.missingAssets.length;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      decoration: BoxDecoration(
        color: Palette.record.withValues(alpha: 0.12),
        border: const Border(bottom: BorderSide(color: Palette.line)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.report_gmailerrorred_rounded,
            size: 18,
            color: Palette.record,
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              '$count audio file${count == 1 ? '' : 's'} could not be found. '
              'Those tracks will be silent.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Palette.textPrimary,
              ),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _bannerDismissed = true),
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- clip tools

  Widget _clipTools(Project project) {
    final trackId = _selectedTrackId;
    final clipId = _selectedClipId;
    if (trackId == null || clipId == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      decoration: const BoxDecoration(
        color: Palette.overlay,
        border: Border(top: BorderSide(color: Palette.line)),
      ),
      child: ValueListenableBuilder<TransportState>(
        valueListenable: _controller.engine.transport,
        builder: (context, transport, _) {
          final playhead = transport.positionFrames;
          final fadeFrames = (project.sampleRate * 0.25).round();
          return LayoutBuilder(
            builder: (context, constraints) {
              // There are more tools than fit a phone. Rather than dropping
              // any of them, the labels go first and the strip scrolls last.
              final labelled = constraints.maxWidth >= 760;
              final tools = <Widget>[
                _tool(
                  'Split here',
                  Icons.content_cut_rounded,
                  labelled,
                  () => _controller.edit(
                    (p) => ProjectEdits.splitClip(
                      p,
                      trackId,
                      clipId,
                      playhead,
                      _controller.newId,
                    ),
                  ),
                ),
                _tool(
                  'Trim start',
                  Icons.first_page_rounded,
                  labelled,
                  () => _controller.edit(
                    (p) =>
                        ProjectEdits.trimClipStart(p, trackId, clipId, playhead),
                  ),
                ),
                _tool(
                  'Trim end',
                  Icons.last_page_rounded,
                  labelled,
                  () => _controller.edit(
                    (p) =>
                        ProjectEdits.trimClipEnd(p, trackId, clipId, playhead),
                  ),
                ),
                const _ToolDivider(),
                _tool(
                  'Fade in',
                  Icons.north_east_rounded,
                  labelled,
                  () => _controller.edit(
                    (p) => ProjectEdits.setClipFades(
                      p,
                      trackId,
                      clipId,
                      fadeInFrames: fadeFrames,
                    ),
                  ),
                ),
                _tool(
                  'Fade out',
                  Icons.south_east_rounded,
                  labelled,
                  () => _controller.edit(
                    (p) => ProjectEdits.setClipFades(
                      p,
                      trackId,
                      clipId,
                      fadeOutFrames: fadeFrames,
                    ),
                  ),
                ),
                _tool(
                  'Remove fades',
                  Icons.horizontal_rule_rounded,
                  labelled,
                  () => _controller.edit(
                    (p) => ProjectEdits.setClipFades(
                      p,
                      trackId,
                      clipId,
                      fadeInFrames: 0,
                      fadeOutFrames: 0,
                    ),
                  ),
                ),
                const _ToolDivider(),
                _tool(
                  'Delete clip',
                  Icons.delete_outline_rounded,
                  labelled,
                  () {
                    _controller.edit(
                      (p) => ProjectEdits.removeClip(p, trackId, clipId),
                    );
                    setState(() => _selectedClipId = null);
                  },
                  colour: Palette.record,
                ),
              ];

              return Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(right: Space.md, left: Space.xs),
                    child: Text('CLIP', style: EncoreType.panelLabel),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: tools),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Deselect',
                    onPressed: () => setState(() => _selectedClipId = null),
                    icon: const Icon(Icons.close_rounded, size: 17),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _tool(
    String label,
    IconData icon,
    bool labelled,
    VoidCallback onPressed, {
    Color? colour,
  }) {
    final tint = colour ?? Palette.textSecondary;
    final style = TextButton.styleFrom(
      foregroundColor: tint,
      visualDensity: VisualDensity.compact,
      minimumSize: const Size(0, 32),
      padding: EdgeInsets.symmetric(horizontal: labelled ? Space.md : Space.sm),
      shape: const RoundedRectangleBorder(borderRadius: Radii.allControl),
    );

    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Tooltip(
        message: label,
        child: labelled
            ? TextButton.icon(
                onPressed: onPressed,
                style: style,
                icon: Icon(icon, size: 15),
                label: Text(label),
              )
            : TextButton(
                onPressed: onPressed,
                style: style,
                child: Icon(icon, size: 17),
              ),
      ),
    );
  }

  // ------------------------------------------------------------------ actions

  Future<void> _toggleRecording() async {
    if (_controller.isRecording) {
      final take = await _controller.stopRecording();
      if (!mounted) return;
      if (take == null) {
        _snack('Nothing was recorded.');
      } else {
        _snack('Saved ${take.name}.');
      }
      return;
    }
    await _controller.startRecording(
      deviceId: _services.settings.inputDeviceId,
    );
  }

  void _addTrack() {
    final track = _controller.addEmptyTrack();
    setState(() => _selectedTrackId = track.id);
  }

  Future<void> _openExport(Project project) async {
    _controller.pause();
    await _controller.save();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Palette.panel,
      builder: (_) => ExportSheet(project: project),
    );
  }

  Future<void> _handleTrackMenu(Track track, TrackMenuAction action) async {
    switch (action) {
      case TrackMenuAction.rename:
        final name = await _promptForName(track.name);
        if (name == null) return;
        _controller.edit((p) => ProjectEdits.renameTrack(p, track.id, name));
      case TrackMenuAction.chooseTake:
        await _chooseTake(track);
      case TrackMenuAction.duplicate:
        _controller.edit(
          (p) => ProjectEdits.addTrack(
            p,
            track.copyWith(
              id: _controller.newId(),
              name: '${track.name} copy',
              clips: [
                for (final clip in track.clips)
                  clip.copyWith(id: _controller.newId()),
              ],
              recordArmed: false,
            ),
          ),
        );
      case TrackMenuAction.delete:
        _controller.edit((p) => ProjectEdits.removeTrack(p, track.id));
        if (_selectedTrackId == track.id) {
          setState(() {
            _selectedTrackId = null;
            _selectedClipId = null;
          });
        }
    }
  }

  /// Take comping: pick which pass of a track is on the timeline (REC-05).
  Future<void> _chooseTake(Track track) async {
    final project = _controller.project;
    if (project == null) return;
    final chosen = await showDialog<Take>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Takes on ${track.name}'),
        contentPadding: const EdgeInsets.fromLTRB(
          Space.sm,
          Space.md,
          Space.sm,
          Space.lg,
        ),
        children: [
          for (final take in track.takes)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(take),
              padding: EdgeInsets.zero,
              child: ListTile(
                selected: take.id == track.activeTakeId,
                selectedTileColor: Palette.ember.withValues(alpha: 0.08),
                leading: Icon(
                  take.id == track.activeTakeId
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: take.id == track.activeTakeId
                      ? Palette.ember
                      : Palette.textTertiary,
                ),
                title: Text(take.name),
                subtitle: Text(
                  '${formatDuration(framesToDuration(take.length, project.sampleRate))} · '
                  'recorded ${take.recordedAt.hour.toString().padLeft(2, '0')}:'
                  '${take.recordedAt.minute.toString().padLeft(2, '0')}',
                ),
              ),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    _controller.edit(
      (p) => ProjectEdits.selectTake(p, track.id, chosen.id, _controller.newId),
    );
  }

  // ---------------------------------------------------------------- keyboard

  Map<ShortcutActivator, VoidCallback> _shortcuts(Project project) {
    return {
      const SingleActivator(LogicalKeyboardKey.space): () =>
          _controller.engine.transport.value.isPlaying
          ? _controller.pause()
          : _controller.play(),
      const SingleActivator(LogicalKeyboardKey.keyR): _toggleRecording,
      const SingleActivator(LogicalKeyboardKey.keyL): () =>
          _controller.setLoopEnabled(!project.transport.loopEnabled),
      const SingleActivator(LogicalKeyboardKey.home): () => _controller.seek(0),
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
          _controller.undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
          _controller.undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
          _controller.redo,
      const SingleActivator(
        LogicalKeyboardKey.keyZ,
        control: true,
        shift: true,
      ): _controller.redo,
      const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
          _controller.save(),
      const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
          _controller.save(),
    };
  }

  // ----------------------------------------------------------------- helpers

  void _reportErrors() {
    final error = _controller.error;
    if (error == null || error == _shownError) return;
    _shownError = error;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _snack(error);
      _controller.clearError();
      _shownError = null;
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _promptForName(String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename track'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    ).then((value) => (value == null || value.isEmpty) ? null : value);
  }
}

/// A hairline between groups of clip tools.
class _ToolDivider extends StatelessWidget {
  const _ToolDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: Space.sm),
      color: Palette.line,
    );
  }
}
