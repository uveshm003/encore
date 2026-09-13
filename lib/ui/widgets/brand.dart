import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// The Encore mark: a lit squircle with a level-meter silhouette cut out of it.
///
/// The same shape is drawn at every size the app needs — a 20 px badge in the
/// app bar, a 96 px hero on the splash — so it is painted rather than shipped
/// as a bitmap. The generated launcher icons use the same geometry.
class EncoreMark extends StatelessWidget {
  const EncoreMark({this.size = 28, this.animate = false, super.key});

  final double size;

  /// Whether the bars breathe. Used on the splash and the empty library, where
  /// there is nothing else moving; never in a list.
  final bool animate;

  /// The bar rhythm of the mark, as fractions of the mark's height.
  static const List<double> bars = [0.34, 0.72, 0.50, 0.90, 0.42];

  @override
  Widget build(BuildContext context) {
    // The mark carries itself. It used to sit on an ember halo, which is the
    // logo equivalent of a drop shadow on text.
    return _MarkBody(size: size, animate: animate);
  }
}

class _MarkBody extends StatefulWidget {
  const _MarkBody({required this.size, required this.animate});

  final double size;
  final bool animate;

  @override
  State<_MarkBody> createState() => _MarkBodyState();
}

class _MarkBodyState extends State<_MarkBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.ambient,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _controller.repeat();
  }

  @override
  void didUpdateWidget(_MarkBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.animate && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          size: Size.square(widget.size),
          painter: EncoreMarkPainter(
            phase: widget.animate ? _controller.value : null,
          ),
        ),
      ),
    );
  }
}

/// Paints the mark. Exposed so the splash and the icon generator share it.
class EncoreMarkPainter extends CustomPainter {
  const EncoreMarkPainter({this.phase});

  /// 0..1 around the breathing cycle, or null for the static shape.
  final double? phase;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // Near-square, like a stamped plate rather than an app icon. The mark used
    // to be a diagonal three-stop gradient with a white highlight along the
    // top — a lit glass tile, which is the single most generic thing a piece
    // of software can have for a logo. One flat colour, and the bars do the
    // work.
    final radius = Radius.circular(size.width * 0.08);
    final body = RRect.fromRectAndRadius(rect, radius);

    canvas.drawRRect(body, Paint()..color = Palette.ember);

    final bars = EncoreMark.bars;
    final barWidth = size.width * 0.086;
    final gap = size.width * 0.062;
    final totalWidth = bars.length * barWidth + (bars.length - 1) * gap;
    var x = (size.width - totalWidth) / 2;
    final centre = size.height / 2;
    final ink = Paint()..color = const Color(0xFF23100A);

    for (var index = 0; index < bars.length; index++) {
      var fraction = bars[index];
      if (phase != null) {
        // Each bar runs the same cycle a little behind the last, so the mark
        // reads as one moving signal rather than five blinking lights.
        final offset = phase! + index * 0.13;
        fraction *= 0.72 + 0.28 * (0.5 + 0.5 * math.sin(offset * 2 * math.pi));
      }
      final height = size.height * 0.62 * fraction.clamp(0.12, 1.0);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, centre - height / 2, barWidth, height),
          Radius.circular(barWidth / 2),
        ),
        ink,
      );
      x += barWidth + gap;
    }
  }

  @override
  bool shouldRepaint(EncoreMarkPainter oldDelegate) =>
      oldDelegate.phase != phase;
}

/// The mark beside the name, for the app bar and the splash.
class EncoreWordmark extends StatelessWidget {
  const EncoreWordmark({
    this.markSize = 26,
    this.animate = false,
    this.style,
    super.key,
  });

  final double markSize;
  final bool animate;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        EncoreMark(size: markSize, animate: animate),
        const SizedBox(width: Space.md),
        Text('Encore', style: style ?? EncoreType.wordmark),
      ],
    );
  }
}

/// The badge that says the app has no network side.
///
/// It appears on the library header, the onboarding and the settings screen —
/// the three places where someone might reasonably wonder where their audio is
/// going.
class OfflineBadge extends StatelessWidget {
  const OfflineBadge({this.label = 'On device', super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(Space.sm, 4, Space.md, 4),
      decoration: BoxDecoration(
        color: Palette.aqua.withValues(alpha: 0.12),
        borderRadius: Radii.allControl,
        border: Border.all(color: Palette.aqua.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline_rounded, size: 12, color: Palette.aqua),
          const SizedBox(width: Space.xs),
          Text(
            label,
            style: EncoreType.textTheme.labelSmall?.copyWith(
              color: Palette.aqua,
              fontSize: 10.5,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
