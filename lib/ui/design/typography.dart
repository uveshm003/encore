import 'package:flutter/material.dart';

import 'palette.dart';

/// The type scale.
///
/// No font is bundled: Encore ships no network permission and no downloads, so
/// it uses the platform's own UI face (SF on Apple, Roboto on Android) and
/// earns its character from weight, tracking and rhythm instead. Anything that
/// shows a changing number — timecode, levels, sizes — uses tabular figures so
/// the digits stop dancing.
///
/// Two kinds of text do the work here, and they look nothing alike:
///
/// * **Prose** — titles and body copy, set normally, for anything a person
///   reads in sentences.
/// * **Legends** — [panelLabel] and [control]: small, uppercase, widely
///   tracked, and quiet. These are the words printed onto a piece of
///   equipment beside a knob. They name things; they are not read.
///
/// Keeping the two apart is most of why the interface reads as an instrument
/// rather than a document. A legend never grows into a heading, and a heading
/// is never set in caps.
abstract final class EncoreType {
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static const TextTheme textTheme = TextTheme(
    displaySmall: TextStyle(
      fontSize: 34,
      height: 1.1,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.8,
      color: Palette.textPrimary,
    ),
    headlineMedium: TextStyle(
      fontSize: 26,
      height: 1.15,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      color: Palette.textPrimary,
    ),
    headlineSmall: TextStyle(
      fontSize: 21,
      height: 1.2,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      color: Palette.textPrimary,
    ),
    titleLarge: TextStyle(
      fontSize: 18,
      height: 1.25,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      color: Palette.textPrimary,
    ),
    titleMedium: TextStyle(
      fontSize: 15,
      height: 1.3,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.1,
      color: Palette.textPrimary,
    ),
    titleSmall: TextStyle(
      fontSize: 13.5,
      height: 1.3,
      fontWeight: FontWeight.w600,
      color: Palette.textPrimary,
    ),
    bodyLarge: TextStyle(
      fontSize: 15,
      height: 1.5,
      fontWeight: FontWeight.w400,
      color: Palette.textPrimary,
    ),
    bodyMedium: TextStyle(
      fontSize: 13.5,
      height: 1.45,
      fontWeight: FontWeight.w400,
      color: Palette.textPrimary,
    ),
    bodySmall: TextStyle(
      fontSize: 12.5,
      height: 1.4,
      fontWeight: FontWeight.w400,
      color: Palette.textSecondary,
    ),
    labelLarge: TextStyle(
      fontSize: 13.5,
      height: 1.2,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
      color: Palette.textPrimary,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      height: 1.2,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
      color: Palette.textSecondary,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      height: 1.2,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      color: Palette.textSecondary,
    ),
  );

  /// The legend above a region: LIBRARY, STORAGE, THIS DEVICE.
  ///
  /// Printed onto the panel, not titling a document — which is why it is
  /// smaller and quieter than the content it introduces, rather than louder.
  static const TextStyle panelLabel = TextStyle(
    fontSize: 10,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.6,
    color: Palette.textTertiary,
  );

  /// The legend on a control itself: M, S, REC, LOOP, IN, OUT.
  static const TextStyle control = TextStyle(
    fontSize: 10,
    height: 1.0,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.9,
    color: Palette.textSecondary,
  );

  /// The transport read-out: the one number the app is always showing.
  ///
  /// Given more size and more tracking than anything else in the interface,
  /// because on a piece of gear the counter is the display and everything
  /// around it is a label.
  static const TextStyle timecode = TextStyle(
    fontSize: 24,
    height: 1.0,
    fontWeight: FontWeight.w500,
    letterSpacing: 1.2,
    fontFeatures: tabular,
    color: Palette.textPrimary,
  );

  /// Small numerics: dB values, file sizes, durations in a list.
  static const TextStyle numeric = TextStyle(
    fontSize: 11.5,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
    fontFeatures: tabular,
    color: Palette.textSecondary,
  );

  /// The wordmark, set as it would be stamped on a faceplate.
  static const TextStyle wordmark = TextStyle(
    fontSize: 13,
    height: 1.0,
    fontWeight: FontWeight.w700,
    letterSpacing: 3.0,
    color: Palette.textPrimary,
  );
}
