import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/brand.dart';
import '../widgets/primitives.dart';

/// A short explanation of the core flow (UI-04).
///
/// Shown once on first launch and available again from the toolbar. It covers
/// the four steps the app exists for and, just as importantly, says plainly
/// that nothing leaves the device.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _steps = [
    _Step(
      art: _ArtMode.imported,
      icon: Icons.library_add_rounded,
      title: 'Import a song',
      body:
          'Pick any track on this device — MP3, WAV, FLAC, AAC and more. '
          'Encore keeps its own working copy and never changes your '
          'original file.',
    ),
    _Step(
      art: _ArtMode.separated,
      icon: Icons.auto_awesome_rounded,
      title: 'Remove the vocals',
      body:
          'Encore separates the lead vocal from the backing right here on '
          'your device. It takes a minute or two, runs once per song, and the '
          'result is saved so you never wait for it twice.',
    ),
    _Step(
      art: _ArtMode.recorded,
      icon: Icons.mic_rounded,
      title: 'Sing over it',
      body:
          'Arm a track, press record and perform. There is a count-in and a '
          'click if you want them, and Encore lines your take up with the '
          'backing automatically. Record as many takes as you like and keep '
          'the best one.',
    ),
    _Step(
      art: _ArtMode.mixed,
      icon: Icons.ios_share_rounded,
      title: 'Mix and export',
      body:
          'Balance the levels, trim and fade what you recorded, then export '
          'one mixed file — or every track separately if you want to finish '
          'somewhere else.',
    ),
  ];

  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isLast => _page == _steps.length - 1;

  void _next() {
    if (_isLast) {
      Navigator.of(context).maybePop();
    } else {
      _controller.nextPage(duration: Motion.base, curve: Motion.standard);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Palette.base,
      body: AppGround(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.xxl,
                  Space.lg,
                  Space.xxl,
                  Space.xxl,
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const EncoreWordmark(markSize: 22),
                        const Spacer(),
                        Text(
                          '${_page + 1} of ${_steps.length}',
                          style: EncoreType.numeric,
                        ),
                      ],
                    ),
                    Expanded(
                      child: PageView.builder(
                        controller: _controller,
                        itemCount: _steps.length,
                        onPageChanged: (index) => setState(() => _page = index),
                        itemBuilder: (context, index) => _steps[index],
                      ),
                    ),
                    const SizedBox(height: Space.xl),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var index = 0; index < _steps.length; index++)
                          AnimatedContainer(
                            duration: Motion.base,
                            curve: Motion.standard,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width: index == _page ? 20 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: index == _page
                                  ? Palette.ember
                                  : Palette.lineStrong,
                              borderRadius: Radii.allControl,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: Space.xxl),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          child: Text(_isLast ? 'Close' : 'Skip'),
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: _next,
                          iconAlignment: IconAlignment.end,
                          icon: Icon(
                            _isLast
                                ? Icons.check_rounded
                                : Icons.arrow_forward_rounded,
                            size: 18,
                          ),
                          label: Text(_isLast ? 'Get started' : 'Next'),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.xl),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.lock_outline_rounded,
                          size: 13,
                          color: Palette.aqua,
                        ),
                        const SizedBox(width: Space.sm),
                        Flexible(
                          child: Text(
                            'Everything happens on this device. No account, no '
                            'uploads, no internet needed.',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Palette.textTertiary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.art,
    required this.icon,
    required this.title,
    required this.body,
  });

  final _ArtMode art;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SurfacePanel(
          padding: const EdgeInsets.all(Space.lg),
          borderRadius: Radii.allPanel,
          colour: Palette.well,
          child: SizedBox(
            height: 132,
            width: double.infinity,
            child: CustomPaint(painter: _StepArtPainter(mode: art)),
          ),
        ),
        const SizedBox(height: Space.xxl),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Palette.ember.withValues(alpha: 0.14),
                borderRadius: Radii.allControl,
              ),
              child: Icon(icon, size: 16, color: Palette.ember),
            ),
            const SizedBox(width: Space.md),
            Flexible(
              child: Text(title, style: theme.textTheme.headlineSmall),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        Text(
          body,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Palette.textSecondary,
            height: 1.55,
          ),
        ),
      ],
    );
  }
}

/// Which stage of the flow the illustration shows.
enum _ArtMode { imported, separated, recorded, mixed }

/// Draws the same song at four stages, so flipping through the steps reads as
/// one thing happening rather than four unrelated pictures.
class _StepArtPainter extends CustomPainter {
  _StepArtPainter({required this.mode});

  final _ArtMode mode;

  /// A fixed pseudo-waveform: the same shape on every page and every launch.
  static final List<double> _shape = List<double>.generate(64, (index) {
    final random = math.Random(index * 977 + 13);
    final envelope = math.sin(index / 63 * math.pi);
    return (0.25 + 0.75 * random.nextDouble()) * (0.35 + 0.65 * envelope);
  });

  @override
  void paint(Canvas canvas, Size size) {
    switch (mode) {
      case _ArtMode.imported:
        _lane(canvas, size, top: 0.22, height: 0.56, colour: Palette.ember);
      case _ArtMode.separated:
        _lane(
          canvas,
          size,
          top: 0.04,
          height: 0.38,
          colour: Palette.ember,
          alpha: 0.28,
          strike: true,
        );
        _lane(
          canvas,
          size,
          top: 0.56,
          height: 0.40,
          colour: Palette.trackInstrumental,
        );
      case _ArtMode.recorded:
        _lane(
          canvas,
          size,
          top: 0.04,
          height: 0.38,
          colour: Palette.trackInstrumental,
        );
        _lane(
          canvas,
          size,
          top: 0.56,
          height: 0.40,
          colour: Palette.record,
          fraction: 0.62,
        );
      case _ArtMode.mixed:
        _lane(
          canvas,
          size,
          top: 0.02,
          height: 0.26,
          colour: Palette.trackInstrumental,
          alpha: 0.5,
        );
        _lane(
          canvas,
          size,
          top: 0.35,
          height: 0.26,
          colour: Palette.trackRecording,
          alpha: 0.5,
        );
        _lane(canvas, size, top: 0.70, height: 0.28, colour: Palette.ember);
    }
  }

  /// One waveform lane inside a rounded well.
  void _lane(
    Canvas canvas,
    Size size, {
    required double top,
    required double height,
    required Color colour,
    double alpha = 1,
    double fraction = 1,
    bool strike = false,
  }) {
    final rect = Rect.fromLTWH(
      0,
      size.height * top,
      size.width,
      size.height * height,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.drawRRect(
      rrect,
      Paint()..color = colour.withValues(alpha: 0.08 * alpha),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colour.withValues(alpha: 0.22 * alpha),
    );

    final centre = rect.center.dy;
    final half = rect.height / 2 - 6;
    final bars = _shape.length;
    final step = rect.width / bars;
    final paint = Paint()
      ..color = colour.withValues(alpha: 0.9 * alpha)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1.6, step * 0.42);

    for (var index = 0; index < (bars * fraction).round(); index++) {
      final x = rect.left + step * (index + 0.5);
      final extent = half * _shape[index];
      canvas.drawLine(
        Offset(x, centre - extent),
        Offset(x, centre + extent),
        paint,
      );
    }

    if (strike) {
      // The vocal lane on the separation step is shown crossed through: that
      // is the part being taken away.
      canvas.drawLine(
        Offset(rect.left + 10, centre),
        Offset(rect.right - 10, centre),
        Paint()
          ..color = colour.withValues(alpha: 0.85)
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_StepArtPainter oldDelegate) => oldDelegate.mode != mode;
}
