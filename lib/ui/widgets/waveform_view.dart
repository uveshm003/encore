import 'package:flutter/material.dart';

import '../../core/waveform.dart';

/// Draws a waveform from a pre-computed envelope (UI-01).
///
/// The widget only ever reduces [WaveformPeaks] down to one min/max pair per
/// pixel column, so drawing cost depends on the width of the view rather than
/// on the length of the audio — panning and zooming a five-minute song is the
/// same amount of work as a five-second one.
///
/// The envelope is filled rather than drawn as separate bars: a filled body
/// reads as one continuous sound, which is what a clip is, and it survives
/// being scaled down to a lane a few pixels tall.
class WaveformView extends StatelessWidget {
  const WaveformView({
    required this.peaks,
    required this.startFrame,
    required this.endFrame,
    required this.colour,
    this.fadeInFrames = 0,
    this.fadeOutFrames = 0,
    super.key,
  });

  final WaveformPeaks peaks;

  /// Frame range of the *asset* to draw.
  final int startFrame;
  final int endFrame;
  final Color colour;

  /// Fade lengths drawn as an overlay so edits are visible (EDIT-02).
  final int fadeInFrames;
  final int fadeOutFrames;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _WaveformPainter(
        peaks: peaks,
        startFrame: startFrame,
        endFrame: endFrame,
        colour: colour,
        fadeInFrames: fadeInFrames,
        fadeOutFrames: fadeOutFrames,
      ),
      isComplex: true,
      willChange: false,
      child: const SizedBox.expand(),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.peaks,
    required this.startFrame,
    required this.endFrame,
    required this.colour,
    required this.fadeInFrames,
    required this.fadeOutFrames,
  });

  final WaveformPeaks peaks;
  final int startFrame;
  final int endFrame;
  final Color colour;
  final int fadeInFrames;
  final int fadeOutFrames;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final columns = size.width.floor();
    if (columns <= 0) return;

    final centre = size.height / 2;
    final half = size.height / 2 - 2;

    if (peaks.isEmpty) {
      // No envelope yet: a centre line reads as "loading", not as silence.
      canvas.drawLine(
        Offset(0, centre),
        Offset(size.width, centre),
        Paint()
          ..color = colour.withValues(alpha: 0.25)
          ..strokeWidth = 1,
      );
      return;
    }

    final envelope = peaks.envelopeFor(
      columns: columns,
      startFrame: startFrame,
      endFrame: endFrame,
    );
    if (envelope.length == 0) return;

    final frames = endFrame - startFrame;
    final top = Path()..moveTo(0, centre);
    final bottom = <Offset>[];

    for (var column = 0; column < envelope.length; column++) {
      final position = frames <= 0
          ? 0.0
          : column / envelope.length * frames;
      final gain = _fadeGain(position, frames);
      final high = (envelope.highs[column] * gain).clamp(-1.0, 1.0);
      final low = (envelope.lows[column] * gain).clamp(-1.0, 1.0);
      final x = column + 0.5;
      top.lineTo(x, centre - high * half);
      bottom.add(Offset(x, centre - low * half));
    }

    // Close the shape by walking the lower envelope back to the start.
    for (final point in bottom.reversed) {
      top.lineTo(point.dx, point.dy);
    }
    top.close();

    canvas.drawPath(
      top,
      Paint()..color = colour,
    );

    // A dimmer centre line keeps quiet passages visible, where the filled
    // body collapses to nothing.
    canvas.drawLine(
      Offset(0, centre),
      Offset(size.width, centre),
      Paint()
        ..color = colour.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );
  }

  double _fadeGain(double position, int frames) {
    var gain = 1.0;
    if (fadeInFrames > 0 && position < fadeInFrames) {
      gain *= position / fadeInFrames;
    }
    if (fadeOutFrames > 0) {
      final remaining = frames - position;
      if (remaining < fadeOutFrames) gain *= remaining / fadeOutFrames;
    }
    return gain.clamp(0.0, 1.0);
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) {
    return oldDelegate.peaks != peaks ||
        oldDelegate.startFrame != startFrame ||
        oldDelegate.endFrame != endFrame ||
        oldDelegate.colour != colour ||
        oldDelegate.fadeInFrames != fadeInFrames ||
        oldDelegate.fadeOutFrames != fadeOutFrames;
  }
}
