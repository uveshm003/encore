import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../library/media_item.dart';
import '../../separation/separation_model.dart';
import '../../separation/separation_service.dart';
import '../../separation/stem_cache.dart';
import '../../separation/stem_kind.dart';
import '../../storage/storage_guard.dart';
import '../theme.dart';
import '../widgets/artwork_tile.dart';
import '../widgets/primitives.dart';

/// What the separation screen hands back when it finishes.
class SeparationOutcome {
  const SeparationOutcome(this.stems);

  final CachedStems stems;
}

/// Choose how to separate a song, then watch it happen (SEP-01, SEP-04…06).
///
/// Separation is a one-time batch step, not something that happens during
/// playback, so it gets a screen of its own: pick the trade-off, see how far
/// along it is, and stop it if it is taking too long.
class SeparationScreen extends StatefulWidget {
  const SeparationScreen({required this.item, super.key});

  final MediaItem item;

  @override
  State<SeparationScreen> createState() => _SeparationScreenState();
}

class _SeparationScreenState extends State<SeparationScreen> {
  late SeparationModel _model;
  late bool _fourStem;
  bool _initialised = false;

  SeparationJob? _job;
  StreamSubscription<SeparationProgress>? _subscription;
  SeparationProgress? _progress;
  String? _failure;
  CachedStems? _cached;
  final Map<String, ModelAvailability> _availability = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Inherited widgets cannot be read from initState; this is the first
    // callback where the services scope is available.
    if (_initialised) return;
    _initialised = true;
    final settings = ServicesScope.of(context).settings;
    _model = settings.separationModel;
    _fourStem = settings.fourStemSeparation;
    _loadAvailability();
    _checkCache();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  AppServices get _services => ServicesScope.of(context);

  Set<StemKind> get _stems => _fourStem ? StemKind.fourStem : StemKind.twoStem;

  Future<void> _loadAvailability() async {
    for (final model in SeparationCatalog.all) {
      final availability = await _services.separation.availabilityOf(model);
      if (!mounted) return;
      setState(() => _availability[model.id] = availability);
    }
  }

  Future<void> _checkCache() async {
    final cached = await _services.separation.cached(
      sourceKey: widget.item.sourceKey,
      model: _model,
      stems: _stems,
    );
    if (mounted) setState(() => _cached = cached);
  }

  /// Checks the disk before committing to a job that can run for minutes
  /// (NFR-RES-02), and lets the user decide when it is merely tight.
  ///
  /// Returns false only when the user backs out, or when there is genuinely
  /// not enough room. A platform that will not report free space reads as
  /// "proceed", so this can never stop a separation on a failed query.
  Future<bool> _confirmStorage() async {
    final required = StorageGuard.separationEstimate(
      frameCount: widget.item.frameCount,
      channelCount: widget.item.channelCount,
      stemCount: _stems.length,
    );
    final check = await StorageGuard(_services.paths).check(required);
    if (!check.shouldWarn || !mounted) return true;

    final free = check.freeBytes;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          check.isBlocking ? 'Not enough space' : 'Storage is nearly full',
        ),
        content: Text(
          check.isBlocking
              ? 'Separating this song needs about '
                    '${formatBytes(check.requiredBytes)}, and there '
                    '${free == null ? 'may not be' : 'is only ${formatBytes(free)}'} '
                    'free. Clear some space — the stem cache in Settings is '
                    'the first place to look — and try again.'
              : 'Separating this song needs about '
                    '${formatBytes(check.requiredBytes)}, which would use '
                    'nearly all the space left on this device. You can carry '
                    'on, but it may be worth clearing the stem cache first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(check.isBlocking ? 'Close' : 'Cancel'),
          ),
          if (!check.isBlocking)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Separate anyway'),
            ),
        ],
      ),
    );
    return proceed ?? false;
  }

  Future<void> _start() async {
    if (!await _confirmStorage()) return;
    if (!mounted) return;

    setState(() {
      _failure = null;
      _progress = const SeparationProgress(
        state: SeparationState.queued,
        fraction: 0,
        message: 'Starting',
      );
    });

    await _services.settings.setSeparationModel(_model);
    await _services.settings.setFourStemSeparation(_fourStem);

    final job = await _services.separation.separate(
      sourceWavPath: _services.library.audioPathFor(widget.item),
      sourceKey: widget.item.sourceKey,
      model: _model,
      stems: _stems,
      title: widget.item.title,
    );
    if (!mounted) return;
    setState(() => _job = job);

    _subscription = job.updates.listen((progress) {
      if (mounted) setState(() => _progress = progress);
    });

    try {
      final stems = await job.result;
      if (mounted) Navigator.of(context).pop(SeparationOutcome(stems));
    } on SeparationCancelledException {
      if (mounted) {
        setState(() {
          _job = null;
          _progress = null;
        });
      }
    } on SeparationFailure catch (failure) {
      if (mounted) {
        setState(() {
          _job = null;
          _progress = null;
          _failure = failure.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = _job != null && !(_job?.isFinished ?? true);

    return Scaffold(
      backgroundColor: Palette.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(running ? 'Separating' : 'Set up'),
      ),
      body: AppGround(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              Space.xxl,
              Space.sm,
              Space.xxl,
              Space.huge,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _songHeader(theme),
                  const SizedBox(height: Space.xxl),
                  if (running)
                    _RunningPanel(
                      progress: _progress,
                      onCancel: () => _job?.cancel(),
                    )
                  else ...[
                    Text(
                      'Remove the vocals',
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: Space.sm),
                    Text(
                      'This runs entirely on this device. Nothing is uploaded, '
                      'and the result is saved so the same song never has to '
                      'be separated twice.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Palette.textSecondary,
                      ),
                    ),
                    const SizedBox(height: Space.xxl),
                    const SectionHeader(
                      title: 'Parts',
                      padding: EdgeInsets.only(
                        left: Space.xs,
                        bottom: Space.md,
                      ),
                    ),
                    _stemChoice(),
                    const SizedBox(height: Space.xl),
                    const SectionHeader(
                      title: 'Quality',
                      padding: EdgeInsets.only(
                        left: Space.xs,
                        bottom: Space.md,
                      ),
                    ),
                    _modelChoice(theme),
                    if (_failure != null) ...[
                      const SizedBox(height: Space.lg),
                      _failureCard(theme, _failure!),
                    ],
                    if (_cached != null) ...[
                      const SizedBox(height: Space.lg),
                      _cachedNote(theme),
                    ],
                    const SizedBox(height: Space.xxl),
                    FilledButton.icon(
                      onPressed: _canStart ? _start : null,
                      icon: Icon(
                        _cached != null
                            ? Icons.bolt_rounded
                            : Icons.auto_awesome_rounded,
                        size: 18,
                      ),
                      label: Text(
                        _cached != null
                            ? 'Use the saved separation'
                            : 'Separate this song',
                      ),
                    ),
                    if (_cached == null) ...[
                      const SizedBox(height: Space.md),
                      Text(
                        'A ${formatDuration(widget.item.duration)} song usually '
                        'takes a minute or two. You can cancel at any point.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Palette.textTertiary,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _songHeader(ThemeData theme) {
    return Row(
      children: [
        ArtworkTile(seed: widget.item.title, size: 48),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  MetaChip(
                    label: formatDuration(widget.item.duration),
                    icon: Icons.schedule_rounded,
                  ),
                  const SizedBox(width: Space.xs),
                  MetaChip(label: widget.item.sourceFormat.displayName),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  bool get _canStart {
    final availability = _availability[_model.id];
    return availability == null || availability.isAvailable;
  }

  Widget _stemChoice() {
    final fourStemSupported = _model.supports(StemKind.fourStem);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cards = [
          _OptionCard(
            selected: !_fourStem,
            enabled: true,
            icon: Icons.splitscreen_rounded,
            title: 'Vocals and instrumental',
            body:
                'Two tracks: the backing to sing over, plus the original '
                'vocal for reference.',
            onSelected: () => _setFourStem(false),
          ),
          _OptionCard(
            selected: _fourStem,
            enabled: fourStemSupported,
            icon: Icons.grid_view_rounded,
            title: 'Four parts',
            body: fourStemSupported
                ? 'Vocals, drums, bass and everything else, on separate '
                      'tracks. Slower.'
                : '${_model.name} only produces two parts.',
            onSelected: () => _setFourStem(true),
          ),
        ];
        if (constraints.maxWidth < 460) {
          return Column(
            children: [
              cards[0],
              const SizedBox(height: Space.sm),
              cards[1],
            ],
          );
        }
        // IntrinsicHeight so the two cards match height even though their
        // descriptions are different lengths; the Row is inside a scroll view,
        // which cannot give a stretching child a height on its own.
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: cards[0]),
              const SizedBox(width: Space.sm),
              Expanded(child: cards[1]),
            ],
          ),
        );
      },
    );
  }

  void _setFourStem(bool value) {
    setState(() => _fourStem = value);
    _checkCache();
  }

  Widget _modelChoice(ThemeData theme) {
    return Column(
      children: [
        for (final model in SeparationCatalog.all) ...[
          _modelTile(theme, model),
          if (model != SeparationCatalog.all.last)
            const SizedBox(height: Space.sm),
        ],
      ],
    );
  }

  Widget _modelTile(ThemeData theme, SeparationModel model) {
    final availability = _availability[model.id];
    final unavailable = availability != null && !availability.isAvailable;
    return _OptionCard(
      selected: _model.id == model.id,
      enabled: !unavailable,
      dense: true,
      title: model.name,
      badge: model.requiresInstall ? 'Model file' : null,
      body: unavailable
          ? availability.reason ?? 'Unavailable'
          : model.summary,
      onSelected: () => _selectModel(model.id),
    );
  }

  void _selectModel(String? id) {
    final model = id == null ? null : SeparationCatalog.byId(id);
    if (model == null) return;
    setState(() {
      _model = model;
      // Dropping to a two-stem model has to drop the four-stem choice too.
      if (_fourStem && !model.supports(StemKind.fourStem)) _fourStem = false;
    });
    _checkCache();
  }

  Widget _cachedNote(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: Palette.aqua.withValues(alpha: 0.10),
        borderRadius: Radii.allControl,
        border: Border.all(color: Palette.aqua.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          const Icon(Icons.bolt_rounded, size: 16, color: Palette.aqua),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              'This song has already been separated at these settings — it '
              'will open straight away.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Palette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _failureCard(ThemeData theme, String message) {
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: Palette.record.withValues(alpha: 0.10),
        borderRadius: Radii.allControl,
        border: Border.all(color: Palette.record.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: Palette.record,
          ),
          const SizedBox(width: Space.md),
          Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// A selectable card. One of these is what a radio button should have been on
/// a screen where each choice needs a sentence of explanation.
class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.selected,
    required this.enabled,
    required this.title,
    required this.body,
    required this.onSelected,
    this.icon,
    this.badge,
    this.dense = false,
  });

  final bool selected;
  final bool enabled;
  final String title;
  final String body;
  final VoidCallback onSelected;
  final IconData? icon;
  final String? badge;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = selected ? Palette.ember : Palette.textTertiary;

    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      enabled: enabled,
      button: true,
      label: title,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onSelected : null,
            borderRadius: Radii.allPanel,
            child: AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.standard,
              padding: EdgeInsets.all(dense ? Space.md : Space.lg),
              decoration: BoxDecoration(
                color: selected ? Palette.inset : Palette.panel,
                borderRadius: Radii.allPanel,
                // Selection is one solid accent edge on the leading side, the
                // way a selected channel is marked on a desk — not a tinted
                // wash and a thicker outline all the way round.
                border: Border(
                  left: BorderSide(
                    color: selected ? Palette.ember : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _indicator(selected),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            if (icon != null) ...[
                              Icon(icon, size: 15, color: tint),
                              const SizedBox(width: Space.sm),
                            ],
                            Flexible(
                              child: Text(
                                title,
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            if (badge != null) ...[
                              const SizedBox(width: Space.sm),
                              MetaChip(label: badge!),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(body, style: theme.textTheme.bodySmall),
                      ],
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

  Widget _indicator(bool selected) {
    return AnimatedContainer(
      duration: Motion.fast,
      width: 18,
      height: 18,
      margin: const EdgeInsets.only(top: 1),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? Palette.ember : Colors.transparent,
        border: Border.all(
          color: selected ? Palette.ember : Palette.lineStrong,
          width: 1.5,
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 12, color: Color(0xFF1A0C05))
          : null,
    );
  }
}

/// What the screen shows while the separator is working.
class _RunningPanel extends StatefulWidget {
  const _RunningPanel({required this.progress, required this.onCancel});

  final SeparationProgress? progress;
  final VoidCallback onCancel;

  @override
  State<_RunningPanel> createState() => _RunningPanelState();
}

class _RunningPanelState extends State<_RunningPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = widget.progress?.fraction ?? 0;

    return SurfacePanel(
      padding: const EdgeInsets.all(Space.xl),
      borderRadius: Radii.allPanel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 96,
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  painter: _SplitPainter(
                    phase: _controller.value,
                    fraction: fraction,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: Space.xl),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  widget.progress?.message ?? 'Working…',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Text(
                '${(fraction * 100).round()}%',
                style: EncoreType.timecode.copyWith(
                  fontSize: 24,
                  color: Palette.emberBright,
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          ProgressTrack(value: fraction <= 0 ? null : fraction),
          const SizedBox(height: Space.lg),
          Text(
            'Keep Encore open. Nothing is being uploaded — this is your '
            'device doing the work.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: Palette.textTertiary,
            ),
          ),
          const SizedBox(height: Space.xl),
          OutlinedButton.icon(
            onPressed: widget.onCancel,
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

/// Two lanes drifting apart, with a scan line running across at the current
/// progress: separation, drawn.
class _SplitPainter extends CustomPainter {
  _SplitPainter({required this.phase, required this.fraction});

  final double phase;
  final double fraction;

  static final List<double> _shape = List<double>.generate(72, (index) {
    final random = math.Random(index * 613 + 7);
    return 0.22 + 0.78 * random.nextDouble();
  });

  @override
  void paint(Canvas canvas, Size size) {
    final drift = 4 * math.sin(phase * 2 * math.pi);
    _lane(canvas, size, 0.02, 0.42, Palette.ember, -drift);
    _lane(canvas, size, 0.56, 0.42, Palette.trackInstrumental, drift);

    final x = size.width * fraction.clamp(0.0, 1.0);
    if (x <= 0) return;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, x, size.height),
      Paint()..color = Colors.white.withValues(alpha: 0.03),
    );
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = Palette.emberBright.withValues(alpha: 0.9)
        ..strokeWidth = 1.5,
    );
  }

  void _lane(
    Canvas canvas,
    Size size,
    double top,
    double height,
    Color colour,
    double offset,
  ) {
    final rect = Rect.fromLTWH(
      0,
      size.height * top + offset,
      size.width,
      size.height * height,
    );
    final centre = rect.center.dy;
    final half = rect.height / 2;
    final step = rect.width / _shape.length;
    final paint = Paint()
      ..color = colour.withValues(alpha: 0.75)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1.4, step * 0.4);

    for (var index = 0; index < _shape.length; index++) {
      final wobble =
          0.75 + 0.25 * math.sin((phase * 2 + index / 9) * math.pi * 2);
      final extent = half * _shape[index] * wobble;
      final x = rect.left + step * (index + 0.5);
      canvas.drawLine(
        Offset(x, centre - extent),
        Offset(x, centre + extent),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SplitPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.fraction != fraction;
}
