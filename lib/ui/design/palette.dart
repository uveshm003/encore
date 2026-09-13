import 'package:flutter/material.dart';

/// The colour system.
///
/// Encore is dark-only on purpose: the interface spends its life behind
/// waveforms, meters and clip fills, and those have to be the brightest things
/// on screen.
///
/// The greys are near-neutral with the faintest warm lean — anodised metal in
/// shadow rather than the blue-black that dark software defaults to. They are
/// flat: there is no gradient anywhere in this file, and none anywhere in the
/// app. Surfaces are told apart by *value*, which is why the steps between
/// them are large enough to see. A panel that needs a gradient to be legible
/// is the wrong colour.
///
/// Three rules hold the whole thing together:
///
/// 1. **Nothing glows.** No coloured halo, no bloom, no ambient wash. Light in
///    this app comes from the audio — meters, waveforms, the playhead.
/// 2. **[ember] means live.** It marks what is happening *right now*: the
///    playhead, the armed track, the primary action of the screen you are on.
///    It is not a brand wash, and a screen with nothing live has none of it.
/// 3. **Rules are structure.** A hairline divides two regions. It is not an
///    outline drawn around a box to make the box look finished.
abstract final class Palette {
  // --------------------------------------------------------------- surfaces
  //
  // Five steps, each clearly lighter than the last. Flat fills only.

  /// Behind everything.
  static const Color base = Color(0xFF0B0B0C);

  /// The scaffold.
  static const Color surface = Color(0xFF141415);

  /// Panels: cards, headers, the transport bar, track headers.
  static const Color panel = Color(0xFF1C1D1E);

  /// Menus, dialogs and sheets — anything that genuinely floats.
  static const Color overlay = Color(0xFF252628);

  /// Controls sitting on a panel: inputs, chips, toggles, meter troughs.
  static const Color inset = Color(0xFF2E2F32);

  /// Wells that content is drawn into: meters, timeline lanes. Darker than
  /// the scaffold, so the audio inside them reads as lit from within.
  static const Color well = Color(0xFF0E0E0F);

  // ------------------------------------------------------------------- text
  //
  // Slightly warm off-white rather than pure white: screen-printed ink, not a
  // backlit pixel.

  static const Color textPrimary = Color(0xFFE9E8E5);
  static const Color textSecondary = Color(0xFF9B9B98);
  static const Color textTertiary = Color(0xFF6D6D6B);
  static const Color textDisabled = Color(0xFF474746);

  // -------------------------------------------------------------- hairlines
  //
  // With no gradients and no shadows, these do all the separating, so they are
  // a touch stronger than the usual near-invisible dark-theme rule.

  /// Between rows in a list: present, but not a ladder.
  static const Color lineFaint = Color(0x16FFFFFF);

  /// Between regions: a header from its content, a panel from the scaffold.
  static const Color line = Color(0x26FFFFFF);

  /// The edge of something focused or selected.
  static const Color lineStrong = Color(0x3DFFFFFF);

  // ----------------------------------------------------------------- accent

  /// Equipment orange. The only warm colour in the app, and it means *live*.
  ///
  /// Deliberately hot and a little unfriendly — the colour of a marking on a
  /// piece of gear, not a brand gradient. Restraint is what makes it work: if
  /// it appears on three things at once it has stopped meaning anything.
  static const Color ember = Color(0xFFF2622B);

  /// For small text and thin marks, where the base tone goes muddy.
  static const Color emberBright = Color(0xFFFF8A52);

  /// Pressed states and fills behind ember text.
  static const Color emberDeep = Color(0xFFB8420F);

  /// A cool counterweight, used *only* where something is safe or local: the
  /// offline badge and the privacy notes. Never decorative.
  static const Color aqua = Color(0xFF4E9186);

  // ---------------------------------------------------------------- signals

  static const Color record = Color(0xFFE23B3B);
  static const Color play = Color(0xFF3FB56B);
  static const Color warn = Color(0xFFD9A038);
  static const Color info = Color(0xFF5B87A8);

  // --------------------------------------------------------- track identity

  /// Stem colours, assigned by kind so a part looks the same in the timeline,
  /// the mixer and the export list.
  ///
  /// Low chroma on purpose. Seven saturated hues would be a rainbow; these are
  /// closer to coloured tape on a patchbay — they identify a lane without
  /// competing with the waveform drawn on top of them.
  static const Color trackVocals = ember;
  static const Color trackInstrumental = Color(0xFF5B87A8);
  static const Color trackDrums = Color(0xFFC98F42);
  static const Color trackBass = Color(0xFF7E6FA8);
  static const Color trackOther = Color(0xFF4E9186);
  static const Color trackRecording = Color(0xFFC4607F);
  static const Color trackReference = Color(0xFF6E7073);

  // ------------------------------------------------------------- treatments

  /// The only shadow in the app, for things that genuinely float above the
  /// window: menus, dialogs, sheets.
  ///
  /// Tight and dark rather than a soft bloom — a hard object casting a hard
  /// shadow. Nothing that is *part of* the interface gets one; a card sitting
  /// in a page is not floating, it is just a different colour.
  static List<BoxShadow> lift() => const [
    BoxShadow(color: Color(0x99000000), blurRadius: 16, offset: Offset(0, 6)),
  ];
}
