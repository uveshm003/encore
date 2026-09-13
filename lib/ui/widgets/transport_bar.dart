import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/audio_buffer.dart';
import '../../core/dsp/level_meter.dart';
import '../../engine/audio_engine.dart';
import '../../project/models/project.dart';
import '../../project/project_controller.dart';
import '../theme.dart';
import 'level_meter_bar.dart';

/// The always-visible transport (UI-02).
///
/// Everything here is one press: play, record, loop, click. The buttons are
/// sized for touch as well as a mouse, and the record button is kept in a pod
/// of its own — the only red thing on screen, and never adjacent to play — so
/// it cannot be hit by accident.
class TransportBar extends StatelessWidget {
  const TransportBar({
    required this.controller,
    required this.project,
    required this.onRecordPressed,
    required this.onExportPressed,
    required this.zoom,
    required this.onZoomChanged,
    super.key,
  });

  final ProjectController controller;
  final Project project;
  final VoidCallback onRecordPressed;
  final VoidCallback onExportPressed;

  /// Frames per pixel; larger is zoomed further out.
  final double zoom;
  final ValueChanged<double> onZoomChanged;

  static const double minZoom = 64;
  static const double maxZoom = 8192;

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.md,
      ),
      decoration: const BoxDecoration(
        color: Palette.panel,
        // One rule where the transport meets the timeline. That edge is
        // structural — two regions of the app meeting — which is the only
        // thing a rule is for.
        border: Border(top: BorderSide(color: Palette.line)),
      ),
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The bar has to survive a narrow window as well as a wide one, so
            // the secondary controls drop away before anything can overflow.
            // Transport, timecode and export are never dropped.
            final width = constraints.maxWidth;
            final showMeters = width >= 820;
            final showZoom = width >= 1000;
            final showHistory = width >= 700;
            // Below this the controls cannot sit on one line at any sensible
            // size, so the bar becomes two rows rather than being truncated.
            final stacked = width < 560;

            return ValueListenableBuilder<TransportState>(
              valueListenable: engine.transport,
              builder: (context, transport, _) {
                final secondary = <Widget>[
                  if (showMeters) ...[
                    if (transport.isRecording || _hasArmedTrack)
                      _meter(context, 'IN', engine.inputLevel),
                    _meter(context, 'OUT', engine.outputLevel),
                    const SizedBox(width: Space.md),
                  ],
                  if (showZoom) ...[
                    _zoomControl(context),
                    const SizedBox(width: Space.sm),
                  ],
                  if (showHistory) ...[
                    _historyButtons(context),
                    const SizedBox(width: Space.sm),
                  ],
                  _exportButton(compact: stacked),
                ];

                if (stacked) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(child: _timecode(context, transport)),
                          const Spacer(),
                          _toggles(context),
                          ...secondary,
                        ],
                      ),
                      const SizedBox(height: Space.sm),
                      _transportButtons(context, transport),
                    ],
                  );
                }

                return Row(
                  children: [
                    _transportButtons(context, transport),
                    const SizedBox(width: Space.md),
                    Flexible(child: _timecode(context, transport)),
                    const SizedBox(width: Space.sm),
                    _toggles(context),
                    const Spacer(),
                    ...secondary,
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  bool get _hasArmedTrack => project.tracks.any((track) => track.recordArmed);

  // -------------------------------------------------------------- transport

  Widget _transportButtons(BuildContext context, TransportState transport) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Pod(
          children: [
            _TransportButton(
              tooltip: 'Back to start',
              icon: Icons.skip_previous_rounded,
              onPressed: () => controller.seek(0),
            ),
            _TransportButton(
              tooltip: transport.isPlaying ? 'Pause' : 'Play',
              icon: transport.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              size: 38,
              iconSize: 22,
              // Lit only while it is actually playing. A solid orange key on a
              // stopped transport was the loudest thing on the screen and it
              // was reporting nothing: ember is supposed to mean *live*, and
              // spending it on an idle control is what stops it meaning
              // anything when something really is running.
              filled: transport.isPlaying,
              selected: !transport.isPlaying,
              tint: Palette.play,
              onPressed: () =>
                  transport.isPlaying ? controller.pause() : controller.play(),
            ),
            _TransportButton(
              tooltip: 'Stop',
              icon: Icons.stop_rounded,
              onPressed: controller.stop,
            ),
          ],
        ),
        const SizedBox(width: Space.md),
        _Pod(
          tint: Palette.record,
          children: [
            _TransportButton(
              tooltip: transport.isRecording ? 'Stop recording' : 'Record',
              icon: transport.isRecording
                  ? Icons.stop_circle_outlined
                  : Icons.fiber_manual_record_rounded,
              size: 36,
              iconSize: 20,
              // Recording is shown by the button being solid red. That is
              // already the loudest thing on the bar; a halo on top of it was
              // saying the same thing twice.
              filled: transport.isRecording,
              tint: Palette.record,
              onPressed: onRecordPressed,
            ),
          ],
        ),
      ],
    );
  }

  /// The read-out, in a recessed well: it is the one thing on the bar that is
  /// read rather than pressed.
  Widget _timecode(BuildContext context, TransportState transport) {
    final position = framesToDuration(
      transport.positionFrames,
      project.sampleRate,
    );
    final countIn = transport.countInRemainingFrames;
    final recording = transport.isRecording;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      decoration: BoxDecoration(
        color: Palette.well,
        borderRadius: Radii.allControl,
        border: Border.all(
          color: recording
              ? Palette.record.withValues(alpha: 0.4)
              : Palette.lineFaint,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatTimecode(position),
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: EncoreType.timecode.copyWith(
              fontSize: 19,
              color: recording ? Palette.record : Palette.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            countIn > 0
                // A count-in is the one time the number matters more than the
                // position, so it takes over the read-out.
                ? 'Count-in ${(countIn / project.sampleRate).ceil()}'
                : 'of ${formatDuration(project.duration)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: EncoreType.numeric.copyWith(
              fontSize: 10.5,
              color: countIn > 0 ? Palette.record : Palette.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggles(BuildContext context) {
    final loopReady = project.transport.hasLoopRegion;
    return _Pod(
      children: [
        _TransportButton(
          tooltip: loopReady
              ? 'Loop the selected region'
              : 'Drag under the ruler to set a loop region',
          icon: Icons.repeat_rounded,
          selected: project.transport.loopEnabled,
          onPressed: loopReady
              ? () => controller.setLoopEnabled(!project.transport.loopEnabled)
              : null,
        ),
        _TransportButton(
          tooltip: 'Metronome and count-in',
          icon: Icons.av_timer_rounded,
          selected: project.transport.metronomeEnabled,
          onPressed: () => controller.setMetronomeEnabled(
            !project.transport.metronomeEnabled,
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------- meters

  Widget _meter(
    BuildContext context,
    String label,
    ValueListenable<LevelReading> level,
  ) {
    return Padding(
      padding: const EdgeInsets.only(right: Space.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: EncoreType.panelLabel.copyWith(fontSize: 9, letterSpacing: 1),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 92,
            child: ValueListenableBuilder<LevelReading>(
              valueListenable: level,
              builder: (context, reading, _) => LevelMeterBar(reading: reading),
            ),
          ),
        ],
      ),
    );
  }

  Widget _zoomControl(BuildContext context) {
    return SizedBox(
      width: 136,
      child: Row(
        children: [
          const Icon(
            Icons.zoom_out_rounded,
            size: 15,
            color: Palette.textTertiary,
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                // Zoom is exponential, so dragging feels the same at every
                // scale.
                value: _zoomToSlider(zoom),
                onChanged: (value) => onZoomChanged(_sliderToZoom(value)),
              ),
            ),
          ),
          const Icon(
            Icons.zoom_in_rounded,
            size: 15,
            color: Palette.textTertiary,
          ),
        ],
      ),
    );
  }

  Widget _historyButtons(BuildContext context) {
    return _Pod(
      children: [
        _TransportButton(
          tooltip: 'Undo',
          icon: Icons.undo_rounded,
          onPressed: controller.canUndo ? controller.undo : null,
        ),
        _TransportButton(
          tooltip: 'Redo',
          icon: Icons.redo_rounded,
          onPressed: controller.canRedo ? controller.redo : null,
        ),
      ],
    );
  }

  Widget _exportButton({required bool compact}) {
    if (compact) {
      return IconButton(
        tooltip: 'Export',
        onPressed: onExportPressed,
        icon: const Icon(Icons.ios_share_rounded, size: 18),
        style: IconButton.styleFrom(
          backgroundColor: Palette.inset,
          foregroundColor: Palette.textPrimary,
          minimumSize: const Size(34, 34),
        ),
      );
    }
    // Outlined, not filled. Export is where the work goes when it is
    // finished; it is not the thing the transport is for, and it was
    // competing with the play key for the eye.
    return OutlinedButton.icon(
      onPressed: onExportPressed,
      icon: const Icon(Icons.ios_share_rounded, size: 16),
      label: const Text('Export'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: Space.md),
      ),
    );
  }

  /// The slider runs 0 (zoomed out) to 1 (zoomed in) over a log scale, so a
  /// given drag distance changes the zoom by the same ratio everywhere.
  static double _zoomToSlider(double framesPerPixel) {
    final low = _log2(minZoom);
    final high = _log2(maxZoom);
    return 1 - ((_log2(framesPerPixel) - low) / (high - low)).clamp(0.0, 1.0);
  }

  static double _sliderToZoom(double value) {
    final low = _log2(minZoom);
    final high = _log2(maxZoom);
    return math.pow(2, high - (high - low) * value).toDouble();
  }

  static double _log2(double value) =>
      value <= 0 ? 0 : math.log(value) / math.ln2;
}

/// A recessed group that holds related controls together.
class _Pod extends StatelessWidget {
  const _Pod({required this.children, this.tint});

  final List<Widget> children;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Palette.well,
        borderRadius: Radii.allControl,
        border: Border.all(
          color: tint == null
              ? Palette.lineFaint
              : tint!.withValues(alpha: 0.22),
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// One round control in a [_Pod].
class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.size = 34,
    this.iconSize = 19,
    this.filled = false,
    this.selected = false,
    this.tint = Palette.ember,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final bool filled;
  final bool selected;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final Color background;
    final Color foreground;
    if (filled) {
      background = tint;
      foreground = const Color(0xFF1A0C05);
    } else if (selected) {
      background = Palette.inset;
      foreground = tint;
    } else {
      background = Colors.transparent;
      foreground = enabled ? Palette.textSecondary : Palette.textDisabled;
    }

    return Tooltip(
      message: tooltip,
      child: AnimatedContainer(
        duration: Motion.fast,
        width: size,
        height: size,
        decoration: BoxDecoration(color: background, shape: BoxShape.circle),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Icon(icon, size: iconSize, color: foreground),
          ),
        ),
      ),
    );
  }
}
