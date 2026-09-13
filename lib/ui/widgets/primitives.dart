import 'package:flutter/material.dart';

import '../theme.dart';

/// The ground a full-screen layout sits on.
///
/// It paints one flat colour and nothing else.
///
/// This used to be a warm radial wash keyed to the accent — a light source
/// hanging above the top-left corner of every screen. It was the app's most
/// obvious tell: decoration with no job, applied everywhere because it was
/// available. A panel of equipment is evenly lit or it is not lit at all.
class AppGround extends StatelessWidget {
  const AppGround({required this.child, this.colour = Palette.surface, super.key});

  final Widget child;
  final Color colour;

  @override
  Widget build(BuildContext context) => ColoredBox(color: colour, child: child);
}

/// A flat panel, told apart from its surroundings by value alone.
///
/// No gradient, no shadow, and a border only when one is asked for. The fill
/// is a step lighter than the scaffold, which is enough on its own — if it is
/// not, the fix is the colour, not a highlight along the top edge.
///
/// [bordered] is off by default on purpose. A rule earns its place by
/// separating two regions that would otherwise run together; drawing one
/// around every panel just to finish it off is what made the old interface
/// look like a component gallery.
class SurfacePanel extends StatelessWidget {
  const SurfacePanel({
    required this.child,
    this.padding = const EdgeInsets.all(Space.lg),
    this.borderRadius = Radii.allPanel,
    this.colour = Palette.panel,
    this.borderColour = Palette.line,
    this.bordered = false,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color colour;
  final Color borderColour;

  /// Draw a hairline around the panel. For a panel that sits on the same
  /// value as what surrounds it, and would otherwise have no edge.
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colour,
        borderRadius: borderRadius,
        border: bordered ? Border.all(color: borderColour) : null,
      ),
      // Ink splashes paint on the nearest Material ancestor, which without
      // this is whatever sits *behind* the panel — so the panel's own fill
      // covers them and ListTile asserts about it in debug. A transparent
      // Material inside the decoration gives the ink somewhere visible to
      // land without painting anything itself.
      child: Material(
        type: MaterialType.transparency,
        borderRadius: borderRadius,
        child: child,
      ),
    );
  }
}

/// A tappable [SurfacePanel] that lifts under the pointer.
///
/// Encore runs in a desktop window as much as on a phone, so rows have to
/// answer a mouse as well as a finger.
class PressableSurface extends StatefulWidget {
  const PressableSurface({
    required this.child,
    required this.onTap,
    this.padding = EdgeInsets.zero,
    this.borderRadius = Radii.allPanel,
    this.accent = Palette.ember,
    this.semanticLabel,
    super.key,
  });

  final Widget child;
  final VoidCallback onTap;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color accent;
  final String? semanticLabel;

  @override
  State<PressableSurface> createState() => _PressableSurfaceState();
}

class _PressableSurfaceState extends State<PressableSurface> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.standard,
          decoration: BoxDecoration(
            // Hover is a step in value, not a coloured outline. A row that
            // lights up its border on mouse-over is a web card; a row that
            // gets lighter is a key that has been touched.
            color: _hovered ? Palette.inset : Palette.panel,
            borderRadius: widget.borderRadius,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: widget.borderRadius,
              hoverColor: Colors.transparent,
              splashColor: widget.accent.withValues(alpha: 0.08),
              highlightColor: widget.accent.withValues(alpha: 0.05),
              child: Padding(padding: widget.padding, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

/// The legend printed above a region, with the rule that divides it.
///
/// Three deliberate things, all of them borrowed from a faceplate rather than
/// from a document:
///
/// * The legend is *quieter* than the content it introduces. A heading that
///   shouts is a web page; a label beside a socket just tells you what the
///   socket is.
/// * The count sits hard right, on the same baseline, so a column of these
///   down a screen reads as a set of gauges rather than a list of titles. It
///   is a bare tabular number — a chip around it was packaging.
/// * The hairline runs the full width underneath. That rule is the reason the
///   region below needs no box drawn around it.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    required this.title,
    this.count,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(0, Space.xxl, 0, Space.sm),
    this.ruled = true,
    super.key,
  });

  final String title;
  final int? count;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  /// The hairline under the legend. Off where the region already has an edge.
  final bool ruled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(title.toUpperCase(), style: EncoreType.panelLabel),
              const Spacer(),
              if (trailing != null)
                trailing!
              else if (count != null)
                Text(
                  '$count',
                  style: EncoreType.numeric.copyWith(
                    fontSize: 10,
                    letterSpacing: 1.2,
                    color: Palette.textTertiary,
                  ),
                ),
            ],
          ),
          if (ruled) ...[
            const SizedBox(height: Space.sm),
            const Divider(height: 1, thickness: 1, color: Palette.lineFaint),
          ],
        ],
      ),
    );
  }
}

/// A quiet piece of metadata: duration, format, sample rate.
///
/// Bare tabular text by default, with no container at all.
///
/// These used to be filled pills. Three or four of them on a row turned every
/// list into a field of grey lozenges, which is the look of a component
/// library rather than of a machine reporting its state — and a box drawn
/// around a word adds nothing the word was not already saying.
///
/// A [colour] means the value *identifies* something rather than merely
/// describing it — a stem, a track kind — and only then does it get a fill,
/// because then it is a strip of coloured tape and the colour is the point.
class MetaChip extends StatelessWidget {
  const MetaChip({required this.label, this.icon, this.colour, super.key});

  final String label;
  final IconData? icon;

  /// Set only for values that identify a part. Leave null for plain facts.
  final Color? colour;

  @override
  Widget build(BuildContext context) {
    final identifies = colour != null;
    final tint = colour ?? Palette.textTertiary;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 11, color: tint),
          const SizedBox(width: 4),
        ],
        Text(
          label.toUpperCase(),
          style: EncoreType.numeric.copyWith(
            color: identifies ? Palette.base : tint,
            fontSize: 10,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
    if (!identifies) return content;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      color: tint,
      child: content,
    );
  }
}

/// A coloured dot, optionally breathing — used for record state and for the
/// stem colours on a project row.
class StatusDot extends StatefulWidget {
  const StatusDot({
    required this.colour,
    this.size = 8,
    this.pulse = false,
    super.key,
  });

  final Color colour;
  final double size;
  final bool pulse;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulse && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.pulse && _controller.isAnimating) {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final opacity = widget.pulse ? 0.45 + 0.55 * _controller.value : 1.0;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            // A pulsing indicator changes brightness, like an LED being
            // driven harder. It does not cast a halo onto the panel around
            // it, because light does not work that way and neither does gear.
            color: widget.colour.withValues(alpha: opacity),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}

/// A bar filling a trough.
///
/// Square ends and a flat fill. Separation and export are the two moments the
/// app asks someone to wait, and the honest way to show that is how far along
/// it is — not a gradient with a lit leading edge, which dresses the waiting
/// up as something to enjoy.
class ProgressTrack extends StatelessWidget {
  const ProgressTrack({
    required this.value,
    this.height = 6,
    this.colour = Palette.ember,
    super.key,
  });

  /// 0..1, or null while the length of the wait is unknown.
  final double? value;
  final double height;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    if (value == null) {
      return ClipRRect(
        borderRadius: Radii.allControl,
        child: LinearProgressIndicator(
          minHeight: height,
          backgroundColor: Palette.inset,
          color: colour,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final fraction = value!.clamp(0.0, 1.0);
        // The determinate bar is drawn by hand rather than by
        // LinearProgressIndicator, which means it carries none of that
        // widget's semantics — so a separation's progress would be silent to
        // a screen reader. Say the percentage instead (NFR-A11Y-01).
        return Semantics(
          value: '${(fraction * 100).round()}%',
          child: Container(
            height: height,
            // A trough cut into the panel with a solid bar filling it: the
            // whole of what a progress indicator is on a machine.
            decoration: const BoxDecoration(color: Palette.well),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: Motion.base,
                curve: Motion.standard,
                width: constraints.maxWidth * fraction,
                decoration: BoxDecoration(color: colour),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Fades and lifts its child in once, staggered by [index].
///
/// Used for list content on entry. It runs a single short animation per row
/// and then stops, so a long library does not keep animating.
class EntranceFade extends StatefulWidget {
  const EntranceFade({
    required this.child,
    this.index = 0,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final int index;
  final bool enabled;

  @override
  State<EntranceFade> createState() => _EntranceFadeState();
}

class _EntranceFadeState extends State<EntranceFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.base,
    value: widget.enabled ? 0 : 1,
  );

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) return;
    // Cap the stagger so the tenth row is not still waiting to appear.
    final delay = Duration(milliseconds: 28 * widget.index.clamp(0, 8));
    Future<void>.delayed(delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _controller, curve: Motion.entrance);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(curved),
        child: widget.child,
      ),
    );
  }
}

/// The shape used for a screen with nothing in it yet.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.title,
    required this.message,
    this.art,
    this.action,
    this.footnote,
    super.key,
  });

  final String title;
  final String message;
  final Widget? art;
  final Widget? action;
  final Widget? footnote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.xxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (art != null) ...[art!, const SizedBox(height: Space.xxl)],
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: Space.md),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Palette.textSecondary,
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: Space.xxl),
                action!,
              ],
              if (footnote != null) ...[
                const SizedBox(height: Space.xl),
                footnote!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
