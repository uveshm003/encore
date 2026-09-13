import 'package:flutter/widgets.dart';

/// Spacing scale.
///
/// Every gap in the app comes from here, so vertical rhythm stays consistent
/// across screens that were written at different times.
abstract final class Space {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 40;
}

/// Corner radii.
///
/// There are three, and two of them are almost square.
///
/// The previous ladder ran from 6 to 24 px on the rule that "containers step
/// up with their size". That is a system built for internal consistency rather
/// than to say anything, and softness applied evenly reads as software trying
/// to look friendly. Cut metal has a small, constant break on every edge
/// whatever the size of the part, so that is what this is: 2 px on controls,
/// 3 px on panels, and a true circle only where something is actually round.
///
/// Structural regions — a header against its content, a timeline lane — get no
/// radius at all. They are not objects; they are areas.
abstract final class Radii {
  /// Regions that meet each other. Use this rather than reaching for zero.
  static const Radius none = Radius.zero;

  /// Buttons, chips, inputs, meter troughs.
  static const Radius control = Radius.circular(2);

  /// Cards, sheets, dialogs, menus.
  static const Radius panel = Radius.circular(3);

  /// Only for things that are genuinely circular: transport buttons, status
  /// dots, the record light.
  static const Radius round = Radius.circular(999);

  static const BorderRadius allNone = BorderRadius.zero;
  static const BorderRadius allControl = BorderRadius.all(control);
  static const BorderRadius allPanel = BorderRadius.all(panel);
  static const BorderRadius allRound = BorderRadius.all(round);
}

/// Durations and curves.
///
/// Audio work is a place where motion has to stay out of the way: nothing
/// here is longer than a beat, and nothing bounces.
abstract final class Motion {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 380);
  static const Duration ambient = Duration(milliseconds: 1800);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeOutQuint;
  static const Curve entrance = Curves.easeOutCubic;
}

/// Stroke widths for hairlines and outlines.
abstract final class Strokes {
  static const double hair = 1;
  static const double focus = 2;
}
