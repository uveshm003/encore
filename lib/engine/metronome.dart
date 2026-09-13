import 'dart:math' as math;
import 'dart:typed_data';

import '../core/audio_buffer.dart';

/// Click track and count-in (PLAY-06).
///
/// The click is generated once and mixed into the output at beat boundaries,
/// which keeps it locked to the same timeline as everything else — the count-in
/// before a take is simply the transport running at negative positions.
class Metronome {
  Metronome({
    required this.sampleRate,
    this.tempoBpm = 120.0,
    this.beatsPerBar = 4,
    this.gain = 0.55,
  }) {
    _accent = _buildClick(1200.0);
    _beat = _buildClick(820.0);
  }

  final int sampleRate;

  double tempoBpm;
  int beatsPerBar;
  double gain;
  bool enabled = false;

  late Float32List _accent;
  late Float32List _beat;

  int get framesPerBeat =>
      math.max(1, (sampleRate * 60.0 / (tempoBpm <= 0 ? 120.0 : tempoBpm)).round());

  int framesPerBar(int bars) => framesPerBeat * beatsPerBar * bars;

  /// Mixes clicks for `[startFrame, startFrame + frames)` into [destination].
  ///
  /// [startFrame] may be negative: that is what a count-in is.
  void render(
    int startFrame,
    AudioBuffer destination, {
    int destinationOffset = 0,
    int? frames,
  }) {
    if (!enabled || gain <= 0) return;
    final length = frames ?? (destination.frameCount - destinationOffset);
    if (length <= 0) return;
    final endFrame = startFrame + length;
    final beatFrames = framesPerBeat;

    // Start one beat early so a click that began in the previous block is
    // still heard ringing into this one.
    var beat = _floorDiv(startFrame, beatFrames) - 1;
    while (true) {
      final beatStart = beat * beatFrames;
      if (beatStart >= endFrame) break;
      final click = _isAccent(beat) ? _accent : _beat;
      if (beatStart + click.length > startFrame) {
        for (var i = 0; i < click.length; i++) {
          final frame = beatStart + i;
          if (frame < startFrame) continue;
          if (frame >= endFrame) break;
          final value = click[i] * gain;
          final index = destinationOffset + (frame - startFrame);
          for (final channel in destination.channels) {
            channel[index] += value;
          }
        }
      }
      beat++;
    }
  }

  /// Frames of count-in for [bars] bars at the current tempo.
  int countInFrames(int bars) => bars <= 0 ? 0 : framesPerBar(bars);

  bool _isAccent(int beat) {
    if (beatsPerBar <= 1) return true;
    return _floorMod(beat, beatsPerBar) == 0;
  }

  /// A short decaying tone: audible through a dense mix without being a
  /// distraction, and short enough never to smear across a beat.
  Float32List _buildClick(double frequency) {
    final length = (sampleRate * 0.035).round();
    final click = Float32List(length);
    for (var i = 0; i < length; i++) {
      final t = i / sampleRate;
      final envelope = math.exp(-t * 90.0);
      click[i] = math.sin(2 * math.pi * frequency * t) * envelope;
    }
    return click;
  }

  static int _floorDiv(int value, int divisor) {
    final quotient = value ~/ divisor;
    return (value % divisor != 0 && (value < 0) != (divisor < 0))
        ? quotient - 1
        : quotient;
  }

  static int _floorMod(int value, int divisor) {
    final remainder = value % divisor;
    return remainder < 0 ? remainder + divisor : remainder;
  }
}
