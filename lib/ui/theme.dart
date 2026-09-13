import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design/palette.dart';
import 'design/tokens.dart';
import 'design/typography.dart';

export 'design/palette.dart';
export 'design/tokens.dart';
export 'design/typography.dart';

/// The app's visual language, assembled into a [ThemeData].
///
/// Dark only, and deliberately so: the interface sits behind waveforms and
/// meters for long stretches, and anything brighter competes with them. The
/// individual decisions live in `design/` — this file only wires them into the
/// Material widgets so a screen can be written without reaching for a colour
/// by hand.
class EncoreTheme {
  const EncoreTheme._();

  /// Status/navigation bar treatment, applied by [dark].
  static const SystemUiOverlayStyle systemOverlay = SystemUiOverlayStyle(
    statusBarColor: Color(0x00000000),
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Palette.surface,
    systemNavigationBarIconBrightness: Brightness.light,
  );

  static ThemeData dark() {
    final scheme = const ColorScheme.dark().copyWith(
      primary: Palette.ember,
      onPrimary: const Color(0xFF1A0C05),
      primaryContainer: Palette.emberDeep,
      onPrimaryContainer: Palette.emberBright,
      secondary: Palette.aqua,
      onSecondary: const Color(0xFF04140F),
      tertiary: Palette.info,
      error: Palette.record,
      onError: Colors.white,
      surface: Palette.surface,
      onSurface: Palette.textPrimary,
      onSurfaceVariant: Palette.textSecondary,
      surfaceContainerLowest: Palette.well,
      surfaceContainerLow: Palette.surface,
      surfaceContainer: Palette.panel,
      surfaceContainerHigh: Palette.overlay,
      surfaceContainerHighest: Palette.inset,
      outline: Palette.line,
      outlineVariant: Palette.lineFaint,
      shadow: Colors.black,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      textTheme: EncoreType.textTheme,
      scaffoldBackgroundColor: Palette.surface,
      canvasColor: Palette.surface,
      dividerColor: Palette.lineFaint,
      // No ripple. A ripple spreading out from a touch point is a Material
      // idea about materials; a key on a piece of equipment changes state the
      // instant it is pressed and does not ring afterwards. The highlight
      // colours below carry the feedback instead.
      splashFactory: NoSplash.splashFactory,
      // Tighter than Material's default. Density is the point of an
      // instrument: the more of the song that fits on screen, the less
      // scrolling sits between the performer and the take.
      visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _FadeThroughTransitions(),
          TargetPlatform.iOS: _FadeThroughTransitions(),
          TargetPlatform.macOS: _FadeThroughTransitions(),
          TargetPlatform.windows: _FadeThroughTransitions(),
          TargetPlatform.linux: _FadeThroughTransitions(),
        },
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: Palette.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Palette.textPrimary,
        systemOverlayStyle: systemOverlay,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleSpacing: Space.lg,
        // A faceplate header, not a title bar: low, and the same value as the
        // panels below it so the whole front of the app reads as one surface.
        toolbarHeight: 46,
        titleTextStyle: EncoreType.textTheme.titleSmall,
        iconTheme: const IconThemeData(size: 18, color: Palette.textSecondary),
        actionsIconTheme: const IconThemeData(
          size: 18,
          color: Palette.textSecondary,
        ),
      ),

      cardTheme: const CardThemeData(
        color: Palette.panel,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.allPanel,
          side: BorderSide(color: Palette.lineFaint),
        ),
        margin: EdgeInsets.zero,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: Palette.overlay,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: EncoreType.textTheme.titleLarge,
        contentTextStyle: EncoreType.textTheme.bodyMedium,
        shape: const RoundedRectangleBorder(
          borderRadius: Radii.allPanel,
          side: BorderSide(color: Palette.line),
        ),
        insetPadding: const EdgeInsets.all(Space.xxl),
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Palette.panel,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        showDragHandle: false,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radii.panel),
          side: BorderSide(color: Palette.line),
        ),
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: Palette.overlay,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        textStyle: EncoreType.textTheme.bodyMedium,
        shape: const RoundedRectangleBorder(
          borderRadius: Radii.allPanel,
          side: BorderSide(color: Palette.line),
        ),
      ),

      menuTheme: const MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Palette.overlay),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: Radii.allPanel,
              side: BorderSide(color: Palette.line),
            ),
          ),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Palette.ember,
          foregroundColor: const Color(0xFF1A0C05),
          disabledBackgroundColor: Palette.inset,
          disabledForegroundColor: Palette.textDisabled,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          textStyle: EncoreType.textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: Radii.allControl),
          elevation: 0,
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Palette.textPrimary,
          side: const BorderSide(color: Palette.line),
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          textStyle: EncoreType.textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: Radii.allControl),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: Palette.textSecondary,
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          textStyle: EncoreType.textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: Radii.allControl),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: Palette.textSecondary,
          highlightColor: Palette.lineFaint,
          shape: const RoundedRectangleBorder(borderRadius: Radii.allControl),
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: Palette.ember,
        foregroundColor: const Color(0xFF1A0C05),
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        extendedTextStyle: EncoreType.textTheme.labelLarge,
        shape: const RoundedRectangleBorder(borderRadius: Radii.allControl),
      ),

      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? Palette.inset
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? Palette.textPrimary
                : Palette.textSecondary,
          ),
          side: const WidgetStatePropertyAll(BorderSide(color: Palette.line)),
          textStyle: WidgetStatePropertyAll(EncoreType.textTheme.labelMedium),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: Radii.allControl),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
          ),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: Palette.inset,
        selectedColor: Palette.ember,
        checkmarkColor: Palette.base,
        disabledColor: Palette.inset,
        labelStyle: EncoreType.textTheme.labelMedium,
        secondaryLabelStyle: EncoreType.textTheme.labelMedium,
        side: const BorderSide(color: Palette.lineFaint),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.sm,
        ),
        showCheckmark: false,
        shape: const RoundedRectangleBorder(borderRadius: Radii.allControl),
      ),

      // A fader, not a toy: a thin cut track with a square cap riding in it.
      sliderTheme: SliderThemeData(
        trackHeight: 2,
        activeTrackColor: Palette.textTertiary,
        inactiveTrackColor: Palette.well,
        thumbColor: Palette.textPrimary,
        overlayColor: Colors.transparent,
        overlayShape: SliderComponentShape.noOverlay,
        thumbShape: const _FaderCap(),
        trackShape: const RectangularSliderTrackShape(),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? const Color(0xFF1A0C05)
              : Palette.textTertiary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Palette.ember
              : Palette.inset,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : Palette.line,
        ),
      ),

      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Palette.ember
              : Palette.textTertiary,
        ),
      ),

      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Palette.ember
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(Color(0xFF1A0C05)),
        side: const BorderSide(color: Palette.lineStrong, width: 1.5),
        shape: const RoundedRectangleBorder(borderRadius: Radii.allControl),
      ),

      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.xs,
        ),
        iconColor: Palette.textTertiary,
        titleTextStyle: EncoreType.textTheme.titleSmall,
        subtitleTextStyle: EncoreType.textTheme.bodySmall,
        shape: const RoundedRectangleBorder(borderRadius: Radii.allControl),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Palette.inset,
        hintStyle: EncoreType.textTheme.bodyMedium?.copyWith(
          color: Palette.textTertiary,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.md,
        ),
        border: const OutlineInputBorder(
          borderRadius: Radii.allControl,
          borderSide: BorderSide(color: Palette.lineFaint),
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: Radii.allControl,
          borderSide: BorderSide(color: Palette.lineFaint),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: Radii.allControl,
          borderSide: BorderSide(color: Palette.ember, width: 1.5),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Palette.overlay,
        contentTextStyle: EncoreType.textTheme.bodyMedium,
        actionTextColor: Palette.emberBright,
        elevation: 0,
        insetPadding: const EdgeInsets.all(Space.lg),
        width: null,
        shape: const RoundedRectangleBorder(
          borderRadius: Radii.allPanel,
          side: BorderSide(color: Palette.line),
        ),
      ),

      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.sm,
          vertical: Space.xs,
        ),
        margin: const EdgeInsets.all(Space.xs),
        textStyle: EncoreType.textTheme.labelSmall?.copyWith(
          color: Palette.textPrimary,
        ),
        decoration: BoxDecoration(
          color: Palette.overlay,
          borderRadius: Radii.allControl,
          border: Border.all(color: Palette.line),
        ),
      ),

      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: Palette.ember,
        linearTrackColor: Palette.inset,
        circularTrackColor: Palette.inset,
        linearMinHeight: 4,
      ),

      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(6),
        radius: Radii.round,
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? Palette.lineStrong
              : Palette.line,
        ),
      ),

      dividerTheme: const DividerThemeData(
        color: Palette.lineFaint,
        space: 1,
        thickness: 1,
      ),

      bannerTheme: MaterialBannerThemeData(
        backgroundColor: Palette.overlay,
        contentTextStyle: EncoreType.textTheme.bodyMedium,
        elevation: 0,
      ),
    );
  }
}

/// A quiet page transition: content lifts a few pixels and fades in.
///
/// The default Material slide reads as a phone gesture and looks wrong in a
/// desktop window, which is where most of this app's time is spent.
/// The cap riding in a fader track.
///
/// A short vertical bar rather than a circle: a round thumb is a switch you
/// drag, a bar is a fader cap, and it reads its own position against the track
/// far more precisely because it has an edge to line up.
class _FaderCap extends SliderComponentShape {
  const _FaderCap();

  static const Size _size = Size(4, 14);

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => _size;

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final paint = Paint()
      ..color = sliderTheme.thumbColor ?? Palette.textPrimary
      ..style = PaintingStyle.fill;
    context.canvas.drawRect(
      Rect.fromCenter(center: center, width: _size.width, height: _size.height),
      paint,
    );
  }
}

class _FadeThroughTransitions extends PageTransitionsBuilder {
  const _FadeThroughTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext? context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Motion.standard,
      reverseCurve: Motion.standard.flipped,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.015),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// Formats a duration as `m:ss` or `h:mm:ss`.
String formatDuration(Duration duration) {
  final total = duration.isNegative ? Duration.zero : duration;
  final hours = total.inHours;
  final minutes = total.inMinutes.remainder(60);
  final seconds = total.inSeconds.remainder(60);
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}'
        ':${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Formats a duration with tenths, for the transport read-out.
String formatTimecode(Duration duration) {
  final total = duration.isNegative ? Duration.zero : duration;
  final minutes = total.inMinutes;
  final seconds = total.inSeconds.remainder(60);
  final tenths = (total.inMilliseconds.remainder(1000) / 100).floor();
  return '$minutes:${seconds.toString().padLeft(2, '0')}.$tenths';
}

/// Formats a byte count for the storage screen.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
}
