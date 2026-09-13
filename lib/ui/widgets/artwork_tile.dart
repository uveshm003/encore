import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A stand-in cover for a song or project.
///
/// There is no artwork to show — nothing is fetched, and the tags in a file
/// are not read — so the tile is generated from the title instead. The same
/// song gets the same colours and the same little waveform every time, which
/// is enough for the eye to find a row it has seen before.
class ArtworkTile extends StatelessWidget {
  const ArtworkTile({
    required this.seed,
    this.size = 52,
    this.icon,
    this.badge,
    super.key,
  });

  /// Anything stable about the item — its title or id.
  final String seed;
  final double size;

  /// Drawn over the pattern when the item is a kind rather than a song.
  final IconData? icon;

  /// A small marker in the corner, used for the record dot on a project.
  final Widget? badge;

  /// The colour a given seed always lands on.
  static Color colourFor(String seed) {
    const palette = [
      Palette.ember,
      Palette.trackInstrumental,
      Palette.trackBass,
      Palette.trackOther,
      Palette.trackDrums,
      Palette.trackRecording,
    ];
    if (seed.isEmpty) return palette.first;
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7FFFFFFF;
    }
    return palette[hash % palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final colour = colourFor(seed);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            // A strip of coloured tape with the song's signature printed on
            // it. Flat stock colour, square corners: the two-tone diagonal
            // sheen it used to carry made every row look like an app icon.
            decoration: BoxDecoration(
              color: Color.lerp(colour, Palette.base, 0.58),
              borderRadius: Radii.allControl,
            ),
            clipBehavior: Clip.antiAlias,
            child: icon != null
                ? Icon(icon, size: size * 0.38, color: colour)
                : CustomPaint(painter: _SignaturePainter(seed: seed)),
          ),
          if (badge != null)
            Positioned(right: -2, bottom: -2, child: badge!),
        ],
      ),
    );
  }
}

/// Draws a short waveform whose shape is decided by the seed.
class _SignaturePainter extends CustomPainter {
  _SignaturePainter({required this.seed});

  final String seed;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed.hashCode);
    const bars = 7;
    final barWidth = size.width * 0.062;
    final gap = (size.width * 0.68 - bars * barWidth) / (bars - 1);
    var x = size.width * 0.16;
    final centre = size.height / 2;
    final paint = Paint()..color = Colors.black.withValues(alpha: 0.42);

    for (var index = 0; index < bars; index++) {
      final height =
          size.height * (0.18 + random.nextDouble() * 0.44);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, centre - height / 2, barWidth, height),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
      x += barWidth + gap;
    }
  }

  @override
  bool shouldRepaint(_SignaturePainter oldDelegate) => oldDelegate.seed != seed;
}
