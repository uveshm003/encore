import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/audio_buffer.dart';
import '../../core/waveform.dart';
import '../../engine/audio_engine.dart';
// Aliased: the project's Clip model shares its name with Flutter's Clip enum.
import '../../project/models/clip.dart' as model;
import '../../project/models/project.dart';
import '../../project/models/track.dart';
import '../../project/project_controller.dart';
import '../theme.dart';
import 'track_header.dart';
import 'waveform_view.dart';

/// The arranged view of a project: tracks side by side on one time axis
/// (UI-01, UI-03).
///
/// Headers stay pinned at the left while the lanes scroll horizontally
/// together, so every track is always read against the same position in the
/// song — which is the point of the view when overdubbing.
class TimelineView extends StatefulWidget {
  const TimelineView({
    required this.controller,
    required this.project,
    required this.framesPerPixel,
    required this.selectedTrackId,
    required this.selectedClipId,
    required this.onTrackSelected,
    required this.onClipSelected,
    required this.onTrackMenu,
    this.onAddTrack,
    this.trackHeight = 116,
    this.headerWidth = 212,
    super.key,
  });

  final ProjectController controller;
  final Project project;

  /// Zoom: how many audio frames one horizontal pixel covers.
  final double framesPerPixel;
  final String? selectedTrackId;
  final String? selectedClipId;
  final ValueChanged<String> onTrackSelected;
  final void Function(String trackId, String clipId) onClipSelected;
  final void Function(Track track, TrackMenuAction action) onTrackMenu;

  /// Shown as a ghost row under the last track. Omitted when there is nowhere
  /// for a new track to come from.
  final VoidCallback? onAddTrack;
  final double trackHeight;
  final double headerWidth;

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> {
  final _horizontal = ScrollController();

  static const double _rulerHeight = 32;
  static const double _loopLaneHeight = 18;
  static const double _addRowHeight = 44;

  /// Frames accumulated during a clip drag, so a move is one undo step.
  double _dragFrames = 0;
  int? _loopAnchorFrame;

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  int _frameAt(double dx) => math.max(0, (dx * widget.framesPerPixel).round());

  double _xFor(int frame) => frame / widget.framesPerPixel;

  /// Seconds between ruler labels at the current zoom.
  ///
  /// The first step from the ladder that leaves at least 72 px between labels,
  /// so the ruler and the grid behind it stay readable however far in or out
  /// the view is.
  double get _gridSeconds {
    final secondsPerPixel = widget.framesPerPixel / widget.project.sampleRate;
    const steps = [1, 2, 5, 10, 15, 30, 60, 120, 300];
    for (final candidate in steps) {
      if (candidate / secondsPerPixel >= 72) return candidate.toDouble();
    }
    return steps.last.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final engine = widget.controller.engine;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = math.max(
          200.0,
          constraints.maxWidth - widget.headerWidth,
        );
        // Always leave a little empty room past the end so a clip can be
        // dragged later than the current end of the song.
        final contentWidth = math.max(
          viewportWidth,
          _xFor(project.durationFrames) + viewportWidth * 0.25,
        );

        return ColoredBox(
          color: Palette.well,
          child: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: widget.headerWidth,
                  child: Column(
                    children: [
                      _headerCorner(context),
                      for (final track in project.tracks)
                        TrackHeader(
                          project: project,
                          track: track,
                          height: widget.trackHeight,
                          isSelected: track.id == widget.selectedTrackId,
                          onSelected: () => widget.onTrackSelected(track.id),
                          onGainChanged: (value) => widget.controller.edit(
                            (project) => _setGain(project, track.id, value),
                            coalesce: true,
                          ),
                          onPanChanged: (value) => widget.controller.edit(
                            (project) => _setPan(project, track.id, value),
                            coalesce: true,
                          ),
                          onMuteToggled: (value) => widget.controller.edit(
                            (project) => _setMuted(project, track.id, value),
                          ),
                          onSoloToggled: (value) => widget.controller.edit(
                            (project) => _setSoloed(project, track.id, value),
                          ),
                          onArmToggled: (value) => widget.controller.edit(
                            (project) => _setArmed(project, track.id, value),
                          ),
                          onMenuAction: (action) =>
                              widget.onTrackMenu(track, action),
                        ),
                      if (widget.onAddTrack != null) _addTrackRow(context),
                    ],
                  ),
                ),
                Expanded(
                  child: Scrollbar(
                    controller: _horizontal,
                    child: SingleChildScrollView(
                      controller: _horizontal,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: contentWidth,
                        child: Stack(
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _ruler(context),
                                _loopLane(context),
                                for (final track in project.tracks)
                                  _lane(context, track),
                                if (widget.onAddTrack != null)
                                  const SizedBox(height: _addRowHeight),
                              ],
                            ),
                            _loopHighlight(project),
                            _playhead(engine),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The block above the track headers, level with the ruler.
  Widget _headerCorner(BuildContext context) {
    return Container(
      height: _rulerHeight + _loopLaneHeight,
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        color: Palette.panel,
        border: Border(bottom: BorderSide(color: Palette.line)),
      ),
      child: Text(
        '${widget.project.tracks.length} '
        '${widget.project.tracks.length == 1 ? 'TRACK' : 'TRACKS'}',
        style: EncoreType.panelLabel.copyWith(fontSize: 9.5),
      ),
    );
  }

  /// The ghost row under the last track: somewhere obvious for the arrangement
  /// to grow, rather than an empty half-screen that looks like the end.
  Widget _addTrackRow(BuildContext context) {
    return SizedBox(
      height: _addRowHeight,
      child: Material(
        color: Palette.panel,
        child: InkWell(
          onTap: widget.onAddTrack,
          child: Container(
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Palette.lineFaint),
                left: BorderSide(color: Palette.lineFaint, width: 3),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: Row(
              children: [
                const Icon(
                  Icons.add_rounded,
                  size: 15,
                  color: Palette.textTertiary,
                ),
                const SizedBox(width: Space.sm),
                Text(
                  'Add track',
                  style: EncoreType.textTheme.labelMedium?.copyWith(
                    color: Palette.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------- ruler

  Widget _ruler(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) =>
            widget.controller.seek(_frameAt(details.localPosition.dx)),
        onHorizontalDragUpdate: (details) =>
            widget.controller.seek(_frameAt(details.localPosition.dx)),
        child: Container(
          height: _rulerHeight,
          decoration: const BoxDecoration(
            color: Palette.panel,
            border: Border(bottom: BorderSide(color: Palette.lineFaint)),
          ),
          child: CustomPaint(
            painter: _RulerPainter(
              framesPerPixel: widget.framesPerPixel,
              sampleRate: widget.project.sampleRate,
              step: _gridSeconds,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  /// A thin strip under the ruler where dragging sets the practice loop
  /// (PLAY-04).
  Widget _loopLane(BuildContext context) {
    final hasRegion = widget.project.transport.hasLoopRegion;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (details) {
          _loopAnchorFrame = _frameAt(details.localPosition.dx);
        },
        onHorizontalDragUpdate: (details) {
          final anchor = _loopAnchorFrame;
          if (anchor == null) return;
          widget.controller.setLoopRegion(
            anchor,
            _frameAt(details.localPosition.dx),
          );
        },
        onHorizontalDragEnd: (_) => _loopAnchorFrame = null,
        onDoubleTap: () => widget.controller.setLoopRegion(0, 0),
        child: Container(
          height: _loopLaneHeight,
          alignment: Alignment.centerLeft,
          decoration: const BoxDecoration(
            color: Palette.panel,
            border: Border(bottom: BorderSide(color: Palette.line)),
          ),
          child: hasRegion
              ? null
              : const Padding(
                  padding: EdgeInsets.only(left: Space.sm),
                  child: Text(
                    'Drag here to set a loop',
                    style: TextStyle(
                      fontSize: 9,
                      height: 1,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                      color: Palette.textDisabled,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _loopHighlight(Project project) {
    final transport = project.transport;
    if (!transport.hasLoopRegion) return const SizedBox.shrink();
    final left = _xFor(transport.loopStart);
    final right = _xFor(transport.loopEnd);
    final active = transport.loopEnabled;
    return Positioned(
      left: left,
      top: 0,
      width: math.max(2, right - left),
      bottom: 0,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Palette.ember.withValues(alpha: active ? 0.09 : 0.035),
            border: Border.symmetric(
              vertical: BorderSide(
                color: Palette.ember.withValues(alpha: active ? 0.75 : 0.3),
              ),
            ),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: Container(
              height: _loopLaneHeight,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              alignment: Alignment.center,
              color: Palette.ember.withValues(alpha: active ? 0.9 : 0.35),
              child: Text(
                'LOOP',
                style: TextStyle(
                  fontSize: 8.5,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: active
                      ? const Color(0xFF1A0C05)
                      : Palette.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------- lanes

  Widget _lane(BuildContext context, Track track) {
    final selected = track.id == widget.selectedTrackId;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) {
        widget.onTrackSelected(track.id);
        widget.controller.seek(_frameAt(details.localPosition.dx));
      },
      child: Container(
        height: widget.trackHeight,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF12151A) : Palette.well,
          border: const Border(bottom: BorderSide(color: Palette.lineFaint)),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _GridPainter(
                    framesPerPixel: widget.framesPerPixel,
                    sampleRate: widget.project.sampleRate,
                    step: _gridSeconds,
                  ),
                ),
              ),
            ),
            for (final clip in track.clips) _clip(context, track, clip),
            if (track.clips.isEmpty)
              Center(
                child: Text(
                  track.recordArmed
                      ? 'Armed — press record to capture a take'
                      : 'Empty track',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: track.recordArmed
                        ? Palette.record.withValues(alpha: 0.75)
                        : Palette.textDisabled,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _clip(BuildContext context, Track track, model.Clip clip) {
    final selected = clip.id == widget.selectedClipId;
    final colour = trackColour(track.kind);
    final left = _xFor(clip.timelineStart);
    final width = math.max(2.0, clip.length / widget.framesPerPixel);

    final sampleRate = widget.project.sampleRate;
    final start = framesToDuration(clip.timelineStart, sampleRate);
    final end = framesToDuration(clip.timelineStart + clip.length, sampleRate);

    return Positioned(
      left: left,
      top: 5,
      width: width,
      height: widget.trackHeight - 14,
      child: Semantics(
        // A clip is a coloured rectangle with a waveform in it and nothing
        // else — so where it sits in the song has to be said out loud, or the
        // timeline is unreadable without sight (NFR-A11Y-01).
        label: '${track.name} clip',
        value: '${formatTimecode(start)} to ${formatTimecode(end)}',
        selected: selected,
        button: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              widget.onTrackSelected(track.id);
              widget.onClipSelected(track.id, clip.id);
            },
            onHorizontalDragStart: (_) => _dragFrames = 0,
            onHorizontalDragUpdate: (details) {
              _dragFrames += details.delta.dx * widget.framesPerPixel;
              final whole = _dragFrames.round();
              if (whole == 0) return;
              _dragFrames -= whole;
              widget.controller.edit(
                (project) => _moveClip(project, track.id, clip.id, whole),
                coalesce: true,
              );
            },
            child: AnimatedContainer(
              duration: Motion.instant,
              decoration: BoxDecoration(
                // Flat. A clip is a block of audio; the vertical fade it used
                // to carry made every lane look lit from above by a light
                // that does not exist.
                color: colour.withValues(alpha: selected ? 0.26 : 0.15),
                borderRadius: Radii.allControl,
                border: Border.all(
                  color: selected ? colour : colour.withValues(alpha: 0.45),
                  width: selected ? 1.5 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _ClipWaveform(
                      controller: widget.controller,
                      clip: clip,
                      colour: colour,
                    ),
                  ),
                  // A hairline along the top edge reads as the clip's handle and
                  // makes a run of adjacent clips countable.
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: 2,
                    child: ColoredBox(
                      color: colour.withValues(alpha: selected ? 1 : 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _playhead(AudioEngine engine) {
    return ValueListenableBuilder<TransportState>(
      valueListenable: engine.transport,
      builder: (context, transport, _) {
        final colour = transport.isRecording ? Palette.record : Palette.ember;
        return Positioned(
          left: _xFor(transport.positionFrames) - 6,
          top: 0,
          bottom: 0,
          width: 12,
          child: IgnorePointer(
            child: CustomPaint(painter: _PlayheadPainter(colour: colour)),
          ),
        );
      },
    );
  }

  // Small edit helpers kept here so the widget reads as one unit; they defer
  // to ProjectEdits for the actual transformation.
  static Project _setGain(Project project, String id, double value) =>
      _edit(project, id, (track) => track.copyWith(gain: value));

  static Project _setPan(Project project, String id, double value) =>
      _edit(project, id, (track) => track.copyWith(pan: value));

  static Project _setMuted(Project project, String id, bool value) =>
      _edit(project, id, (track) => track.copyWith(muted: value));

  static Project _setSoloed(Project project, String id, bool value) =>
      _edit(project, id, (track) => track.copyWith(soloed: value));

  static Project _setArmed(Project project, String id, bool value) =>
      _edit(project, id, (track) => track.copyWith(recordArmed: value));

  static Project _edit(
    Project project,
    String trackId,
    Track Function(Track) transform,
  ) {
    final track = project.trackById(trackId);
    if (track == null) return project;
    return project.withTrack(transform(track));
  }

  static Project _moveClip(
    Project project,
    String trackId,
    String clipId,
    int delta,
  ) {
    final track = project.trackById(trackId);
    if (track == null) return project;
    return project.withTrack(
      track.copyWith(
        clips: [
          for (final clip in track.clips)
            if (clip.id == clipId)
              clip.copyWith(
                timelineStart: math.max(0, clip.timelineStart + delta),
              )
            else
              clip,
        ],
      ),
    );
  }
}

/// Loads and draws the envelope for one clip.
class _ClipWaveform extends StatefulWidget {
  const _ClipWaveform({
    required this.controller,
    required this.clip,
    required this.colour,
  });

  final ProjectController controller;
  final model.Clip clip;
  final Color colour;

  @override
  State<_ClipWaveform> createState() => _ClipWaveformState();
}

class _ClipWaveformState extends State<_ClipWaveform> {
  WaveformPeaks _peaks = WaveformPeaks.empty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ClipWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clip.assetId != widget.clip.assetId) _load();
  }

  Future<void> _load() async {
    final peaks = await widget.controller.peaksForAsset(widget.clip.assetId);
    if (mounted) setState(() => _peaks = peaks);
  }

  @override
  Widget build(BuildContext context) {
    return WaveformView(
      peaks: _peaks,
      startFrame: widget.clip.assetOffset,
      endFrame: widget.clip.assetOffset + widget.clip.length,
      colour: widget.colour,
      fadeInFrames: widget.clip.fadeInFrames,
      fadeOutFrames: widget.clip.fadeOutFrames,
    );
  }
}

/// Vertical grid behind the lanes, on the same spacing as the ruler labels.
class _GridPainter extends CustomPainter {
  _GridPainter({
    required this.framesPerPixel,
    required this.sampleRate,
    required this.step,
  });

  final double framesPerPixel;
  final int sampleRate;
  final double step;

  @override
  void paint(Canvas canvas, Size size) {
    final secondsPerPixel = framesPerPixel / sampleRate;
    final spacing = step / secondsPerPixel;
    if (spacing <= 0) return;

    final major = Paint()..color = Colors.white.withValues(alpha: 0.045);
    final minor = Paint()..color = Colors.white.withValues(alpha: 0.02);

    for (var x = 0.0, index = 0; x <= size.width; x += spacing, index++) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height), major);
      final half = x + spacing / 2;
      if (half <= size.width) {
        canvas.drawRect(Rect.fromLTWH(half, 0, 1, size.height), minor);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) =>
      oldDelegate.framesPerPixel != framesPerPixel ||
      oldDelegate.sampleRate != sampleRate ||
      oldDelegate.step != step;
}

/// Time ruler with labels at a spacing that suits the current zoom.
class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.framesPerPixel,
    required this.sampleRate,
    required this.step,
  });

  final double framesPerPixel;
  final int sampleRate;
  final double step;

  @override
  void paint(Canvas canvas, Size size) {
    final secondsPerPixel = framesPerPixel / sampleRate;
    final spacing = step / secondsPerPixel;
    if (spacing <= 0) return;

    final major = Paint()
      ..color = Palette.textTertiary.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    final minor = Paint()
      ..color = Palette.textTertiary.withValues(alpha: 0.22)
      ..strokeWidth = 1;

    var second = 0.0;
    for (var x = 0.0; x <= size.width; x += spacing) {
      canvas.drawLine(
        Offset(x, size.height - 9),
        Offset(x, size.height),
        major,
      );
      // A half-step tick between labels: enough to judge a position by, not
      // enough to turn the ruler into a comb.
      final half = x + spacing / 2;
      if (half <= size.width) {
        canvas.drawLine(
          Offset(half, size.height - 5),
          Offset(half, size.height),
          minor,
        );
      }

      final label = TextPainter(
        text: TextSpan(
          text: formatDuration(Duration(milliseconds: (second * 1000).round())),
          style: const TextStyle(
            color: Palette.textTertiary,
            fontSize: 10,
            height: 1,
            fontWeight: FontWeight.w600,
            fontFeatures: EncoreType.tabular,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(x + 4, 7));
      second += step;
    }
  }

  @override
  bool shouldRepaint(_RulerPainter oldDelegate) =>
      oldDelegate.framesPerPixel != framesPerPixel ||
      oldDelegate.sampleRate != sampleRate ||
      oldDelegate.step != step;
}

/// The playhead: a line with a head at the top, so it can be found at a glance
/// on a timeline several screens wide.
class _PlayheadPainter extends CustomPainter {
  _PlayheadPainter({required this.colour});

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.width / 2;
    canvas.drawRect(
      Rect.fromLTWH(centre - 0.75, 0, 1.5, size.height),
      Paint()..color = colour,
    );

    final head = Path()
      ..moveTo(centre - 5, 0)
      ..lineTo(centre + 5, 0)
      ..lineTo(centre, 9)
      ..close();
    canvas.drawPath(head, Paint()..color = colour);
  }

  @override
  bool shouldRepaint(_PlayheadPainter oldDelegate) =>
      oldDelegate.colour != colour;
}
