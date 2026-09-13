import 'package:flutter/material.dart';

import '../../core/dsp/level_meter.dart';
import '../theme.dart';

/// Peak/RMS meter with a clip warning (REC-07).
///
/// The scale is deliberately non-linear: the top 12 dB gets half the length,
/// because that is the range a performer is actually setting a level in. The
/// body shows RMS — what the level sounds like — and a thin marker shows the
/// peak, which is what will clip.
class LevelMeterBar extends StatelessWidget {
  const LevelMeterBar({
    required this.reading,
    this.orientation = Axis.horizontal,
    this.thickness = 8,
    this.showClipWarning = true,
    super.key,
  });

  final LevelReading reading;
  final Axis orientation;
  final double thickness;
  final bool showClipWarning;

  static const double _floorDb = -54.0;

  /// Maps dBFS onto 0..1 along the meter.
  static double positionFor(double db) {
    if (db <= _floorDb) return 0;
    if (db >= 0) return 1;
    // Two linear segments: -54…-12 dB across the lower half, -12…0 dB across
    // the upper half.
    if (db <= -12) return (db - _floorDb) / (_floorDb.abs() - 12) * 0.5;
    return 0.5 + (db + 12) / 12 * 0.5;
  }

  /// Where the meter changes colour, as a fraction of its length.
  static final double _warnAt = positionFor(-6);
  static final double _hotAt = positionFor(-1);

  /// What the meter is saying, in words (NFR-A11Y-01).
  ///
  /// A meter is pure colour and length, so without this a screen-reader user
  /// setting a level has nothing at all to go on — and the clip warning, which
  /// REC-07 exists to deliver, would be invisible to them. Peak is the number
  /// that matters when setting a level, so it leads.
  String get semanticValue {
    final clipping = showClipWarning && reading.clipped;
    if (reading.peakDb <= _floorDb) {
      return clipping ? 'Clipping. No signal now.' : 'No signal';
    }
    final peak = reading.peakDb.toStringAsFixed(1);
    return clipping
        ? 'Clipping. Peak $peak decibels.'
        : 'Peak $peak decibels';
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = orientation == Axis.horizontal;
    return Semantics(
      label: 'Input level',
      value: semanticValue,
      // Clipping is the one thing here worth interrupting for: it means the
      // take being recorded right now is being damaged.
      liveRegion: showClipWarning && reading.clipped,
      child: ExcludeSemantics(
        child: SizedBox(
          width: horizontal ? null : thickness,
          height: horizontal ? thickness : null,
          child: CustomPaint(
            painter: _MeterPainter(
              rms: positionFor(reading.rmsDb),
              peak: positionFor(reading.peakDb),
              clipped: showClipWarning && reading.clipped,
              horizontal: horizontal,
              thickness: thickness,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter({
    required this.rms,
    required this.peak,
    required this.clipped,
    required this.horizontal,
    required this.thickness,
  });

  final double rms;
  final double peak;
  final bool clipped;
  final bool horizontal;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final extent = horizontal ? size.width : size.height;
    if (extent <= 0) return;
    final radius = Radius.circular(thickness / 2);
    final track = RRect.fromRectAndRadius(Offset.zero & size, radius);

    canvas.drawRRect(track, Paint()..color = Palette.well);
    canvas.drawRRect(
      track,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Palette.lineFaint,
    );

    canvas.save();
    canvas.clipRRect(track);

    // The gradient is painted across the whole track and then clipped to the
    // current level, so a given decibel value always has the same colour
    // rather than the whole bar changing hue as it moves.
    final gradient = LinearGradient(
      begin: horizontal ? Alignment.centerLeft : Alignment.bottomCenter,
      end: horizontal ? Alignment.centerRight : Alignment.topCenter,
      colors: const [Palette.play, Palette.play, Palette.warn, Palette.record],
      stops: [
        0,
        LevelMeterBar._warnAt,
        LevelMeterBar._hotAt,
        1,
      ],
    ).createShader(Offset.zero & size);

    final filled = extent * rms.clamp(0.0, 1.0);
    if (filled > 0) {
      canvas.drawRect(
        horizontal
            ? Rect.fromLTWH(0, 0, filled, size.height)
            : Rect.fromLTWH(0, size.height - filled, size.width, filled),
        Paint()..shader = gradient,
      );
    }

    // Ticks at the two colour boundaries give the eye something to aim at.
    final tick = Paint()..color = Colors.black.withValues(alpha: 0.35);
    for (final position in [LevelMeterBar._warnAt, LevelMeterBar._hotAt]) {
      final offset = extent * position;
      canvas.drawRect(
        horizontal
            ? Rect.fromLTWH(offset, 0, 1, size.height)
            : Rect.fromLTWH(0, size.height - offset, size.width, 1),
        tick,
      );
    }

    final peakOffset = (extent * peak.clamp(0.0, 1.0) - 2).clamp(0.0, extent);
    if (peak > 0) {
      canvas.drawRect(
        horizontal
            ? Rect.fromLTWH(peakOffset, 0, 2, size.height)
            : Rect.fromLTWH(0, size.height - peakOffset - 2, size.width, 2),
        Paint()..shader = gradient,
      );
    }

    if (clipped) {
      canvas.drawRect(
        horizontal
            ? Rect.fromLTWH(size.width - 4, 0, 4, size.height)
            : Rect.fromLTWH(0, 0, size.width, 4),
        Paint()..color = Palette.record,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_MeterPainter oldDelegate) =>
      oldDelegate.rms != rms ||
      oldDelegate.peak != peak ||
      oldDelegate.clipped != clipped ||
      oldDelegate.horizontal != horizontal ||
      oldDelegate.thickness != thickness;
}
