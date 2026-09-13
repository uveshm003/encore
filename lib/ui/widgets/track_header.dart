import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../project/models/project.dart';
import '../../project/models/track.dart';
import '../theme.dart';

/// Colour a track is drawn in, chosen by what it holds.
Color trackColour(TrackKind kind) => switch (kind) {
  TrackKind.vocals => Palette.trackVocals,
  TrackKind.instrumental => Palette.trackInstrumental,
  TrackKind.drums => Palette.trackDrums,
  TrackKind.bass => Palette.trackBass,
  TrackKind.other => Palette.trackOther,
  TrackKind.recording => Palette.trackRecording,
  TrackKind.reference => Palette.trackReference,
};

/// The per-track controls beside each lane (PLAY-03, MIX-01, REC-01).
class TrackHeader extends StatelessWidget {
  const TrackHeader({
    required this.project,
    required this.track,
    required this.height,
    required this.onGainChanged,
    required this.onPanChanged,
    required this.onMuteToggled,
    required this.onSoloToggled,
    required this.onArmToggled,
    required this.onMenuAction,
    this.isSelected = false,
    this.onSelected,
    super.key,
  });

  final Project project;
  final Track track;
  final double height;
  final bool isSelected;
  final ValueChanged<double> onGainChanged;
  final ValueChanged<double> onPanChanged;
  final ValueChanged<bool> onMuteToggled;
  final ValueChanged<bool> onSoloToggled;
  final ValueChanged<bool> onArmToggled;
  final ValueChanged<TrackMenuAction> onMenuAction;
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = trackColour(track.kind);
    final silenced = !project.isAudible(track);

    return GestureDetector(
      onTap: onSelected,
      child: AnimatedContainer(
        duration: Motion.fast,
        height: height,
        padding: const EdgeInsets.fromLTRB(
          Space.md,
          Space.sm,
          Space.sm,
          Space.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected ? Palette.overlay : Palette.panel,
          border: Border(
            bottom: const BorderSide(color: Palette.lineFaint),
            left: BorderSide(
              color: silenced ? colour.withValues(alpha: 0.35) : colour,
              width: 3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    track.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: silenced
                          ? Palette.textTertiary
                          : Palette.textPrimary,
                    ),
                  ),
                ),
                if (track.takes.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(right: Space.xs),
                    child: Text(
                      '${track.takes.length} takes',
                      style: EncoreType.numeric.copyWith(
                        fontSize: 10,
                        color: Palette.textTertiary,
                      ),
                    ),
                  ),
                _menu(context),
              ],
            ),
            const SizedBox(height: Space.sm),
            Row(
              children: [
                _ToggleGroup(
                  children: [
                    _Toggle(
                      label: 'M',
                      tooltip: 'Mute',
                      active: track.muted,
                      activeColour: Palette.warn,
                      onChanged: onMuteToggled,
                    ),
                    _Toggle(
                      label: 'S',
                      tooltip: 'Solo',
                      active: track.soloed,
                      activeColour: Palette.play,
                      onChanged: onSoloToggled,
                    ),
                    _Toggle(
                      label: '●',
                      tooltip: 'Arm for recording',
                      active: track.recordArmed,
                      activeColour: Palette.record,
                      onChanged: onArmToggled,
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  _kindLabel(track.kind),
                  style: EncoreType.panelLabel.copyWith(
                    fontSize: 9,
                    color: colour.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
            const Spacer(),
            _fader(
              context,
              icon: Icons.volume_up_rounded,
              tooltip: 'Level',
              colour: colour,
              value: track.gain.clamp(0.0, 2.0),
              max: 2.0,
              readout: _gainLabel(track.gain),
              onChanged: onGainChanged,
            ),
            _fader(
              context,
              icon: Icons.settings_ethernet_rounded,
              tooltip: 'Pan',
              colour: colour.withValues(alpha: 0.6),
              value: track.pan.clamp(-1.0, 1.0),
              min: -1.0,
              readout: _panLabel(track.pan),
              onChanged: onPanChanged,
            ),
          ],
        ),
      ),
    );
  }

  /// A slider trimmed down to fit the header's height, with its value beside
  /// it: setting a level by eye is guesswork without a number.
  ///
  /// The default Slider reserves room for its touch overlay, which is taller
  /// than a track lane; the overlay is removed and the thumb shrunk so two
  /// faders and the buttons all fit without the row overflowing.
  Widget _fader(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required Color colour,
    required double value,
    required String readout,
    required ValueChanged<double> onChanged,
    double min = 0.0,
    double max = 1.0,
  }) {
    return SizedBox(
      height: 21,
      child: Row(
        children: [
          Tooltip(
            message: tooltip,
            child: Icon(icon, size: 13, color: Palette.textTertiary),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: SliderComponentShape.noOverlay,
                activeTrackColor: colour,
                inactiveTrackColor: Palette.inset,
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 38,
            child: Text(
              readout,
              textAlign: TextAlign.right,
              style: EncoreType.numeric.copyWith(
                fontSize: 10,
                color: Palette.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _menu(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 22,
      child: PopupMenuButton<TrackMenuAction>(
        tooltip: 'Track options',
        padding: EdgeInsets.zero,
        iconSize: 16,
        icon: const Icon(Icons.more_horiz_rounded, color: Palette.textTertiary),
        onSelected: onMenuAction,
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: TrackMenuAction.rename,
            child: Text('Rename'),
          ),
          if (track.takes.isNotEmpty)
            const PopupMenuItem(
              value: TrackMenuAction.chooseTake,
              child: Text('Choose take…'),
            ),
          const PopupMenuItem(
            value: TrackMenuAction.duplicate,
            child: Text('Duplicate'),
          ),
          const PopupMenuItem(
            value: TrackMenuAction.delete,
            child: Text(
              'Delete track',
              style: TextStyle(color: Palette.record),
            ),
          ),
        ],
      ),
    );
  }

  static String _kindLabel(TrackKind kind) => switch (kind) {
    TrackKind.vocals => 'VOX',
    TrackKind.instrumental => 'INST',
    TrackKind.drums => 'DRUMS',
    TrackKind.bass => 'BASS',
    TrackKind.other => 'OTHER',
    TrackKind.recording => 'TAKE',
    TrackKind.reference => 'REF',
  };

  /// Amplitude shown the way a mixer shows it.
  static String _gainLabel(double gain) {
    if (gain <= 0.001) return '−∞';
    final db = 20 * (math.log(gain) / math.ln10);
    return '${db >= 0 ? '+' : ''}${db.toStringAsFixed(1)}';
  }

  static String _panLabel(double pan) {
    if (pan.abs() < 0.02) return 'C';
    final amount = (pan.abs() * 100).round();
    return '${pan < 0 ? 'L' : 'R'}$amount';
  }
}

/// Mute, solo and arm, kept together in one recessed group.
class _ToggleGroup extends StatelessWidget {
  const _ToggleGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      // A bank of keys cut into the panel: one well, hairlines between the
      // keys, no gaps. Separate rounded buttons floating side by side is a
      // toolbar; a continuous bank is a mixer strip.
      decoration: const BoxDecoration(color: Palette.well),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.activeColour,
    required this.onChanged,
  });

  final String label;
  final String tooltip;
  final bool active;
  final Color activeColour;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        toggled: active,
        button: true,
        label: tooltip,
        child: InkWell(
          onTap: () => onChanged(!active),
          child: AnimatedContainer(
            duration: Motion.instant,
            width: 24,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // Lit key when engaged, dark key when not. The legend goes to
              // near-black on the lit key so it reads as printed on the cap
              // rather than glowing through it.
              color: active ? activeColour : Palette.panel,
              border: const Border(
                right: BorderSide(color: Palette.well, width: 1),
              ),
            ),
            child: Text(
              label,
              style: EncoreType.control.copyWith(
                color: active ? Palette.base : Palette.textTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Actions offered in a track's overflow menu.
enum TrackMenuAction { rename, chooseTake, duplicate, delete }
